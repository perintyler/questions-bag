/**
 * The questions web page.
 *
 * Deliberately plain: no framework, no build step. It polls the service,
 * renders whatever is pending, and posts answers back. The whole page is one
 * job — let a person answer a question an agent is blocked on, from whatever
 * device is to hand.
 */

const POLL_MS = 4000;

/** Multi-select state per question, keyed `${recordId}:${questionId}`. */
const picked = new Map();
/** Questions whose answer is in flight, so a double-click cannot double-post. */
const submitting = new Set();

const $list = document.getElementById("list");
const $health = document.getElementById("health");

function key(recordId, questionId) {
  return `${recordId}:${questionId}`;
}

/**
 * The service authenticates every client, this page included — so the page
 * collects its credential from the loopback-only /config route rather than
 * the service carving out an unauthenticated path for same-origin requests.
 * One code path means a broken guard shows up as a 401 here instead of
 * silently letting anything through.
 */
let secret = null;

async function api(path, options) {
  if (secret === null) {
    const config = await fetch("/config").then((r) => r.json());
    secret = config.secret ?? "";
  }

  const response = await fetch(path, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      ...(secret ? { Authorization: `Bearer ${secret}` } : {}),
      ...(options?.headers ?? {}),
    },
  });
  if (!response.ok && response.status !== 409) {
    throw new Error(`HTTP ${response.status}`);
  }
  return response.json();
}

async function refreshHealth() {
  try {
    const health = await api("/health");
    // A stale sweeper means deadlines are not being enforced. Say so here
    // rather than letting the page look fine while questions pile up.
    $health.textContent = health.ok
      ? `${health.pending} pending`
      : "service unhealthy — deadlines are not being enforced";
    $health.classList.toggle("bad", !health.ok);
  } catch {
    $health.textContent = "service unreachable";
    $health.classList.add("bad");
  }
}

function optionRow(record, question, option) {
  const multi = question.multiSelect;
  const id = key(record.id, question.id);
  const chosen = picked.get(id) ?? new Set();
  const on = chosen.has(option.label);

  const label = document.createElement("label");
  label.className = `opt${on ? " on" : ""}`;

  const input = document.createElement("input");
  input.type = multi ? "checkbox" : "radio";
  input.name = id;
  input.checked = on;
  input.addEventListener("change", () => {
    const next = multi ? new Set(picked.get(id) ?? []) : new Set();
    if (multi && next.has(option.label)) next.delete(option.label);
    else next.add(option.label);
    picked.set(id, next);
    render();
  });

  const text = document.createElement("span");
  const strong = document.createElement("span");
  strong.className = "opt-label";
  strong.textContent = option.label;
  text.appendChild(strong);

  if (option.description) {
    const desc = document.createElement("span");
    desc.className = "opt-desc";
    desc.textContent = option.description;
    text.appendChild(desc);
  }
  if (option.preview) {
    const preview = document.createElement("code");
    preview.className = "opt-preview";
    preview.textContent = option.preview;
    text.appendChild(preview);
  }

  label.append(input, text);
  return label;
}

function askBlock(record, question) {
  const wrap = document.createElement("div");
  wrap.className = "ask";

  if (question.header) {
    const header = document.createElement("span");
    header.className = "ask-header";
    header.textContent = question.header;
    wrap.appendChild(header);
  }

  const prompt = document.createElement("p");
  prompt.className = "ask-question";
  prompt.textContent = question.question;
  wrap.appendChild(prompt);

  if (question.options?.length) {
    const options = document.createElement("div");
    options.className = "options";
    // A declared default pre-selects, and only pre-selects. It is never sent
    // on the reader's behalf if they walk away — the agent is told the
    // question expired instead.
    if (question.default && !picked.has(key(record.id, question.id))) {
      picked.set(key(record.id, question.id), new Set([question.default]));
    }
    for (const option of question.options) options.appendChild(optionRow(record, question, option));
    wrap.appendChild(options);
  } else {
    const box = document.createElement("textarea");
    box.placeholder = "Your answer…";
    box.dataset.text = key(record.id, question.id);
    box.value = picked.get(key(record.id, question.id))?.text ?? "";
    box.addEventListener("input", () => {
      picked.set(key(record.id, question.id), { text: box.value });
    });
    wrap.appendChild(box);
  }

  return wrap;
}

function collectAnswers(record) {
  return record.questions.map((question) => {
    const value = picked.get(key(record.id, question.id));
    if (value instanceof Set) {
      return { questionId: question.id, selected: [...value] };
    }
    return { questionId: question.id, selected: [], text: value?.text ?? "" };
  });
}

/** Every question needs something in it before the answer can be sent. */
function isComplete(record) {
  return record.questions.every((question) => {
    const value = picked.get(key(record.id, question.id));
    if (question.options?.length) return value instanceof Set && value.size > 0;
    return typeof value?.text === "string" && value.text.trim().length > 0;
  });
}

function card(record) {
  const pending = record.state === "pending";
  const el = document.createElement("article");
  el.className = `q ${pending ? "pending" : "settled"}`;

  const head = document.createElement("div");
  head.className = "q-head";
  const state = document.createElement("span");
  state.className = `q-state ${record.state}`;
  state.textContent = record.state;
  const who = document.createElement("span");
  who.textContent = record.requester;
  const when = document.createElement("span");
  when.textContent = record.created_at;
  head.append(state, who, when);
  el.appendChild(head);

  if (record.context) {
    const context = document.createElement("p");
    context.className = "q-context";
    context.textContent = record.context;
    el.appendChild(context);
  }

  for (const question of record.questions) {
    if (pending) {
      el.appendChild(askBlock(record, question));
    } else {
      const prompt = document.createElement("p");
      prompt.className = "ask-question";
      prompt.textContent = question.question;
      el.appendChild(prompt);
    }
  }

  if (pending) {
    const actions = document.createElement("div");
    actions.className = "actions";

    const send = document.createElement("button");
    send.className = "primary";
    send.textContent = "Answer";
    send.disabled = !isComplete(record) || submitting.has(record.id);
    send.addEventListener("click", () => settle(record, "answer"));

    // Dismissing is a real answer to give: it tells the agent a human saw the
    // question and chose not to decide, which is different from silence.
    const skip = document.createElement("button");
    skip.className = "quiet";
    skip.textContent = "Not answering";
    skip.disabled = submitting.has(record.id);
    skip.addEventListener("click", () => settle(record, "dismiss"));

    actions.append(send, skip);
    el.appendChild(actions);
  } else if (record.answers?.length) {
    const given = document.createElement("div");
    given.className = "answer-given";
    given.textContent = record.answers
      .map((a) => (a.text ? a.text : a.selected.join(", ")))
      .filter(Boolean)
      .join(" · ");
    const who = document.createElement("span");
    who.className = "who";
    who.textContent = ` — via ${record.answered_by ?? "unknown"}`;
    given.appendChild(who);
    el.appendChild(given);
  }

  return el;
}

async function settle(record, action) {
  submitting.add(record.id);
  render();
  try {
    const body =
      action === "answer"
        ? { answers: collectAnswers(record), answered_by: "web" }
        : { dismissed_by: "web" };
    await api(`/questions/${record.id}/${action === "answer" ? "answer" : "dismiss"}`, {
      method: "POST",
      body: JSON.stringify(body),
    });
  } catch (error) {
    // Leave the card interactive so the answer is not silently lost.
    console.error("failed to settle", error);
  } finally {
    submitting.delete(record.id);
    await load();
  }
}

let records = [];
let loadError = null;

function render() {
  $list.replaceChildren();

  if (loadError) {
    const panel = document.createElement("div");
    panel.className = "state-panel err";
    panel.textContent = "Cannot reach the questions service.";
    const hint = document.createElement("span");
    hint.className = "hint";
    // Said plainly, because this state and "no questions" mean opposite
    // things: an agent may be blocked right now with nobody able to see it.
    hint.textContent =
      "An agent may be waiting on an answer nobody can see. Check that the questions service is running.";
    panel.appendChild(hint);
    $list.appendChild(panel);
    return;
  }

  if (!records.length) {
    const panel = document.createElement("div");
    panel.className = "state-panel";
    panel.textContent = "Nothing to answer.";
    const hint = document.createElement("span");
    hint.className = "hint";
    hint.textContent = "Questions from agent sessions show up here.";
    panel.appendChild(hint);
    $list.appendChild(panel);
    return;
  }

  for (const record of records) $list.appendChild(card(record));
}

async function load() {
  try {
    records = await api("/questions");
    loadError = null;
  } catch (error) {
    loadError = error;
  }
  render();
  await refreshHealth();
}

load();
setInterval(load, POLL_MS);

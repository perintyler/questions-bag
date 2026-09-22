import { beforeEach, afterEach, describe, expect, it } from "vitest";
import Database from "better-sqlite3";
import { initSchema, setDb, closeDb, getDb } from "./db.js";
import {
  createQuestion,
  getQuestion,
  answerQuestion,
  dismissQuestion,
  sweepExpired,
  listQuestions,
  recordDelivery,
  wasDelivered,
  deliveryFailures,
} from "./store.js";
import type { AskedQuestion } from "./types.js";

const CHOICE: AskedQuestion[] = [
  {
    id: "q1",
    question: "Which database?",
    header: "Database",
    kind: "choice",
    multiSelect: false,
    options: [{ label: "Postgres" }, { label: "SQLite" }],
  },
];

function ask(overrides: Partial<Parameters<typeof createQuestion>[0]> = {}) {
  return createQuestion({ requester: "test", questions: CHOICE, ...overrides });
}

beforeEach(() => {
  const db = new Database(":memory:");
  initSchema(db);
  setDb(db);
});

afterEach(() => closeDb());

describe("creating", () => {
  it("starts pending with the payload intact", () => {
    const q = ask({ context: "picking a store" });
    expect(q.state).toBe("pending");
    expect(q.context).toBe("picking a store");
    expect(q.questions).toEqual(CHOICE);
    expect(q.answers).toBeNull();
  });

  it("keeps a question with no session", () => {
    // A cron or job has no session, and its question is still worth asking.
    expect(ask({ sessionId: null }).session_id).toBeNull();
  });
});

describe("answering", () => {
  it("records the answer and who gave it", () => {
    const q = ask();
    const settled = answerQuestion(q.id, [{ questionId: "q1", selected: ["SQLite"] }], "app");

    expect(settled?.state).toBe("answered");
    expect(settled?.answered_by).toBe("app");
    expect(settled?.answers).toEqual([{ questionId: "q1", selected: ["SQLite"] }]);
    expect(settled?.answered_at).toBeTruthy();
  });

  it("keeps free text", () => {
    const q = ask();
    const settled = answerQuestion(
      q.id,
      [{ questionId: "q1", selected: [], text: "actually, DuckDB" }],
      "web",
    );
    expect(settled?.answers?.[0].text).toBe("actually, DuckDB");
  });

  it("refuses a second answer", () => {
    // The guard that matters: whoever arrives first owns the outcome. Without
    // it, a late notification tap overwrites an answer the agent already acted
    // on.
    const q = ask();
    expect(answerQuestion(q.id, [{ questionId: "q1", selected: ["Postgres"] }], "notification"))
      .not.toBeNull();
    expect(answerQuestion(q.id, [{ questionId: "q1", selected: ["SQLite"] }], "app")).toBeNull();

    expect(getQuestion(q.id)?.answers).toEqual([{ questionId: "q1", selected: ["Postgres"] }]);
  });

  it("cannot revive an expired question", () => {
    // The case the guard exists for: the agent has already been told this
    // expired and moved on. A tap arriving now must not change the answer
    // underneath it.
    const q = ask({ ttlMinutes: -1 });
    sweepExpired();

    expect(answerQuestion(q.id, [{ questionId: "q1", selected: ["SQLite"] }], "app")).toBeNull();
    expect(getQuestion(q.id)?.state).toBe("expired");
  });

  it("writes one resolution row per real transition", () => {
    const q = ask();
    answerQuestion(q.id, [{ questionId: "q1", selected: ["SQLite"] }], "app");
    answerQuestion(q.id, [{ questionId: "q1", selected: ["Postgres"] }], "web");

    const rows = listResolutions(q.id);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ state: "answered", answered_by: "app" });
  });
});

describe("hydrating legacy rows", () => {
  // payload is stored once and read verbatim (see initSchema's comment on the
  // column) -- there is no migration for it. A row written before `kind` and
  // `multiSelect` existed on AskedQuestion is still sitting in real stores
  // with neither, and both are non-optional in the type every client decodes
  // against. This reproduces exactly that: a row created by writing the JSON
  // directly, the way createQuestion could NOT produce it (it always writes
  // a complete AskedQuestion), because that mismatch is the actual bug --
  // not a network problem, a legacy row failing to decode on every client at
  // once.
  function insertLegacyRow(payload: unknown, overrides: Partial<{ state: string }> = {}) {
    const db = getDb();
    const id = "legacy-" + Math.random().toString(36).slice(2);
    db.prepare(
      `INSERT INTO questions (id, requester, payload, state, expires_at)
       VALUES (?, 'legacy-test', ?, ?, datetime('now', '+1 hour'))`,
    ).run(id, JSON.stringify(payload), overrides.state ?? "pending");
    return id;
  }

  it("defaults a missing kind to choice", () => {
    const id = insertLegacyRow([{ id: "q1", question: "old row", options: [{ label: "a" }] }]);
    expect(getQuestion(id)?.questions[0].kind).toBe("choice");
  });

  it("defaults a missing multiSelect to false", () => {
    const id = insertLegacyRow([{ id: "q1", question: "old row", kind: "choice" }]);
    expect(getQuestion(id)?.questions[0].multiSelect).toBe(false);
  });

  // The two real rows this was found on (ios-surface-check probes) had
  // neither id, kind, nor multiSelect, and were already expired with no
  // answers -- so a synthesized id needs only to be stable across repeated
  // reads of the same row, not globally unique or persisted.
  it("synthesizes a stable id when one is missing entirely", () => {
    const id = insertLegacyRow([{ question: "probe", options: [{ label: "a" }] }]);
    const first = getQuestion(id)?.questions[0].id;
    const second = getQuestion(id)?.questions[0].id;
    expect(first).toBeTruthy();
    expect(first).toBe(second);
  });

  it("leaves a fully-shaped row untouched", () => {
    const id = insertLegacyRow(CHOICE);
    expect(getQuestion(id)?.questions).toEqual(CHOICE);
  });

  it("backfills through listQuestions too, not just getQuestion", () => {
    insertLegacyRow([{ id: "q1", question: "old row" }]);
    const [listed] = listQuestions({ state: "pending" });
    expect(listed.questions[0].kind).toBe("choice");
    expect(listed.questions[0].multiSelect).toBe(false);
  });
});

describe("dismissing", () => {
  it("is not the same as expiring", () => {
    // Someone was reached and said "not answering". That proves delivery
    // works, where an expiry proves nothing — so the states stay apart.
    const q = ask();
    expect(dismissQuestion(q.id, "app")?.state).toBe("dismissed");
    expect(getQuestion(q.id)?.answered_by).toBe("app");
  });

  it("refuses to dismiss a settled question", () => {
    const q = ask();
    answerQuestion(q.id, [{ questionId: "q1", selected: ["SQLite"] }], "app");
    expect(dismissQuestion(q.id, "web")).toBeNull();
    expect(getQuestion(q.id)?.state).toBe("answered");
  });
});

describe("expiry", () => {
  it("settles a question past its deadline", () => {
    const q = ask({ ttlMinutes: -1 });
    expect(sweepExpired()).toBe(1);
    expect(getQuestion(q.id)?.state).toBe("expired");
  });

  it("leaves nobody as the answerer", () => {
    // The NULL is load-bearing: it is how an audit tells a real reply from a
    // timeout. If the sweeper stamped itself here, the two would look alike.
    const q = ask({ ttlMinutes: -1 });
    sweepExpired();
    expect(getQuestion(q.id)?.answered_by).toBeNull();
    expect(getQuestion(q.id)?.answers).toBeNull();
  });

  it("never returns a declared default as the answer", () => {
    // A default pre-selects in the UI. Returning it on expiry would make
    // "they chose this" and "nobody was ever asked" identical — exactly the
    // ambiguity the whole state split exists to prevent.
    const q = createQuestion({
      requester: "test",
      ttlMinutes: -1,
      questions: [{ ...CHOICE[0], default: "Postgres" }],
    });
    sweepExpired();

    const after = getQuestion(q.id)!;
    expect(after.state).toBe("expired");
    expect(after.answers).toBeNull();
  });

  it("leaves a question that still has time", () => {
    const q = ask({ ttlMinutes: 60 });
    expect(sweepExpired()).toBe(0);
    expect(getQuestion(q.id)?.state).toBe("pending");
  });

  it("does not re-expire an already settled question", () => {
    const q = ask({ ttlMinutes: -1 });
    sweepExpired();
    expect(sweepExpired()).toBe(0);
    expect(listResolutions(q.id)).toHaveLength(1);
  });
});

describe("listing", () => {
  it("filters by state and session", () => {
    const mine = ask({ sessionId: "s1" });
    ask({ sessionId: "s2" });
    answerQuestion(mine.id, [{ questionId: "q1", selected: ["SQLite"] }], "app");

    expect(listQuestions({ state: "pending" })).toHaveLength(1);
    expect(listQuestions({ sessionId: "s1" })).toHaveLength(1);
    expect(listQuestions({ state: "answered", sessionId: "s1" })).toHaveLength(1);
    expect(listQuestions({ state: "answered", sessionId: "s2" })).toHaveLength(0);
  });
});

describe("delivery", () => {
  it("reports a question nobody could see", () => {
    // The check that must be able to fail. A question with no successful
    // delivery is one nobody could have answered, and that has to be
    // distinguishable from one they ignored.
    const q = ask();
    recordDelivery(q.id, "notification", false, "notifications are not permitted");

    expect(wasDelivered(q.id)).toBe(false);
    expect(deliveryFailures(q.id)).toEqual([
      "notification: notifications are not permitted",
    ]);
  });

  it("counts one working surface as delivered", () => {
    const q = ask();
    recordDelivery(q.id, "notification", false, "banners are off");
    recordDelivery(q.id, "app", true);

    expect(wasDelivered(q.id)).toBe(true);
  });
});

function listResolutions(questionId: string) {
  // Reaching past the store's API on purpose: the resolutions table is an
  // audit record, so the test asserts what was actually written rather than
  // what a getter chooses to report.
  return getDb()
    .prepare(`SELECT state, answered_by FROM resolutions WHERE question_id = ? ORDER BY id`)
    .all(questionId) as Array<{ state: string; answered_by: string | null }>;
}

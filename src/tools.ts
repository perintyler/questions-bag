/**
 * The agent-facing surface: ask a question, and wait.
 *
 * This replaces the coding agent's built-in question picker. The built-in is
 * a terminal popover — it works beautifully when someone is sitting at the
 * terminal, and does not exist at all otherwise. A Barry session is very often
 * a background run, a cron, or an overnight job, so "ask the user" has to mean
 * something that reaches a person who is not watching a scrollback.
 *
 * So a question here is stored, delivered to whatever surfaces are available,
 * and blocks on a real human answer. What it never does is invent one.
 */

import { z } from "zod";
import { defineTool, type ToolContext } from "@barry-rocks/tools";
import { randomUUID } from "node:crypto";
import {
  createQuestion,
  getQuestion,
  sweepExpired,
  listQuestions,
  wasDelivered,
  deliveryFailures,
} from "./store.js";
import type { AskedQuestion, Outcome, QuestionKind } from "./types.js";

const POLL_INTERVAL_MS = 2_000;

/**
 * How long to wait before warning that nobody has even been shown the
 * question. Long enough that the app's 5s poll and the notification round trip
 * have comfortably had their chance.
 */
const DELIVERY_GRACE_MS = 30_000;

function resolveSessionId(context: ToolContext | undefined): string | null {
  return context?.sessionId ?? process.env.BARRY_SESSION_ID ?? null;
}

const optionSchema = z.object({
  label: z.string().min(1).describe("Short label for the choice (1-5 words)"),
  description: z.string().optional().describe("What picking this one means"),
  preview: z
    .string()
    .optional()
    .describe(
      "Content shown beside the option — a code snippet, diff, or ASCII mockup. Use when the choice is best judged by looking at the thing.",
    ),
});

const questionSchema = z.object({
  question: z.string().min(1).describe("The full question, as you would say it out loud"),
  header: z
    .string()
    .optional()
    .describe("Short label for the question, shown as a chip. A few words."),
  options: z
    .array(optionSchema)
    .min(2)
    .optional()
    .describe(
      "The choices. Omit entirely to ask for free text instead — an open question is a first-class kind here, not an 'Other' escape hatch.",
    ),
  multiSelect: z
    .boolean()
    .default(false)
    .describe("Allow more than one option to be picked"),
  default: z
    .string()
    .optional()
    .describe(
      "Option label to pre-select. A convenience for whoever answers — it is NEVER returned as the answer if the question expires.",
    ),
});

/** Options present means a choice; absent means free text. Confirm is explicit. */
function inferKind(options: unknown[] | undefined): QuestionKind {
  return options && options.length > 0 ? "choice" : "text";
}

export const ask = defineTool({
  namespace: "questions",
  access: "read",
  name: "ask",
  description:
    "Ask the user something and wait for their answer. Use when you are blocked on a decision that is genuinely theirs — one you cannot resolve from the request, the code, or a sensible default. The question reaches them as a notification, in the Questions app, and on the web, so it works in a background or overnight session where no one is at the terminal. Returns an outcome; it does not throw when they decline.",
  schema: {
    questions: z
      .array(questionSchema)
      .min(1)
      .describe("The questions to ask. Keep them to the ones whose answers change what you do."),
    context: z
      .string()
      .optional()
      .describe(
        "Why you are asking, in a sentence or two. Shown above the questions so they can answer without going and reading the transcript.",
      ),
    requester: z
      .string()
      .default("agent")
      .describe("What is asking — an action or task name. Used for auditing."),
    ttl_minutes: z
      .number()
      .int()
      .positive()
      .optional()
      .describe("How long to wait before giving up. Defaults to four hours."),
  },
  handler: async ({ questions, context, requester, ttl_minutes }, toolContext): Promise<Outcome> => {
    const asked: AskedQuestion[] = questions.map((q) => ({
      id: randomUUID(),
      question: q.question,
      header: q.header,
      kind: inferKind(q.options),
      options: q.options,
      multiSelect: q.multiSelect,
      default: q.default,
    }));

    const record = createQuestion({
      requester,
      questions: asked,
      context,
      sessionId: resolveSessionId(toolContext),
      ttlMinutes: ttl_minutes,
    });

    const startedAt = Date.now();
    let warnedUndelivered: string | undefined;

    for (;;) {
      // Enforce the deadline here as well as in the service. Waiting only on
      // the service's sweeper would hang forever in exactly the case where
      // that service is the thing that has broken.
      sweepExpired();

      const current = getQuestion(record.id);
      if (!current) {
        return {
          answered: false,
          state: "dismissed",
          reason: "The question record disappeared before it was answered.",
          question_id: record.id,
        };
      }

      if (current.state !== "pending") {
        return settle(current.state, current.answers, record.id, warnedUndelivered);
      }

      // A question nobody can see is not a question. Surface that as soon as
      // the grace period is up, rather than letting the agent sit through a
      // four-hour timeout and then report silence as if a human had ignored it.
      if (!warnedUndelivered && Date.now() - startedAt > DELIVERY_GRACE_MS) {
        if (!wasDelivered(record.id)) {
          const failures = deliveryFailures(record.id);
          warnedUndelivered = failures.length
            ? `Nothing has shown this question to anyone yet: ${failures.join("; ")}`
            : "Nothing has shown this question to anyone yet — no delivery surface has picked it up. Check that the questions service is running and the Questions app can reach it.";
        }
      }

      await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
    }
  },
});

function settle(
  state: "answered" | "expired" | "dismissed",
  answers: Outcome["answers"] | null,
  questionId: string,
  undelivered: string | undefined,
): Outcome {
  if (state === "answered") {
    return {
      answered: true,
      state,
      answers: answers ?? [],
      reason: "The user answered.",
      question_id: questionId,
    };
  }

  // Both remaining states mean "no answer", and they are kept apart because
  // they call for different responses. `dismissed` proves a human saw it and
  // chose not to reply. `expired` proves nothing — it is equally consistent
  // with a broken notification path, which is why the undelivered note rides
  // along.
  const reason =
    state === "dismissed"
      ? "The user saw the question and chose not to answer it. Do not re-ask the same thing; proceed on your own judgement or stop and explain what you need."
      : "Nobody answered before the deadline. This is NOT a refusal — it is equally consistent with nobody having seen it. Say so rather than treating silence as a decision.";

  return {
    answered: false,
    state,
    reason: undelivered ? `${reason} ${undelivered}` : reason,
    question_id: questionId,
    ...(undelivered ? { undelivered } : {}),
  };
}

export const listQuestionsTool = defineTool({
  namespace: "questions",
  access: "read",
  name: "list",
  description: "List questions and how they were resolved.",
  schema: {
    state: z.enum(["pending", "answered", "expired", "dismissed"]).optional(),
    session_id: z.string().optional().describe("Only questions raised by this session"),
    limit: z.number().int().positive().max(200).default(50),
  },
  handler: async ({ state, session_id, limit }) => {
    // Sweep first so a stale `pending` is never reported as if it were still
    // live. A list that shows a long-dead question as awaiting an answer sends
    // someone to look for a UI that has already moved on.
    sweepExpired();
    return listQuestions({ state, sessionId: session_id, limit });
  },
  cliFormat: (rows: unknown) => {
    const list = rows as Array<{
      id: string;
      state: string;
      requester: string;
      questions: Array<{ question: string }>;
      created_at: string;
    }>;
    if (!list.length) return "no questions";
    return list
      .map(
        (q) =>
          `${q.state.padEnd(9)} ${q.created_at}  ${q.requester}\n          ${q.questions.map((x) => x.question).join(" / ")}\n          ${q.id}`,
      )
      .join("\n");
  },
});

export const status = defineTool({
  namespace: "questions",
  access: "read",
  name: "status",
  description:
    "Check that asking a question actually works end to end: the store, the service, and whether any surface is in a position to show one to a human.",
  schema: {},
  handler: async () => {
    const port = process.env.BARRY_QUESTIONS_PORT ?? "3869";
    const url = `http://127.0.0.1:${port}/health`;

    let service: { reachable: boolean; healthy: boolean; detail: string };
    try {
      const response = await fetch(url, { signal: AbortSignal.timeout(3_000) });
      const body = (await response.json().catch(() => ({}))) as {
        sweeper?: { last_sweep_at?: string | null };
      };
      service = {
        reachable: true,
        // A 503 here is the service telling us its sweeper is stale. Reporting
        // that as "up" is exactly the kind of check that cannot fail.
        healthy: response.ok,
        detail: response.ok
          ? `healthy (sweeper last ran ${body.sweeper?.last_sweep_at ?? "unknown"})`
          : `unhealthy: HTTP ${response.status} — questions may never expire`,
      };
    } catch (error) {
      service = {
        reachable: false,
        healthy: false,
        detail: `unreachable at ${url}: ${error instanceof Error ? error.message : String(error)}`,
      };
    }

    const pending = listQuestions({ state: "pending", limit: 200 });
    const unseen = pending.filter((q) => !wasDelivered(q.id));

    return {
      status: service.healthy && unseen.length === 0 ? "ok" : "degraded",
      service: service.detail,
      pending: pending.length,
      // The number that matters. Pending questions nobody has been shown are
      // agents blocked on a person who does not know they were asked.
      pendingNobodyHasSeen: unseen.length,
      ...(unseen.length
        ? { unseen: unseen.map((q) => ({ id: q.id, failures: deliveryFailures(q.id) })) }
        : {}),
    };
  },
  cliFormat: (result: unknown) => {
    const r = result as {
      status: string;
      service: string;
      pending: number;
      pendingNobodyHasSeen: number;
    };
    return [
      `${r.status}`,
      `service: ${r.service}`,
      `pending: ${r.pending} (${r.pendingNobodyHasSeen} shown to nobody)`,
    ].join("\n");
  },
});

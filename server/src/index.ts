/**
 * The questions service.
 *
 * It exists because the UIs cannot open this bag's SQLite file: the macOS app
 * is sandboxed and the web page is a browser. Everything that shows a question
 * to a human, or carries their answer back, goes through here.
 *
 * It also owns the deadline. The asking tool sweeps too, so a dead service
 * cannot pin an agent forever — but this is where expiry happens when nobody
 * is asking.
 */

import express from "express";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { createLogger } from "@barry-rocks/logger";
import { sweeperHealth } from "./health.js";
import { isDirectLoopback } from "./loopback.js";
import {
  createQuestion,
  getQuestion,
  answerQuestion,
  dismissQuestion,
  listQuestions,
  sweepExpired,
  recordDelivery,
} from "../../src/store.js";
import type { QuestionState, Surface } from "../../src/types.js";

const log = createLogger("questions");

const PORT = Number(process.env.BARRY_QUESTIONS_PORT ?? 3869);
const SECRET = process.env.BARRY_SECRET ?? "";

/** How often elapsed questions are closed. */
const SWEEP_INTERVAL_MS = 30_000;

/**
 * When the sweeper last completed a pass.
 *
 * `/health` reports this so a dead sweeper is visible. Without it the service
 * would answer a cheerful "ok" while questions piled up pending forever behind
 * a green light — the exact failure this primitive exists to prevent,
 * reproduced inside its own health check.
 */
let lastSweepAt: number | null = null;

const app = express();
app.use(express.json({ limit: "4mb" }));

// Log every request. Without it, "the app is not polling" and "the app is
// polling and finding nothing" look identical from the outside — and that
// difference decides whether a blocked agent is a delivery bug or an empty
// queue.
app.use((req, _res, next) => {
  log.info(`${req.method} ${req.originalUrl}`);
  next();
});

function authorize(req: express.Request, res: express.Response): boolean {
  if (!SECRET) return true;
  const header = req.headers.authorization;
  const alt = req.headers["x-barry-secret"];
  if (header === `Bearer ${SECRET}` || alt === SECRET) return true;
  res.status(401).json({ error: "unauthorized" });
  return false;
}

/**
 * The secret, for the page this service itself serves.
 *
 * The alternative was exempting the web routes from auth on the grounds that
 * they are same-origin — but then the guard's broken state (no auth at all)
 * and its working state look identical from the browser, and nothing would
 * catch it if the bind address ever widened. Handing the page a credential
 * keeps one code path: every client authenticates, including this one.
 *
 * Served only to a DIRECT loopback caller — see `isDirectLoopback`. The phone
 * app deliberately does not use this route; it carries a secret entered once
 * into the keychain, because a client that bootstraps its credential from an
 * unauthenticated endpoint does not really have one.
 */
app.get("/config", (req, res) => {
  if (!isDirectLoopback(req)) {
    res.status(403).json({ error: "forbidden" });
    return;
  }
  res.json({ secret: SECRET });
});

const SURFACES: Surface[] = ["notification", "app", "web", "cli", "ios"];

function toSurface(value: unknown): Surface | null {
  return typeof value === "string" && (SURFACES as string[]).includes(value)
    ? (value as Surface)
    : null;
}

app.get("/health", (_req, res) => {
  const sweeper = sweeperHealth(lastSweepAt, Date.now(), SWEEP_INTERVAL_MS * 3);

  res.status(sweeper.status).json({
    ok: sweeper.healthy,
    pending: listQuestions({ state: "pending", limit: 200 }).length,
    sweeper,
  });
});

app.post("/questions", (req, res) => {
  if (!authorize(req, res)) return;
  const { requester, questions, context, session_id, ttl_minutes } = req.body ?? {};

  if (typeof requester !== "string" || !Array.isArray(questions) || questions.length === 0) {
    res.status(400).json({ error: "requester (string) and a non-empty questions array are required" });
    return;
  }

  res.json(
    createQuestion({
      requester,
      questions,
      context: typeof context === "string" ? context : undefined,
      sessionId: typeof session_id === "string" ? session_id : null,
      ttlMinutes: typeof ttl_minutes === "number" ? ttl_minutes : undefined,
    }),
  );
});

app.get("/questions", (req, res) => {
  if (!authorize(req, res)) return;
  // Sweep before listing. A UI that renders a long-dead question as awaiting
  // an answer sends someone to answer something nobody is waiting on.
  sweepExpired();
  lastSweepAt = Date.now();
  res.json(
    listQuestions({
      state: req.query.state as QuestionState | undefined,
      sessionId: typeof req.query.session_id === "string" ? req.query.session_id : undefined,
    }),
  );
});

app.get("/questions/:id", (req, res) => {
  if (!authorize(req, res)) return;
  const question = getQuestion(req.params.id);
  if (!question) {
    res.status(404).json({ error: "not found" });
    return;
  }
  res.json(question);
});

app.post("/questions/:id/answer", (req, res) => {
  if (!authorize(req, res)) return;
  const { answers, answered_by } = req.body ?? {};

  if (!Array.isArray(answers)) {
    res.status(400).json({ error: "answers array required" });
    return;
  }
  const surface = toSurface(answered_by);
  if (!surface) {
    res.status(400).json({ error: `answered_by must be one of ${SURFACES.join(", ")}` });
    return;
  }

  const settled = answerQuestion(req.params.id, answers, surface);
  if (!settled) {
    // Not an error: two people can answer at once, or it just expired. The
    // caller wants the outcome that actually stands, so hand back the record
    // and let the UI say "someone got there first".
    const current = getQuestion(req.params.id);
    if (!current) {
      res.status(404).json({ error: "not found" });
      return;
    }
    res.status(409).json({ ...current, changed: false });
    return;
  }

  res.json({ ...settled, changed: true });
});

app.post("/questions/:id/dismiss", (req, res) => {
  if (!authorize(req, res)) return;
  const surface = toSurface(req.body?.dismissed_by);
  if (!surface) {
    res.status(400).json({ error: `dismissed_by must be one of ${SURFACES.join(", ")}` });
    return;
  }

  const settled = dismissQuestion(req.params.id, surface);
  if (!settled) {
    const current = getQuestion(req.params.id);
    if (!current) {
      res.status(404).json({ error: "not found" });
      return;
    }
    res.status(409).json({ ...current, changed: false });
    return;
  }
  res.json({ ...settled, changed: true });
});

/**
 * A surface reporting whether it managed to show a question to anyone.
 *
 * The failure case is the point. `UNUserNotificationCenter.add` succeeds
 * silently when notifications are denied, so an app that only reported its
 * successes would let a question nobody can see look exactly like a question
 * nobody has answered yet.
 */
app.post("/questions/:id/delivery", (req, res) => {
  if (!authorize(req, res)) return;
  const surface = toSurface(req.body?.surface);
  const { delivered, detail } = req.body ?? {};

  if (!surface || typeof delivered !== "boolean") {
    res.status(400).json({ error: "surface and delivered (boolean) are required" });
    return;
  }
  if (!getQuestion(req.params.id)) {
    res.status(404).json({ error: "not found" });
    return;
  }

  recordDelivery(req.params.id, surface, delivered, typeof detail === "string" ? detail : undefined);
  if (!delivered) log.warn(`question ${req.params.id} undelivered via ${surface}: ${detail ?? ""}`);
  res.json({ recorded: true });
});

// The web page. Unauthenticated on purpose — it is served on loopback only,
// and the API calls it makes carry the secret from the page's own config.
app.use("/", express.static(join(dirname(fileURLToPath(import.meta.url)), "..", "..", "web")));

const sweeper = setInterval(() => {
  try {
    sweepExpired();
    lastSweepAt = Date.now();
  } catch (error) {
    // Leave lastSweepAt alone so /health degrades rather than papering over it.
    log.error(`questions.sweep_failed ${error instanceof Error ? error.message : String(error)}`);
  }
}, SWEEP_INTERVAL_MS);
sweeper.unref?.();

// Run once at boot so /health is truthful immediately, rather than reporting a
// dead sweeper for the first interval.
sweepExpired();
lastSweepAt = Date.now();

app.listen(PORT, "127.0.0.1", () => {
  log.info(`questions service on 127.0.0.1:${PORT}`);
});

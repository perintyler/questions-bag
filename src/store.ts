/**
 * The question state machine.
 *
 * A question is created `pending` and leaves exactly once — to `answered`,
 * `expired`, or `dismissed`. Every transition is guarded by
 * `WHERE id = ? AND state = 'pending'`, so whoever arrives first owns the
 * outcome: the person tapping a notification button, the app, the web page,
 * or the sweeper. Without that guard a late tap could flip an already-expired
 * question to answered *after* the agent was told it expired and acted on it.
 */

import { randomUUID } from "node:crypto";
import { getDb, DEFAULT_TTL_MINUTES } from "./db.js";
import type {
  AskedQuestion,
  QuestionAnswer,
  QuestionRecord,
  QuestionState,
  Surface,
} from "./types.js";

interface Row {
  id: string;
  session_id: string | null;
  requester: string;
  context: string | null;
  payload: string;
  answer: string | null;
  state: QuestionState;
  answered_by: string | null;
  answered_at: string | null;
  expires_at: string;
  created_at: string;
}

function hydrate(row: Row): QuestionRecord {
  return {
    id: row.id,
    session_id: row.session_id,
    requester: row.requester,
    context: row.context,
    questions: JSON.parse(row.payload) as AskedQuestion[],
    answers: row.answer ? (JSON.parse(row.answer) as QuestionAnswer[]) : null,
    state: row.state,
    answered_by: row.answered_by,
    answered_at: row.answered_at,
    expires_at: row.expires_at,
    created_at: row.created_at,
  };
}

export interface CreateInput {
  requester: string;
  questions: AskedQuestion[];
  context?: string;
  sessionId?: string | null;
  ttlMinutes?: number;
}

export function createQuestion(input: CreateInput): QuestionRecord {
  const db = getDb();
  const id = randomUUID();
  const ttl = input.ttlMinutes ?? DEFAULT_TTL_MINUTES;

  // Computed in SQLite rather than JS so the deadline shares a clock with the
  // sweeper's `datetime('now')` comparison. A JS-side ISO string drifts from
  // SQLite's UTC formatting and makes off-by-a-timezone expiries.
  db.prepare(
    `INSERT INTO questions (id, session_id, requester, context, payload, state, expires_at)
     VALUES (?, ?, ?, ?, ?, 'pending', datetime('now', ?))`,
  ).run(
    id,
    input.sessionId ?? null,
    input.requester,
    input.context ?? null,
    JSON.stringify(input.questions),
    `${ttl} minutes`,
  );

  return getQuestion(id)!;
}

export function getQuestion(id: string): QuestionRecord | null {
  const row = getDb().prepare(`SELECT * FROM questions WHERE id = ?`).get(id) as Row | undefined;
  return row ? hydrate(row) : null;
}

/**
 * Record the answer. Returns the settled record, or null when the question was
 * already settled — the caller must treat null as "someone else got there
 * first", not as an error to retry.
 */
export function answerQuestion(
  id: string,
  answers: QuestionAnswer[],
  answeredBy: Surface,
): QuestionRecord | null {
  const db = getDb();
  const settle = db.transaction(() => {
    const info = db
      .prepare(
        `UPDATE questions
            SET state = 'answered', answer = ?, answered_by = ?, answered_at = datetime('now')
          WHERE id = ? AND state = 'pending'`,
      )
      .run(JSON.stringify(answers), answeredBy, id);

    if (info.changes !== 1) return null;

    db.prepare(
      `INSERT INTO resolutions (question_id, state, answered_by) VALUES (?, 'answered', ?)`,
    ).run(id, answeredBy);

    return getQuestion(id);
  });
  return settle();
}

/**
 * A human saw the question and declined to answer it.
 *
 * Distinct from expiry: someone was reached, which means the delivery path
 * works. Collapsing the two would hide a broken notification behind what looks
 * like a deliberate choice.
 */
export function dismissQuestion(id: string, dismissedBy: Surface): QuestionRecord | null {
  const db = getDb();
  const settle = db.transaction(() => {
    const info = db
      .prepare(
        `UPDATE questions
            SET state = 'dismissed', answered_by = ?, answered_at = datetime('now')
          WHERE id = ? AND state = 'pending'`,
      )
      .run(dismissedBy, id);

    if (info.changes !== 1) return null;

    db.prepare(
      `INSERT INTO resolutions (question_id, state, answered_by) VALUES (?, 'dismissed', ?)`,
    ).run(id, dismissedBy);

    return getQuestion(id);
  });
  return settle();
}

/**
 * Settle every question past its deadline. Returns how many were expired.
 *
 * `answered_by` is deliberately left NULL: nobody answered. That NULL is what
 * lets an audit tell a real reply from a timeout.
 */
export function sweepExpired(): number {
  const db = getDb();
  const sweep = db.transaction(() => {
    const due = db
      .prepare(`SELECT id FROM questions WHERE state = 'pending' AND expires_at <= datetime('now')`)
      .all() as Array<{ id: string }>;

    for (const { id } of due) {
      const info = db
        .prepare(`UPDATE questions SET state = 'expired' WHERE id = ? AND state = 'pending'`)
        .run(id);
      if (info.changes === 1) {
        db.prepare(`INSERT INTO resolutions (question_id, state) VALUES (?, 'expired')`).run(id);
      }
    }
    return due.length;
  });
  return sweep();
}

export interface ListFilter {
  state?: QuestionState;
  sessionId?: string;
  limit?: number;
}

export function listQuestions(filter: ListFilter = {}): QuestionRecord[] {
  const clauses: string[] = [];
  const params: unknown[] = [];

  if (filter.state) {
    clauses.push("state = ?");
    params.push(filter.state);
  }
  if (filter.sessionId) {
    clauses.push("session_id = ?");
    params.push(filter.sessionId);
  }

  const where = clauses.length ? `WHERE ${clauses.join(" AND ")}` : "";
  params.push(filter.limit ?? 50);

  const rows = getDb()
    .prepare(`SELECT * FROM questions ${where} ORDER BY created_at DESC LIMIT ?`)
    .all(...params) as Row[];

  return rows.map(hydrate);
}

/**
 * Record whether the question actually reached a human.
 *
 * Called by every delivery surface, including when delivery *fails*. A
 * question with no successful delivery row is one nobody could have answered,
 * and `ask` reports that rather than letting it look like silence.
 */
export function recordDelivery(
  questionId: string,
  surface: Surface,
  delivered: boolean,
  detail?: string,
): void {
  getDb()
    .prepare(
      `INSERT INTO deliveries (question_id, surface, delivered, detail) VALUES (?, ?, ?, ?)`,
    )
    .run(questionId, surface, delivered ? 1 : 0, detail ?? null);
}

/** True when at least one surface confirmed it put this question in front of someone. */
export function wasDelivered(questionId: string): boolean {
  const row = getDb()
    .prepare(`SELECT COUNT(*) AS n FROM deliveries WHERE question_id = ? AND delivered = 1`)
    .get(questionId) as { n: number };
  return row.n > 0;
}

/** Why delivery failed, for an agent that needs to explain the silence. */
export function deliveryFailures(questionId: string): string[] {
  const rows = getDb()
    .prepare(
      `SELECT surface, detail FROM deliveries
        WHERE question_id = ? AND delivered = 0 ORDER BY created_at`,
    )
    .all(questionId) as Array<{ surface: string; detail: string | null }>;
  return rows.map((r) => (r.detail ? `${r.surface}: ${r.detail}` : r.surface));
}

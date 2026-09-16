import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import Database from "better-sqlite3";

export type QuestionDb = Database.Database;

/**
 * How long a question waits for a human before it gives up.
 *
 * Longer than an approval's hour: an approval gates work already in flight,
 * while a question is often asked by an overnight run that can afford to wait
 * for someone to wake up. Short enough that a forgotten question still
 * resolves rather than pinning an agent forever.
 */
export const DEFAULT_TTL_MINUTES = 240;

let _db: QuestionDb | null = null;

function getDbPath(): string {
  return process.env.BARRY_QUESTIONS_DB ?? join(homedir(), ".barry", "questions.db");
}

/**
 * Schema is inlined rather than read from a `migrations/` dir. That pattern
 * resolves SQL through `import.meta.url`, which breaks the moment esbuild
 * bundles this bag into ~/Library/Caches/Barry/bags — the same reason
 * bags/approvals inlines its own.
 */
export function initSchema(db: QuestionDb): void {
  db.exec(`
    CREATE TABLE IF NOT EXISTS questions (
      id TEXT PRIMARY KEY,
      -- Nullable on purpose: a job or cron has no session, and a question it
      -- raises is still worth asking and recording.
      session_id TEXT,
      requester TEXT NOT NULL,
      -- Why the agent is asking. Shown above the questions so the reader can
      -- answer without going and reading a transcript.
      context TEXT,
      -- The asked questions, as JSON: [{ id, question, header, kind, options,
      -- multiSelect, default }]. Stored whole rather than in a child table —
      -- it is written once, read whole, and never queried across.
      payload TEXT NOT NULL,
      -- The reply, as JSON: [{ questionId, selected: [], text }]. NULL until
      -- someone answers; an answered row always has it.
      answer TEXT,
      state TEXT NOT NULL CHECK (state IN ('pending','answered','expired','dismissed')),
      -- Which surface settled it: 'notification', 'app', 'web', 'cli',
      -- 'ios'. A question answered by nobody has this NULL, which is how
      -- the store tells "they chose" from "it ran out".
      answered_by TEXT,
      answered_at TEXT,
      expires_at TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_questions_state ON questions(state);
    CREATE INDEX IF NOT EXISTS idx_questions_session ON questions(session_id);
    CREATE INDEX IF NOT EXISTS idx_questions_expires ON questions(expires_at);

    -- Append-only record of how each question was settled. The questions row
    -- carries the current state; this carries how it got there, which is what
    -- you want when asking "did a human actually answer this, or did it time
    -- out while nobody was looking?"
    CREATE TABLE IF NOT EXISTS resolutions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      question_id TEXT NOT NULL,
      state TEXT NOT NULL,
      answered_by TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_resolutions_question ON resolutions(question_id);

    -- Whether the question was ever actually put in front of a human, and if
    -- not, why. A question blocks an agent, so "we asked and nobody replied"
    -- must never be indistinguishable from "nobody was ever asked" — this is
    -- the column that keeps a broken notification path visible.
    CREATE TABLE IF NOT EXISTS deliveries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      question_id TEXT NOT NULL,
      surface TEXT NOT NULL,
      delivered INTEGER NOT NULL,
      detail TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_deliveries_question ON deliveries(question_id);
  `);
}

export function getDb(): QuestionDb {
  if (!_db) {
    const path = getDbPath();
    mkdirSync(dirname(path), { recursive: true });
    _db = new Database(path);
    _db.pragma("journal_mode = WAL");
    _db.pragma("busy_timeout = 5000");
    initSchema(_db);
  }
  return _db;
}

/** Test seam: point the module at a fresh database. */
export function setDb(db: QuestionDb): void {
  _db = db;
}

export function closeDb(): void {
  _db?.close();
  _db = null;
}

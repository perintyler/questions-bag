/**
 * The shape of a question, shared by the store, the service, and every UI.
 *
 * Deliberately wider than the coding agent's built-in picker, which forces
 * 1-4 questions of 2-4 options each behind a 12-character header. Those caps
 * suit a terminal popover and nothing else; a question that reaches a phone
 * or an app window has no such constraint. What is kept is the *shape* — an
 * agent that already knows how to ask can call this without relearning.
 */

/** How a single question is answered. */
export type QuestionKind = "choice" | "text" | "confirm";

export interface QuestionOption {
  label: string;
  description?: string;
  /**
   * Content rendered beside the option — a code snippet, a diff, an ASCII
   * mockup. The built-in supports this and Barry's old ask_question dropped
   * it, which made "show me both versions" impossible to ask well.
   */
  preview?: string;
}

export interface AskedQuestion {
  id: string;
  question: string;
  header?: string;
  kind: QuestionKind;
  options?: QuestionOption[];
  multiSelect: boolean;
  /**
   * Pre-selected in the UI. NOT returned on expiry — see `Outcome`. A default
   * is a convenience for the person answering, never a stand-in for them.
   */
  default?: string;
}

/** One person's reply to one question. */
export interface QuestionAnswer {
  questionId: string;
  /** Chosen option labels. Empty for a free-text answer. */
  selected: string[];
  /** Free text, for `kind: "text"` or an "other" reply to a choice. */
  text?: string;
}

export type QuestionState = "pending" | "answered" | "expired" | "dismissed";

export interface QuestionRecord {
  id: string;
  session_id: string | null;
  requester: string;
  context: string | null;
  questions: AskedQuestion[];
  answers: QuestionAnswer[] | null;
  state: QuestionState;
  answered_by: string | null;
  answered_at: string | null;
  expires_at: string;
  created_at: string;
}

/**
 * What the asking agent gets back.
 *
 * `answered` is the only field to branch on; the rest explain it. The three
 * unanswered states are kept apart on purpose:
 *
 * - `expired`   — nobody replied before the deadline
 * - `dismissed` — a human saw it and explicitly declined to answer
 *
 * If those collapsed into each other, or into an answer, a broken delivery
 * path would be invisible: every question would come back "no" and nothing
 * would say whether a human was ever involved. Same reasoning as the
 * denied/expired split in bags/approvals.
 */
export interface Outcome {
  answered: boolean;
  state: QuestionState;
  answers?: QuestionAnswer[];
  reason: string;
  question_id: string;
  /**
   * Present when the question could not be put in front of anyone. An agent
   * that sees this should say so rather than treating it as a refusal — it
   * means the asking machinery is broken, not that the user said no.
   */
  undelivered?: string;
}

/** Where an answer came from, or where delivery was attempted. */
export type Surface = "notification" | "app" | "web" | "cli" | "ios";

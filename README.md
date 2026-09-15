# questions

Ask the user a question and wait for the answer — with somewhere for it to land.

An agent calls `ask` and **blocks**. The question reaches the user as a macOS
notification (with the options as buttons, where they fit), in the Questions
app, and on a web page. Their answer comes back as an outcome.

```ts
const outcome = await ask({
  context: "Both sides rewrote the retry loop in src/db.ts.",
  questions: [{
    question: "Which retry implementation should survive the merge?",
    header: "Retry loop",
    options: [
      { label: "Ours", description: "Backoff with jitter", preview: "await sleep(2 ** i * 100)" },
      { label: "Theirs", description: "Fixed interval", preview: "await sleep(500)" },
    ],
  }],
  requester: "merge-worktree",
});

if (!outcome.answered) {
  // outcome.state is "expired" or "dismissed" — they are not the same thing
}
```

## Installing

```bash
git clone https://github.com/perintyler/questions-bag.git ~/repos/bags/questions
cd ~/repos/bags/questions && pnpm install
barry install ~/repos/bags/questions --as questions
barry pack questions
```

**The clone has to sit beside a Barry checkout.** `package.json` resolves
`@barry-rocks/tools` and `@barry-rocks/logger` through `link:../../barry/...`,
the same convention every bag in the aggregator uses — so `~/repos/bags/questions`
alongside `~/repos/barry` works, and an arbitrary path fails to typecheck. The
tests pass either way, which makes the wrong layout easy to miss: run
`npx tsc --noEmit` to confirm.

**Pack this before relying on it.** Barry denies the coding agent's built-in
question picker for every session, so a barry without this bag packed has no way
to ask at all — not a degraded one, none. `questions` is not a default trait; it
reaches a session only through `barry pack`.

## Why this exists

The coding agent ships its own question picker, and it is a good one — in a
terminal. It does not exist anywhere else. A Barry session is very often a
background run, a cron, or an overnight job, so "ask the user" has to mean
something that reaches a person who is not watching a scrollback.

This bag replaces that picker outright rather than sitting beside it. It keeps
the familiar shape — several questions, options with descriptions, previews,
multi-select — and drops the limits that only made sense for a popover: there
is no cap on options, and a question with no options at all is free text rather
than an "Other" escape hatch.

## What is worth knowing before changing anything here

**`expired` and `dismissed` are deliberately different.** Both mean "no answer",
but "nobody ever saw it" and "a human looked at it and declined" call for
different responses. If they looked alike, a broken notification path would be
invisible — every question would come back unanswered and nothing would say
whether a person was ever involved.

**A declared `default` is never returned as an answer.** It pre-selects in the
UI, for the convenience of whoever is answering. Returning it on expiry would
collapse "they chose this" into "nobody was asked", which is the exact ambiguity
the state split exists to prevent.

**Delivery is recorded, including its failures.** `UNUserNotificationCenter.add`
succeeds silently when notifications are denied, so an app that only reported
successes would let a question nobody can see look exactly like a question
nobody has answered yet. The `deliveries` table carries both, and `ask` warns
after 30 seconds if no surface has picked a question up — rather than making the
agent sit out the full deadline before mentioning it.

**An outcome is a value, not an exception.** `ask` does not throw when the user
declines; a refusal is an answer. It throws only when it cannot get one.

**Only `pending` can transition.** The guard is in each `UPDATE`'s `WHERE`
clause, so whoever gets there first owns the outcome — the person tapping a
notification button, the app, the web page, or the sweeper. Without it a late
tap could flip an already-expired question to answered *after* the agent was
told it expired and acted on that.

**The schema is inlined** in `src/db.ts` rather than read from a `migrations/`
directory. That pattern resolves SQL through `import.meta.url`, which breaks the
moment esbuild bundles this bag into `~/Library/Caches/Barry/bags`.

**Every client authenticates, including the page this service serves.** The web
UI collects the secret from the loopback-only `/config` route instead of the
service exempting same-origin requests. One code path means a broken guard shows
up as a 401 rather than as silently open access.

## Layout

| Path | What it is |
|---|---|
| `src/store.ts` | The state machine and its guards |
| `src/db.ts` | Schema (`~/.barry/questions.db`, `BARRY_QUESTIONS_DB`) |
| `src/types.ts` | The question shape, shared by every surface |
| `src/tools.ts` | `ask`, `list`, `status` |
| `server/src/index.ts` | HTTP service on 3869, the expiry sweeper, and the web page |
| `server/src/health.ts` | Whether deadlines are actually being enforced |
| `web/` | The web UI |
| `questions-app/` | The native macOS app (SwiftUI) |

The service exists because the UIs cannot open a bag's SQLite file. Its
`/health` reports the sweeper's last run and **503s when it goes stale** — a
service answering a bare "ok" with a dead sweeper would leave questions pending
forever behind a green light.

## Tests and QA

```bash
pnpm test                          # store + health
cd questions-app && swift test     # model decoding + notification routing
```

[QA.md](QA.md) covers the rest, including the checks worth running by hand: that
removing the transition guard turns exactly four tests red, that a dead sweeper
drives `/health` to 503, and that a question with a declared default still
expires rather than answering itself. A suite that has never failed is a claim,
not evidence.

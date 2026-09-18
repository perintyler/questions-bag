# questions-ios

Answer agent questions from a phone.

An agent that calls `mcp__questions__ask` **blocks** until someone answers or
the TTL (4h by default) runs out. Before this app the only answer surfaces were
a macOS app, a macOS notification and a loopback web page — so away from the Mac
an agent simply waited out the clock and came back `expired`.

## Running it

```bash
barry ios build questions --simulator "iPhone 16 Pro"
barry ios build questions --device
./scripts/test.sh
```

## Reaching the Mac

| | Base URL | Secret |
|---|---|---|
| Simulator | `http://127.0.0.1:3869` | **required** — the service checks every route |
| Device | `https://barry-mac.tail5cb2f2.ts.net:8446` | **required** |

The service binds `127.0.0.1`. A userspace `tailscaled` sidecar terminates TLS
on the tailnet and proxies to it, so a raw service port is still not reachable
from a phone.

The device address is a stable tailnet DNS name on purpose. It used to be a
hardcoded Tailscale IP plus a `Host: questions.barry.lan` header selecting a
Caddy site block, with a note to re-check the IP using `tailscale ip -4` — and
it went stale anyway when the node it named went offline, leaving the device
path dead. A name that Tailscale resolves removes the maintenance instead of
rescheduling it. The endpoint proxies to this service alone, so there is no
host header to set. The certificate is a real Let's Encrypt one, so there is
nothing to trust manually.

**Unlike the events feed, nothing injects a secret on this path.** The questions
service authenticates every route itself, so the secret is required on a device
and is entered once into the keychain. The app deliberately does *not* use the
service's `/config` route to fetch it: a client that bootstraps its credential
from an unauthenticated endpoint does not really have one. (That route is also
loopback-only, and since this app it refuses proxied callers too — otherwise
putting the service behind Caddy would have published `BARRY_SECRET` to the
whole tailnet.)

> The Tailscale address **changes** — this Mac moved twice in a day. The shipped
> default is a starting point; Settings overrides and persists it. Find the
> current one with `tailscale ip -4`.

## What the store actually contains

`src/store.ts` persists the `questions` payload **verbatim**. Only the MCP `ask`
tool mints per-question ids and infers `kind`, so a record created straight over
HTTP keeps whatever its caller sent. Real rows in the live store carry
`kind: null`, `multiSelect: null` and `id: null`.

The macOS app's model declares all three non-optional, so porting it as-is fails
to decode those records — the whole list, not just the odd row. This model
decodes them: `kind` is inferred from the presence of options (mirroring
`inferKind`), `multiSelect` defaults to false, and a missing `id` is synthesised
positionally because the answer POST is keyed by it.

Timestamps are SQLite `datetime('now')` output (`YYYY-MM-DD HH:MM:SS`, UTC), not
ISO8601 — an ISO8601 parser returns nil and the countdown silently disappears.

## Behaviour worth knowing

- **Drafts survive polling.** The app refreshes every 5s; selections and typed
  text live in the store, not the view, so a poll landing mid-answer cannot
  discard them. Losing a half-written answer would make the app worse than not
  having it.
- **A declared `default` is seeded once**, on first sight. Re-seeding every poll
  would reinstate a default five seconds after someone deliberately cleared it.
  A default is never submitted on the reader's behalf — an unanswered question
  expires, and the agent is told so.
- **Answer is disabled until every question is answered.** A partial reply would
  hand the agent a decision nobody made.
- **409 is an outcome, not an error.** Two people can answer at once, and a
  question can expire mid-reply. The service returns the record that actually
  stands; the app shows it plainly ("someone answered this first") rather than
  in red next to genuine failures.
- **Delivery is reported.** The app POSTs `surface: "ios"` on first sight of a
  pending question, so `ask`'s 30-second "nobody has seen this" warning stays
  meaningful instead of firing at a reader who is looking right at it.

## No push notifications

The app only shows a question while it is open. Real push needs a paid team and
an APNs entitlement, which conflicts with signing under a free personal team
(`device: true`). **If the phone should buzz when an agent asks, that changes
the signing story** and is worth settling before building on this.

## Layout

| Path | What it is |
|---|---|
| `App/Question.swift` | the model; decodes what the store actually holds |
| `App/QuestionsClient.swift` | `URLSession` client; 409 surfaces as `SettleOutcome` |
| `App/AppStore.swift` | records, drafts, default seeding, settling |
| `App/Views/QuestionListView.swift` | pending cards, options with previews, settled list |
| `Tests/` | decoding vs real payloads, draft behaviour, live service |

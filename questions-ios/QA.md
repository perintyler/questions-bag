<!-- tools: Bash,Read -->
# QA — questions-ios

24 tests: `./scripts/test.sh`. Every check below has a **negative control** that
was run and confirmed red, then reverted.

## Verified negative controls

| # | Check | Break it by | Confirmed result |
|---|---|---|---|
| 1 | a poll never discards a draft | clear `selections`/`freeText` on refresh | 2 tests red: `("")` is not `("half a thought")` |
| 2 | a default seeds only once | drop the `seededDefaults` guard | red: "the poll reinstated a default the reader had cleared" |
| 3 | the model decodes real rows | make `kind` non-optional (the macOS shape) | red against the LIVE store: `keyNotFound("kind")` |
| 4 | `ios` is an accepted surface | remove `"ios"` from `SURFACES` in the service | live answer returns **400**, not 200 |
| 5 | `/config` refuses proxied callers | restore the socket-only guard | 3 loopback tests red |

#3 is the one that matters most: it fails against **live data**, proving a direct
port of the macOS model would have broken on records that exist right now.

## End-to-end, verified against the running service

```
questions.barry.lan/health  -> 200   (phone can reach it, over Caddy)
questions.barry.lan/config  -> 403   (the secret is NOT exposed)
127.0.0.1:3869/config       -> 200   (the web page still works)
answer answered_by:"ios"    -> 200, state=answered, answered_by=ios
second answer               -> 409, the FIRST answer stands
deliveries table            -> ios|1  (delivery reported from the app)
```

Confirmed in the simulator against the real service: a question with a header,
option descriptions, a monospace `preview` block, a seeded default and a
free-text field renders correctly; Answer stays disabled until the free-text
question is filled in; answering moves the record into **Settled** showing
`ANSWERED · via ios` on the next poll.

## Manual checks (only a device can prove these)

- [ ] `barry ios build questions --device`, then trust the certificate under
      Settings → General → VPN & Device Management.
- [ ] Enter the secret in Settings; "Test connection" succeeds, and fails
      visibly with a wrong secret. (`/health` needs no auth precisely so
      "server down" and "wrong secret" stay distinguishable.)
- [ ] **Wi-Fi off.** Over cellular the app must still reach the Mac via
      Tailscale — the check that would have caught `point-guard-ios`'s dead
      device path.
- [ ] Answer a real `mcp__questions__ask` from the phone and confirm the agent
      unblocks with that answer.
- [ ] Start typing, wait past a 5s poll, confirm the text survives.
- [ ] Two devices answering at once: the loser sees "Already settled" with the
      winning answer, not an error.

## Known gaps

- No push notifications; the app updates only while open (see README).
- No UI test target; the views are exercised manually.

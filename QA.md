<!-- tools: Bash,Read -->
# QA: questions

Ask the user a question and wait for the answer. This bag owns the store, an
HTTP service the UIs can reach, the web page, and the native macOS app.

Every check below has a **negative control** — a way of confirming it can
actually fail. A check whose broken state looks like its healthy one is worse
than no check, and this bag's whole job is making "nobody answered" and "nobody
was ever asked" distinguishable.

## Requirements

- Node 22+, pnpm
- Xcode 16+ (for the app)
- `pnpm install` has been run in this directory

## Setup

```bash
cd ~/repos/bags/questions
export QA_DB=/tmp/questions-qa.db
rm -f "$QA_DB" "$QA_DB"-wal "$QA_DB"-shm
export BARRY_QUESTIONS_DB="$QA_DB"
# A port nothing else uses, so QA never collides with the deployed service.
export BARRY_QUESTIONS_PORT=3879
```

## Test steps

### 1. Compiles

```bash
cd ~/repos/bags/questions && npx tsc --noEmit
```

**Expected:** exit 0, no output.

### 2. Unit tests pass

```bash
cd ~/repos/bags/questions && pnpm test
```

**Expected:** 22 passed.

### 3. The transition guard actually guards

The point of the store is that a settled question cannot be overwritten.
Confirm the tests fail when the guard is gone, rather than trusting a green run:

```bash
cd ~/repos/bags/questions
cp src/store.ts /tmp/store.bak
sed -i '' "s/WHERE id = ? AND state = 'pending'\`/WHERE id = ?\`/g" src/store.ts
pnpm test 2>&1 | grep -E "Tests "
cp /tmp/store.bak src/store.ts
```

**Expected:** 4 failed — "refuses a second answer", "cannot revive an expired
question", "writes one resolution row per real transition", and "refuses to
dismiss a settled question". If they still pass, the guard is doing nothing and
the suite is not proving what it claims.

### 4. A dead sweeper turns /health red

```bash
cd ~/repos/bags/questions
cp server/src/health.ts /tmp/health.bak
sed -i '' 's/const healthy = age !== null && age < staleAfterMs;/const healthy = true;/' server/src/health.ts
pnpm test 2>&1 | grep -E "Tests "
cp /tmp/health.bak server/src/health.ts
```

**Expected:** 3 failed. A health check that cannot report unhealthy converts
"deadlines stopped being enforced" into a green light.

Live form, with the service running:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3879/health
```

**Expected:** `200` while the sweeper runs. Stop the service and the same call
fails to connect — a 503 appears only while the process lives but its sweeper
has gone stale (exercised by the unit test above).

### 5. A declared default never answers for the user

This is the control that matters most. A default is a UI convenience; if it
could be returned on expiry, "they chose this" and "nobody was asked" would be
the same value.

```bash
cd ~/repos/bags/questions
cat > ./qa-default.ts <<'EOF'
import { createQuestion, sweepExpired, getQuestion } from "./src/store.js";
const q = createQuestion({
  requester: "qa", ttlMinutes: -1,
  questions: [{ id: "q1", question: "Deploy to prod?", kind: "choice", multiSelect: false,
                default: "Yes", options: [{ label: "Yes" }, { label: "No" }] }],
});
sweepExpired();
const after = getQuestion(q.id)!;
console.log(after.state === "expired" && after.answers === null
  ? "PASS — the default was not substituted for an answer"
  : "FAIL — a default leaked into the answer");
EOF
pnpm exec tsx ./qa-default.ts; rm -f ./qa-default.ts
```

**Expected:** `PASS`.

### 6. The service round trip

Start it, then exercise the lifecycle:

```bash
cd ~/repos/bags/questions && pnpm start &
sleep 5
S=$(curl -s http://127.0.0.1:3879/config | python3 -c 'import sys,json; print(json.load(sys.stdin)["secret"])')

# create
ID=$(curl -s -X POST http://127.0.0.1:3879/questions -H "Authorization: Bearer $S" \
  -H 'Content-Type: application/json' \
  -d '{"requester":"qa","questions":[{"id":"q1","question":"Which database?","kind":"choice","multiSelect":false,"options":[{"label":"Postgres"},{"label":"SQLite"}]}]}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')

# answer, then try to answer again
curl -s -o /dev/null -w 'first answer: %{http_code}\n' -X POST "http://127.0.0.1:3879/questions/$ID/answer" \
  -H "Authorization: Bearer $S" -H 'Content-Type: application/json' \
  -d '{"answers":[{"questionId":"q1","selected":["SQLite"]}],"answered_by":"web"}'
curl -s -o /dev/null -w 'second answer: %{http_code}\n' -X POST "http://127.0.0.1:3879/questions/$ID/answer" \
  -H "Authorization: Bearer $S" -H 'Content-Type: application/json' \
  -d '{"answers":[{"questionId":"q1","selected":["Postgres"]}],"answered_by":"app"}'
```

**Expected:** `first answer: 200`, `second answer: 409`. Then confirm the first
answer is the one that stands.

### 7. Auth cannot be bypassed

```bash
curl -s -o /dev/null -w 'no secret:    %{http_code}\n' http://127.0.0.1:3879/questions
curl -s -o /dev/null -w 'wrong secret: %{http_code}\n' -H "Authorization: Bearer nope" http://127.0.0.1:3879/questions
curl -s -o /dev/null -w 'real secret:  %{http_code}\n' -H "Authorization: Bearer $S" http://127.0.0.1:3879/questions
```

**Expected:** `401`, `401`, `200`. All three matter — a run where the first two
also returned 200 would mean the guard is absent, not that the secret is right.

### 8. The web UI answers a real question

Open <http://127.0.0.1:3879/> with a pending question in the store.

**Expected:** the question renders with its options, any `preview` blocks shown
beside their labels, and a free-text box for an options-less question. The
Answer button is **disabled** until every question has something in it. After
answering, the card moves to the settled list showing the answer and `via web`.

### 9. The app builds, and its tests pass

```bash
cd ~/repos/bags/questions/questions-app && swift test
./build.sh
```

**Expected:** tests green; `Built: .build/Questions.app`. The build ends with
`codesign --verify --strict`, which fails loudly if the bundle was assembled
without re-signing — macOS refuses to launch an unverifiable bundle.

### 10. Undelivered notifications are visible

With the app running, turn off notification permission for Questions in System
Settings, then have an agent ask something.

**Expected:** within ~30 seconds the asking tool reports that nothing has shown
the question to anyone, and the app window shows the amber "Questions are not
reaching you as banners" panel. The question must NOT simply sit silently
pending — that is the failure this whole bag is built to make visible.

### 11. Registry health

```bash
barry bag doctor
```

**Expected:** no port conflict on 3869, no server key conflict, no dangling
trait namespace.

#!/usr/bin/env bash
# Full verification loop for the Questions iPhone app: regenerate the project, then
# run the whole suite against a real booted simulator, talking to the real
# locally-running Barry API. No mocks.
set -euo pipefail
cd "$(dirname "$0")/.."

SIM_NAME="${QUESTIONS_IOS_SIM:-iPhone 16 Pro}"
SCHEME="Questions"
API="http://127.0.0.1:3869/health"

export PATH="/opt/homebrew/bin:$PATH"

# Say out loud which suite you are getting. The live tests XCTSkip when the API
# is down, and a skip reads identically to a pass in the summary line — so the
# one thing this probe must never do is stay quiet about it.
echo "==> Checking the questions service is reachable (127.0.0.1:3869)..."
if curl -sf -m 3 "$API" >/dev/null; then
  echo "    reachable — live integration tests will RUN."
else
  echo "!!  NOT reachable — every live test will SKIP, not fail."
  echo "    Unit tests still run. Start the API with:"
  echo "      launchctl kickstart -k gui/\$(id -u)/com.barry.bag.questions.api"
fi

# Resolve the simulator to a UDID and target it by id, not by name.
#
# `-destination name:` goes ambiguous the moment a second simulator is booted —
# a stray iPhone 16 Pro Max once captured a run in a sibling bag and produced
# failures whose coordinates made no sense against the device under test.
SIM_ID=$(xcrun simctl list devices available \
  | awk -v name="$SIM_NAME" -F'[()]' '$0 ~ name "  *\\(" { print $2; exit }')
if [ -z "$SIM_ID" ]; then
  echo "error: no available simulator named '$SIM_NAME'" >&2
  echo "  Set QUESTIONS_IOS_SIM, or see: xcrun simctl list devices available" >&2
  exit 1
fi
echo "==> Simulator: ${SIM_NAME} (${SIM_ID})"

echo "==> Regenerating the Xcode project from project.yml..."
xcodegen generate

echo "==> Running the test suite..."
set +e
# -derivedDataPath pins the output where `barry ios build` also writes. Without
# it xcodebuild uses Xcode's shared DerivedData, and `simctl install` from the
# other path silently installs a STALE app — which cost three rounds of
# screenshots chasing a feature that was never in the binary under test.
xcodebuild -project "${SCHEME}.xcodeproj" -scheme "${SCHEME}" \
  -destination "platform=iOS Simulator,id=${SIM_ID}" \
  -derivedDataPath .build-barry-ios \
  test 2>&1 | tee /tmp/questions-ios-test.log \
  | grep -E "Test Case|Test Suite '(All tests|${SCHEME}Tests\.xctest)'|error:|\*\* TEST"
STATUS=${PIPESTATUS[0]}
set -e

echo ""
if [ "$STATUS" -eq 0 ]; then
  echo "All tests passed. (Check the log for skips: grep -c 'was skipped' /tmp/questions-ios-test.log)"
else
  echo "Tests failed. Full log: /tmp/questions-ios-test.log"
fi
exit "$STATUS"

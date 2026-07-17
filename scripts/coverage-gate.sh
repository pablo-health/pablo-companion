#!/bin/bash
#
# Fails if CompanionSessionCore's line coverage drops below MIN_COVERAGE.
#
# Scoped to CompanionSessionCore deliberately. That target is the shared session
# wire path — the queue, the coordinator, the upload client — and it is the code
# both the app and the headless harness run. It is also the only part of the mac
# codebase that `swift test` can exercise without launching the app, so it is the
# only place a coverage number means something today. The Xcode app target's
# tests are app-hosted: they boot a real window and block on Keychain dialogs, so
# gating on them would make CI hang rather than fail.
#
# This is a ratchet, not a target. Raise MIN_COVERAGE when real coverage rises;
# never lower it to make a red build green.
set -euo pipefail

MIN_COVERAGE="${MIN_COVERAGE:-85}"

cd "$(dirname "$0")/.."

swift test --enable-code-coverage >/dev/null 2>&1

PROFDATA=$(find .build -name '*.profdata' -type f 2>/dev/null | head -1)
BINARY=$(find .build -name '*.xctest' -type d 2>/dev/null | head -1)

if [ -z "$PROFDATA" ] || [ -z "$BINARY" ]; then
  echo "error: no coverage data produced — did the tests build?" >&2
  exit 1
fi

EXECUTABLE="$BINARY/Contents/MacOS/$(basename "$BINARY" .xctest)"

# --sources restricts the report to the target under gate; without it the number
# is diluted by the test files themselves, which are ~100% covered by
# construction and would flatter the result.
REPORT=$(xcrun llvm-cov report "$EXECUTABLE" \
  -instr-profile="$PROFDATA" \
  $(find Sources/CompanionSessionCore -name '*.swift' | sed 's/^/--sources /' | tr '\n' ' ') \
  2>/dev/null)

# TOTAL row, line-coverage column.
COVERAGE=$(echo "$REPORT" | awk '/^TOTAL/ {gsub(/%/, "", $10); print $10}')

if [ -z "$COVERAGE" ]; then
  echo "error: could not parse coverage from llvm-cov report" >&2
  echo "$REPORT" >&2
  exit 1
fi

echo "$REPORT" | awk 'NR>2 && NF>5 {printf "  %-42s %8s\n", $1, $10}'
echo ""
printf "CompanionSessionCore line coverage: %s%% (minimum %s%%)\n" "$COVERAGE" "$MIN_COVERAGE"

if awk "BEGIN {exit !($COVERAGE < $MIN_COVERAGE)}"; then
  echo "error: coverage $COVERAGE% is below the $MIN_COVERAGE% floor" >&2
  echo "Add tests, or justify lowering MIN_COVERAGE in the PR description." >&2
  exit 1
fi

echo "Coverage gate passed."

#!/usr/bin/env bash
#
# Runs Waystage's test suites and records every run in test-logs/.
#
#   scripts/test-all.sh            # all suites available on this machine
#   scripts/test-all.sh quick      # core + gateway (used by the pre-push hook)
#   scripts/test-all.sh core       # Swift package: unit + integration tests (macOS or Linux)
#   scripts/test-all.sh gateway    # Backend gateway: lint, typecheck, vitest
#   scripts/test-all.sh ios        # Xcode: package tests on iOS, app unit tests, XCUITests (macOS only)
#
# Outputs
#   test-logs/TEST_LOG.md          one row per suite per run (committed history)
#   test-logs/runs/<stamp>.md      per-run report with failing tests (committed)
#   test-logs/raw/<stamp>/         full console output, JUnit/xcresult (git-ignored, CI artifact)
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
MODE="${1:-all}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
HUMAN_TIME="$(date -u +'%Y-%m-%d %H:%M:%SZ')"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo 'no-git')"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then COMMIT="${COMMIT}+dirty"; fi
LOG_DIR="$ROOT/test-logs"
RAW_DIR="$LOG_DIR/raw/$STAMP"
RUN_FILE="$LOG_DIR/runs/$STAMP.md"
HISTORY="$LOG_DIR/TEST_LOG.md"
mkdir -p "$RAW_DIR" "$LOG_DIR/runs"

# Prefer a toolchain on PATH; fall back to a locally extracted one (Linux CI/dev containers).
if ! command -v swift >/dev/null 2>&1 && [ -x /opt/swift/usr/bin/swift ]; then
  export PATH="/opt/swift/usr/bin:$PATH"
fi

if [ ! -f "$HISTORY" ]; then
  cat > "$HISTORY" <<'HEADER'
# Test run history

Every execution of `scripts/test-all.sh` (locally, in the pre-push hook, or in CI) appends one
row per suite. Per-run details, including the names of failing tests, are in `runs/`.

| When (UTC) | Commit | Suite | Result | Tests | Duration | Details |
|---|---|---|---|---|---|---|
HEADER
fi

{
  echo "# Test run $HUMAN_TIME"
  echo
  echo "- Commit: \`$COMMIT\`"
  echo "- Mode: \`$MODE\`"
  echo "- Host: \`$(uname -sm)\`"
  command -v swift >/dev/null 2>&1 && echo "- Swift: \`$(swift --version 2>/dev/null | head -1)\`"
  command -v node >/dev/null 2>&1 && echo "- Node: \`$(node --version)\`"
  command -v xcodebuild >/dev/null 2>&1 && echo "- Xcode: \`$(xcodebuild -version | head -1)\`"
  echo
} > "$RUN_FILE"

OVERALL=0

# record <suite> <status: pass|fail|skipped> <tests> <seconds> <raw log>
record() {
  local suite="$1" status="$2" tests="$3" seconds="$4" raw="$5" icon
  case "$status" in
    pass) icon="✅ pass" ;;
    fail) icon="❌ fail"; OVERALL=1 ;;
    *) icon="⏭️ skipped" ;;
  esac
  echo "| $HUMAN_TIME | \`$COMMIT\` | $suite | $icon | $tests | ${seconds}s | [runs/$STAMP.md](runs/$STAMP.md) |" >> "$HISTORY"
  {
    echo "## $suite — $icon"
    echo
    echo "- Tests: $tests"
    echo "- Duration: ${seconds}s"
    [ -n "$raw" ] && echo "- Raw output: \`test-logs/raw/$STAMP/$(basename "$raw")\`"
    if [ "$status" = "fail" ] && [ -f "$raw" ]; then
      echo
      echo "Failures:"
      echo
      echo '```'
      failure_lines "$raw"
      echo '```'
    fi
    echo
  } >> "$RUN_FILE"
  printf '%-28s %s (%s, %ss)\n' "$suite" "$icon" "$tests" "$seconds"
  # Also print failures to the console so CI job logs show them without downloading artifacts.
  if [ "$status" = "fail" ] && [ -f "$raw" ]; then
    echo "  ── failures ($suite) ──"
    failure_lines "$raw" | sed 's/^/  /'
    echo "  ── last lines ──"
    tail -25 "$raw" | sed 's/^/  /'
  fi
}

failure_lines() {
  grep -E "✘|recorded an issue|error:|FAIL|failed|Failing tests|Test Case .* failed|Testing cancelled|crashed" "$1" \
    | grep -v "^✔" | awk '!seen[$0]++' | head -80
}

# run_suite <suite> <raw-log-name> <count-extractor> <command...>
run_suite() {
  local suite="$1" logname="$2" extractor="$3"; shift 3
  local raw="$RAW_DIR/$logname" start end status tests
  echo "▶ $suite"
  start=$(date +%s)
  if "$@" > "$raw" 2>&1; then status=pass; else status=fail; fi
  end=$(date +%s)
  tests="$($extractor "$raw")"
  record "$suite" "$status" "${tests:-?}" "$((end - start))" "$raw"
}

swift_count() { grep -Eo "Test run with [0-9]+ tests?" "$1" | tail -1 | grep -Eo "[0-9]+" | sed 's/$/ tests/'; }
vitest_count() { grep -E "^\s+Tests\s+" "$1" | tail -1 | sed -E 's/^\s+Tests\s+//'; }
# xcodebuild runs both XCTest ("Executed N tests") and Swift Testing ("Test run with N tests").
xcode_count() {
  local xctest swifttesting
  xctest=$(grep -Eo "Executed [0-9]+ tests?, with [0-9]+ failures?" "$1" | tail -1)
  swifttesting=$(grep -Eo "Test run with [0-9]+ tests?" "$1" | tail -1 | grep -Eo "[0-9]+")
  echo "${swifttesting:+$swifttesting Swift Testing tests; }${xctest:-no XCTest run}"
}
none_count() { echo "-"; }

core_suite() {
  if ! command -v swift >/dev/null 2>&1; then
    record "core (Swift package)" skipped "-" 0 ""
    return
  fi
  run_suite "core (Swift package)" "core-swift-test.log" swift_count \
    swift test --package-path Packages/WaystageKit --parallel --xunit-output "$RAW_DIR/core-junit.xml"
}

gateway_suite() {
  if ! command -v npm >/dev/null 2>&1; then
    record "gateway (lint+types)" skipped "-" 0 ""
    record "gateway (vitest)" skipped "-" 0 ""
    return
  fi
  (cd Backend/gateway && npm ci --no-audit --no-fund >"$RAW_DIR/gateway-npm-ci.log" 2>&1)
  run_suite "gateway (lint+types)" "gateway-static.log" none_count \
    bash -c "cd Backend/gateway && npm run --silent lint && npm run --silent typecheck"
  run_suite "gateway (vitest)" "gateway-vitest.log" vitest_count \
    bash -c "cd Backend/gateway && npx vitest run --outputFile.junit='$RAW_DIR/gateway-junit.xml'"
}

pick_simulator() {
  xcrun simctl list devices available 2>/dev/null | grep -Eo "iPhone [0-9]+( Pro)?( Max)? \(" | head -1 | sed 's/ ($//'
}

ios_suite() {
  if ! command -v xcodebuild >/dev/null 2>&1; then
    record "iOS package tests" skipped "-" 0 ""
    record "iOS app unit + UI tests" skipped "-" 0 ""
    echo "  (xcodebuild not available — run on macOS with Xcode 26+)" | tee -a "$RUN_FILE"
    return
  fi
  local device="${IOS_SIMULATOR:-$(pick_simulator)}"
  local destination="platform=iOS Simulator,name=$device"
  command -v xcodegen >/dev/null 2>&1 && xcodegen generate --quiet
  run_suite "iOS package tests" "ios-package.log" xcode_count \
    bash -c "cd Packages/WaystageKit && xcodebuild test -scheme WaystageKit-Package -destination '$destination' -resultBundlePath '$RAW_DIR/package.xcresult' CODE_SIGNING_ALLOWED=NO"
  run_suite "iOS app unit + UI tests" "ios-app.log" xcode_count \
    xcodebuild test -project Waystage.xcodeproj -scheme Waystage -destination "$destination" \
      -resultBundlePath "$RAW_DIR/app.xcresult" CODE_SIGNING_ALLOWED=NO
}

case "$MODE" in
  core) core_suite ;;
  gateway) gateway_suite ;;
  ios) ios_suite ;;
  quick) core_suite; gateway_suite ;;
  all) core_suite; gateway_suite; ios_suite ;;
  *) echo "Unknown mode: $MODE (use all|quick|core|gateway|ios)"; exit 2 ;;
esac

echo
if [ "$OVERALL" -eq 0 ]; then
  echo "All requested suites passed. Log: test-logs/runs/$STAMP.md"
else
  echo "Some suites FAILED. See test-logs/runs/$STAMP.md"
fi
exit "$OVERALL"

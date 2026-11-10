#!/bin/sh
# The app's tests natively on this Mac, on the command line's build of the engine (docs/CLI.md):
# no iPhone, no Xcode test host. For work on the runtime; a change that ships still gets its
# iPhone run (scripts/device-harness.sh).
#
# Usage:
#   scripts/cli-test.sh unit [Class[/method] ...]
#       The unit tests that need no interface, on the scripted engine (about a minute).
#   scripts/cli-test.sh inference|files|web|thinking|probes|calibrate [Class[/method] ...]
#       The real-model scenarios of that suite, on this Mac's GPU: a Mac run, ask first.
#
#   scripts/cli-test.sh unit AppStateTests
#   scripts/cli-test.sh inference InferenceScenarioTests/test05_ToolCall
#
# Env: LITERTLM_PACKAGE (the runtime to build against, as for the command line; default
#      Vendor/LiteRT-LM), AGELLO_TELEMETRY (the engine's telemetry level, default 2).
# The tests run with their home folder redirected to build/cli/test-home, so they never touch
# this Mac's own Library, Documents or settings; models are read from ~/Models/agello and
# never changed. Not here: the interface's tests, the memory envelopes and the UI suites.
# Outputs: build/cli/test/<suite>.log, and build/cli/test/harness-report.json for the scenarios.
# Exit: 0 passed, 1 failed, 2 usage, 3 another run holds the harness lock.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUITE="${1:-}"
[ $# -gt 0 ] && shift
SCRATCH="$ROOT/build/cli/test"
HOME_DIR="$ROOT/build/cli/test-home"

case "$SUITE" in
  unit) bundle=AgelloTests; classes="" ;;
  inference) bundle=AgelloDeviceTests; classes="InferenceScenarioTests" ;;
  files) bundle=AgelloDeviceTests; classes="KnowledgeScenarioTests" ;;
  web) bundle=AgelloDeviceTests; classes="WebScenarioTests" ;;
  thinking) bundle=AgelloDeviceTests; classes="ThinkingScenarioTests"; export HARNESS_THINKING=1 ;;
  probes) bundle=AgelloDeviceTests; classes="ProbeScenarioTests"; export HARNESS_PROBES=1 ;;
  calibrate) bundle=AgelloDeviceTests; classes="CalibrationScenarioTests"; export HARNESS_CALIBRATE=1 ;;
  *) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
[ $# -gt 0 ] && classes="$*"

if [ "$bundle" = AgelloDeviceTests ]; then
  # A real-model run: one at a time on this Mac, with the iPhone's harness too.
  # shellcheck source=scripts/lib/harness-lock.sh
  . "$ROOT/scripts/lib/harness-lock.sh"
  LOCK="$(harness_lock_dir "$ROOT")"
  mkdir -p "$(dirname "$LOCK")"
  if ! mkdir "$LOCK" 2>/dev/null; then
    sleep 1
    if running="$(harness_lock_info "$LOCK")"; then
      echo "Another run is in progress ($LOCK):" >&2
      echo "$running" | sed 's/^/  /' >&2
      exit 3
    fi
    rm -rf "$LOCK"
    mkdir "$LOCK"
  fi
  trap 'rm -rf "$LOCK"' EXIT
  trap 'exit 130' HUP INT TERM
  printf 'pid=%s\nroot=%s\nplatform=mac\nsuite=cli-test %s\nlog=%s\nlast=yes\nstarted=%s\n' \
    $$ "$ROOT" "$SUITE" "$SCRATCH/$SUITE.log" "$(date '+%Y-%m-%d %H:%M')" >"$LOCK/info"
  caffeinate -dims -w $$ &
fi

mkdir -p "$SCRATCH" "$HOME_DIR"
echo "Building the tests…"
if ! (cd "$ROOT" && swift build --build-tests --scratch-path "$SCRATCH") >"$SCRATCH/build.log" 2>&1; then
  sed 's/\x1b\[[0-9;]*m//g' "$SCRATCH/build.log" | grep -E ':[0-9]+:[0-9]+: error:' | sed "s|$ROOT/||" | head -10 >&2
  echo "The tests didn't build: $SCRATCH/build.log" >&2
  exit 1
fi

# xctest takes one -XCTest with a comma-separated list.
list=""
for class in $classes; do list="${list:+$list,}$bundle.$class"; done
filters=""
[ -z "$list" ] || filters="-XCTest $list"
if [ "$bundle" = AgelloDeviceTests ]; then
  # Models and caches as the command line uses them: read only, one cache root per runtime build.
  build="$("$SCRATCH/debug/agello" env --trace-dir "$SCRATCH/env-traces" 2>/dev/null \
    | python3 -c 'import json, sys; print((json.load(sys.stdin)["machine"].get("runtimeBuild") or {}).get("build_id", "no-build-id"))')"
  rm -rf "$SCRATCH/env-traces" "$SCRATCH/runtime.log"
  export AGELLO_MODELS_DIR="$HOME/Models/agello"
  export AGELLO_ENGINE_CACHE_DIR="$HOME/Models/agello/cache/agello-cli/$build"
  export AGELLO_TELEMETRY="${AGELLO_TELEMETRY:-2}"
  export HARNESS_RUN_ID="cli-$(date +%Y%m%d-%H%M%S)"
fi

LOG="$SCRATCH/$SUITE.log"
status=0
# shellcheck disable=SC2086 # the filters are separate words
CFFIXED_USER_HOME="$HOME_DIR" xcrun xctest $filters "$SCRATCH/debug/$bundle.xctest" >"$LOG" 2>&1 || status=$?
grep -E "^Test Case .* (failed|passed)|: error: " "$LOG" | grep -E "failed|error" | sed "s|$ROOT/||" | cut -c1-240 | head -30
grep -E "Executed [0-9]+ tests?" "$LOG" | tail -1 | sed 's/^[[:space:]]*//'
if [ "$bundle" = AgelloDeviceTests ] && [ -f "$HOME_DIR/Documents/harness-report.json" ]; then
  cp "$HOME_DIR/Documents/harness-report.json" "$SCRATCH/harness-report.json"
  echo "Report: $SCRATCH/harness-report.json"
fi
echo "Log: $LOG"
[ "$status" -eq 0 ] || exit 1

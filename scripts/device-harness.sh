#!/bin/sh
# On-device test harness for Agello: the physical iPhone, or this Mac running
# the iPhone app (PLATFORM=mac). Never the simulator.
#
# Usage:
#   scripts/device-harness.sh [unit|inference|files|web|ui|all|thinking|memory|calibrate|probes|screenshots|bench] [extra xcodebuild args...]
#
#   unit       Unit tests (planner, budgets, schema, markdown, files, projects,
#              the app pipeline through the scripted engine), on the iPhone.
#   inference  In-app scenarios through the real engine (download, load, text,
#              chat isolation, stop, tools, thinking, image, audio, settings
#              round-trip, context limit, titles, benchmark). Downloads E4B if missing.
#   files      Files with the real models: EmbeddingGemma indexing and retrieval,
#              "summarize this 40-page PDF", cited follow-up.
#   web        Live web search with the real model (needs internet): cited
#              answer, planned follow-up, automatic mode.
#   ui         Real-tap flows (send, Stop, Home button mid-reply, leave/return
#              mid-reply, drawer, projects, files, message actions, Think,
#              keyboard, Settings). Needs E4B downloaded.
#   thinking   Long Thinking-mode scenarios (issue #703 prompt, budgets up to 2K).
#   calibrate  Context-size calibration: memory and speed at 4K-32K KV caches.
#   probes     LiteRT-LM feature probes (helper conversation, JSON, embeddings).
#   memory     Memory pressure simulation (E4B at 6.0/5.0/4.0/3.5 GB usable).
#   screenshots  A guided UI tour with the real model: one screenshot per
#              screen (attachments/screenshots/) for the README and App Store.
#   bench      The autonomous harness (docs/HARNESS.md): each bench case sent
#              through the app's screens in a Release build, the app tracing
#              the reply; traces pulled and joined in bench/report.md.
#              BENCH_ONLY=id,id runs some cases; BENCH_RESUME=1 runs only those
#              the last report doesn't hold complete; BENCH_COOL=1 waits for
#              the phone to cool before each case (for speeds); BENCH_ACCEPT=1
#              makes this run the baseline later runs are compared with
#              (scripts/bench/baseline.json); BENCH_TRACE=off runs without the
#              app's trace (screen timings only). iPhone only.
#   all        unit, inference + files + web, then ui.
#
# Env: PLATFORM (iphone, the default; mac: this Mac runs the iPhone app
#      "Designed for iPad/iPhone" through its Metal path; ui, screenshots and
#      memory and bench stay iPhone-only, and `all` skips ui),
#      DEVICE_ID (iPhone only; default: deviceId from the git-ignored .mobilebuildmcp/config.yaml),
#      ONLY (run part of a suite: comma- or space-separated test identifiers
#      inside it, e.g. ONLY=AgelloTests/AppStateTests/testMockModeSendsWithoutDownloadedModel
#      scripts/device-harness.sh unit; not with `all`),
#      OUT (default: build/device-harness, build/mac-harness with PLATFORM=mac),
#      AGELLO_TELEMETRY (engine telemetry level in our LiteRT-LM builds, default 2),
#      AGELLO_SIMULATE_APPLE_GPU (our builds: another Apple GPU's kernel paths, e.g. "Apple A17 Pro";
#      a runtime debugging aid: no supported iPhone has that GPU),
#      XCBEAUTIFY (path to xcbeautify, or "off" for raw output; default:
#      Homebrew's, looked up directly so other xcbeautify copies in PATH are ignored).
# Outputs: $OUT/<suite>.xcresult, $OUT/<suite>.log (raw xcodebuild output),
#          $OUT/attachments/, $OUT/harness-report.json
# An iPhone run starts with a preflight: the phone reachable and unlocked,
# iPhone Mirroring closed, 10 GB free on this Mac. It exits with 4 and the one
# thing to fix (PREFLIGHT=off skips it).
# One run at a time on this machine: while another run holds the lock
# (build/.harness.lock in the main checkout), the script exits with 3.
# Other exit codes: 2 for a usage error, xcodebuild's otherwise (65: tests
# failed), and for bench 1 when the report finds a problem.
# The script keeps this Mac awake until it exits.
set -eu

SUITE="${1:-all}"
[ $# -gt 0 ] && shift
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORM="${PLATFORM:-iphone}"
case "$PLATFORM" in
  iphone)
    # shellcheck source=scripts/lib/device.sh
    . "$ROOT/scripts/lib/device.sh"
    resolve_device_id "$ROOT"
    OUT="${OUT:-$ROOT/build/device-harness}"
    ;;
  mac)
    case "$SUITE" in
      ui | screenshots | memory | bench)
        echo "The $SUITE suite runs on the iPhone only, not with PLATFORM=mac." >&2
        exit 2
        ;;
    esac
    # The Mac's destination id is its provisioning UDID.
    DEVICE_ID="$(system_profiler SPHardwareDataType | sed -n 's/.*Provisioning UDID: *//p')"
    OUT="${OUT:-$ROOT/build/mac-harness}"
    ;;
  *) echo "Unknown PLATFORM: $PLATFORM (iphone or mac)" >&2; exit 2 ;;
esac
SCHEME=Agello
DESTINATION="id=$DEVICE_ID"
UNIT_TESTS=AgelloTests
DEVICE_TESTS=AgelloDeviceTests

# One run at a time on this machine, from any checkout or worktree; the
# Claude Code hooks read the lock (scripts/lib/harness-lock.sh).
# shellcheck source=scripts/lib/harness-lock.sh
. "$ROOT/scripts/lib/harness-lock.sh"
LOCK="$(harness_lock_dir "$ROOT")"
mkdir -p "$(dirname "$LOCK")"
if ! mkdir "$LOCK" 2>/dev/null; then
  # A run that has just taken the lock may not have written its info yet.
  sleep 1
  if running="$(harness_lock_info "$LOCK")"; then
    echo "Another harness run is in progress ($LOCK):" >&2
    echo "$running" | sed 's/^/  /' >&2
    exit 3
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK"
fi
trap 'rm -rf "$LOCK"' EXIT
trap 'exit 130' HUP INT TERM
STARTED="$(date '+%Y-%m-%d %H:%M')"
LAST=yes
# Records the suite being run, whose log the hooks read.
write_lock_info() {
  printf 'pid=%s\nroot=%s\nplatform=%s\nsuite=%s\nlog=%s\nlast=%s\nstarted=%s\n' \
    $$ "$ROOT" "$PLATFORM" "$1" "$OUT/$1.log" "$LAST" "$STARTED" >"$LOCK/info.tmp"
  mv "$LOCK/info.tmp" "$LOCK/info"
}
# Keep this Mac awake until the script exits: an iPhone run needs it too.
caffeinate -dims -w $$ &

# Before an iPhone run builds anything: the one thing to fix, if there is one. A locked phone
# otherwise stalls the run at "Unlock iPhone to Continue" after the whole build.
preflight() {
  if ! xcrun devicectl list devices 2>/dev/null | grep "$DEVICE_ID" | grep -q "available\|connected"; then
    echo "Preflight: the iPhone ($DEVICE_ID) isn't reachable. Connect it, then run again." >&2
    return 4
  fi
  if xcrun devicectl device info lockState --device "$DEVICE_ID" 2>/dev/null | grep -q "passcodeRequired: true"; then
    if pgrep -f ScreenContinuity >/dev/null 2>&1; then
      echo "Preflight: the iPhone is locked and iPhone Mirroring is open, which keeps it locked. Close iPhone Mirroring and unlock the iPhone, then run again." >&2
    else
      echo "Preflight: the iPhone is locked. Unlock it (and keep it unlocked for the run), then run again." >&2
    fi
    return 4
  fi
  if pgrep -f ScreenContinuity >/dev/null 2>&1; then
    echo "Preflight: iPhone Mirroring is open. It connects when the phone locks and would stop the run: close it." >&2
    return 4
  fi
  free_gb="$(df -g / | awk 'NR == 2 {print $4}')"
  if [ "${free_gb:-99}" -lt 10 ]; then
    echo "Preflight: only $free_gb GB free on this Mac; a build needs room. Run scripts/storage.sh." >&2
    return 4
  fi
  return 0
}
if [ "$PLATFORM" = iphone ] && [ "${PREFLIGHT:-on}" != off ]; then
  preflight || exit 4
fi

BUNDLE_ID="com.patricedery.agello"
mkdir -p "$OUT"
write_lock_info "$SUITE"
# Lets the in-app report survive crash relaunches within this run only.
export TEST_RUNNER_HARNESS_RUN_ID="run-$(date +%s)"
# Engine telemetry level for our LiteRT-LM builds (ignored by Google's): 2 records span timings
# and GPU time at no measurable cost; each scenario's snapshot lands in its report entry.
export TEST_RUNNER_AGELLO_TELEMETRY="${AGELLO_TELEMETRY:-2}"
# Our LiteRT-LM builds: run another Apple GPU's kernel paths ("Apple A17 Pro"); empty for none.
if [ -n "${AGELLO_SIMULATE_APPLE_GPU:-}" ]; then
  export TEST_RUNNER_AGELLO_SIMULATE_APPLE_GPU="$AGELLO_SIMULATE_APPLE_GPU"
fi

# Homebrew's xcbeautify, by absolute path: PATH may list another copy first.
if [ "${XCBEAUTIFY:-}" = off ]; then
  XCBEAUTIFY=""
elif [ -z "${XCBEAUTIFY:-}" ]; then
  XCBEAUTIFY="$(brew --prefix 2>/dev/null || echo /opt/homebrew)/bin/xcbeautify"
fi
[ -n "$XCBEAUTIFY" ] && [ ! -x "$XCBEAUTIFY" ] && XCBEAUTIFY=""

format_output() {
  if [ -z "$XCBEAUTIFY" ]; then
    cat
  elif [ -t 1 ]; then
    "$XCBEAUTIFY"
  else
    "$XCBEAUTIFY" --disable-colored-output
  fi
}

xcodebuild_test() {
  xcodebuild test \
    -project "$ROOT/Agello.xcodeproj" -scheme "$SCHEME" -configuration "${CONFIGURATION:-Debug}" \
    -destination "$DESTINATION" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    -resultBundlePath "$result" "$@"
}

run_suite() {
  name="$1"
  shift
  result="$OUT/$name.xcresult"
  rm -rf "$result" "$OUT/$name.log"
  write_lock_info "$name"
  echo "==> $name"
  # sh has no pipefail: keep xcodebuild's exit status in a file.
  status_file="$OUT/.$name.status"
  set +e
  { xcodebuild_test "$@" 2>&1; echo $? >"$status_file"; } \
    | tee "$OUT/$name.log" | format_output
  suite_status="$(cat "$status_file")"
  rm -f "$status_file"
  set -e
  # Device suites print where the app wrote its report (copied on a Mac).
  printed="$(sed -n 's/^HARNESS_REPORT_PATH=//p' "$OUT/$name.log" | tail -n 1)"
  [ -n "$printed" ] && REPORT_PATH="$printed"
  # This run's attachments only (the manifest is rewritten each time).
  rm -rf "$OUT/attachments/$name"
  mkdir -p "$OUT/attachments/$name"
  xcrun xcresulttool export attachments --path "$result" \
    --output-path "$OUT/attachments/$name" >/dev/null 2>&1 || true
  return "$suite_status"
}

pull_report() {
  if [ "$PLATFORM" != iphone ]; then
    if [ -n "${REPORT_PATH:-}" ] && cp "$REPORT_PATH" "$OUT/harness-report.json" 2>/dev/null; then
      echo "Report: $OUT/harness-report.json"
    else
      echo "No harness report on this Mac"
    fi
    return 0
  fi
  xcrun devicectl device copy from --device "$DEVICE_ID" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source Documents/harness-report.json --destination "$OUT/harness-report.json" \
    >/dev/null 2>&1 && echo "Report: $OUT/harness-report.json" || echo "No harness report on device"
}

# -only-testing filters for the suite's scopes, or for ONLY's tests, which
# must be inside those scopes (opt-in suites set their environment above).
filters() {
  if [ -z "${ONLY:-}" ]; then
    for scope in "$@"; do printf ' -only-testing:%s' "$scope"; done
    return 0
  fi
  for test in $(echo "$ONLY" | tr ',' ' '); do
    in_suite=no
    for scope in "$@"; do
      case "$test" in "$scope" | "$scope"/*) in_suite=yes ;; esac
    done
    if [ "$in_suite" = no ]; then
      echo "ONLY: $test is not in the $SUITE suite ($*)" >&2
      return 2
    fi
    printf ' -only-testing:%s' "$test"
  done
}

status=0
scopes=""
case "$SUITE" in
  unit) scopes="$UNIT_TESTS" ;;
  inference) scopes="$DEVICE_TESTS/InferenceScenarioTests" ;;
  files) scopes="$DEVICE_TESTS/KnowledgeScenarioTests" ;;
  web) scopes="$DEVICE_TESTS/WebScenarioTests" ;;
  ui) scopes="AgelloUITests" ;;
  thinking)
    export TEST_RUNNER_HARNESS_THINKING=1
    scopes="$DEVICE_TESTS/ThinkingScenarioTests"
    ;;
  memory)
    export TEST_RUNNER_HARNESS_MEMORY=1
    scopes="$DEVICE_TESTS/MemoryEnvelopeScenarioTests"
    ;;
  probes)
    export TEST_RUNNER_HARNESS_PROBES=1
    scopes="$DEVICE_TESTS/ProbeScenarioTests"
    ;;
  calibrate)
    export TEST_RUNNER_HARNESS_CALIBRATE=1
    scopes="$DEVICE_TESTS/CalibrationScenarioTests"
    ;;
  screenshots)
    export TEST_RUNNER_HARNESS_SCREENSHOTS=1
    scopes="AgelloUITests/ScreenshotTourUITests"
    ;;
  bench)
    # Release, in a scheme of its own: the unit and device tests need @testable (Debug).
    export TEST_RUNNER_HARNESS_BENCH=1
    [ -n "${BENCH_ONLY:-}" ] && export TEST_RUNNER_BENCH_ONLY="$BENCH_ONLY"
    [ -n "${BENCH_TRACE:-}" ] && export TEST_RUNNER_BENCH_TRACE="$BENCH_TRACE"
    [ -n "${BENCH_COOL:-}" ] && export TEST_RUNNER_BENCH_COOL="$BENCH_COOL"
    SCHEME=AgelloBench
    CONFIGURATION=Release
    BENCH_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # Resuming: only the cases the last report doesn't hold complete; its other cases are kept.
    BENCH_PREVIOUS=""
    if [ "${BENCH_RESUME:-}" = 1 ] && [ -f "$OUT/bench/report.json" ]; then
      BENCH_PREVIOUS="$OUT/bench-previous-report.json"
      cp "$OUT/bench/report.json" "$BENCH_PREVIOUS"
      remaining="$(python3 "$ROOT/scripts/bench-report.py" --remaining "$BENCH_PREVIOUS" "$ROOT/AgelloUITests/BenchCases.swift")"
      if [ -z "$remaining" ]; then
        echo "Nothing to resume: the last report holds every case complete."
        rm -f "$BENCH_PREVIOUS"
        exit 0
      fi
      echo "Resuming: $remaining"
      export TEST_RUNNER_BENCH_ONLY="$remaining"
    fi
    scopes="AgelloUITests/BenchUITests"
    ;;
  all)
    if [ -n "${ONLY:-}" ]; then
      echo "ONLY needs a single suite (unit, inference, ui…), not all." >&2
      exit 2
    fi
    LAST=no
    run_suite unit -only-testing:"$UNIT_TESTS" "$@" || status=$?
    inference_status=0
    [ "$PLATFORM" != iphone ] && LAST=yes
    run_suite inference -only-testing:"$DEVICE_TESTS"/InferenceScenarioTests \
      -only-testing:"$DEVICE_TESTS"/KnowledgeScenarioTests \
      -only-testing:"$DEVICE_TESTS"/WebScenarioTests "$@" || inference_status=$?
    [ "$status" -eq 0 ] && status=$inference_status
    if [ "$PLATFORM" = iphone ]; then
      ui_status=0
      LAST=yes
      run_suite ui -only-testing:AgelloUITests "$@" || ui_status=$?
      [ "$status" -eq 0 ] && status=$ui_status
    fi
    ;;
  *) echo "Unknown suite: $SUITE" >&2; exit 2 ;;
esac
if [ -n "$scopes" ]; then
  # shellcheck disable=SC2086 # scopes and filters are space-separated words
  only="$(filters $scopes)" || exit 2
  # shellcheck disable=SC2086
  run_suite "$SUITE" $only "$@" || status=$?
fi
if [ "$SUITE" = bench ]; then
  # The app's traces of this run, then the joined report.
  rm -rf "$OUT/bench"
  mkdir -p "$OUT/bench"
  xcrun devicectl device copy from --device "$DEVICE_ID" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source Documents/traces --destination "$OUT/bench/traces" >/dev/null 2>&1 \
    || echo "No traces on the device"
  python3 "$ROOT/scripts/bench-report.py" "$OUT" "$BENCH_STARTED" "$BENCH_PREVIOUS" || status=$?
  rm -f "$BENCH_PREVIOUS"
else
  pull_report
fi
# What the project's disk use is now, and any scratch the run left (one-off OUT folders included).
echo
"$ROOT/scripts/storage.sh" brief || true
exit $status

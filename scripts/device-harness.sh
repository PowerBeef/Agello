#!/bin/sh
# On-device test harness for Agello: the physical iPhone, or this Mac running
# the iPhone app (PLATFORM=mac). Never the simulator.
#
# Usage:
#   scripts/device-harness.sh [unit|inference|files|web|ui|all|thinking|memory|calibrate|probes|screenshots] [extra xcodebuild args...]
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
#   memory     8 GB iPhone memory simulation (E4B at 5.0/4.0/3.5 GB usable).
#   screenshots  A guided UI tour with the real model: one screenshot per
#              screen (attachments/screenshots/) for the README and App Store.
#   all        unit, inference + files, then ui.
#
# Env: PLATFORM (iphone, the default, or mac: this Mac runs the iPhone app
#      "Designed for iPad/iPhone" through its Metal path; ui, screenshots and
#      memory stay iPhone-only, and `all` skips ui),
#      DEVICE_ID (iPhone only; default: deviceId from the git-ignored .mobilebuildmcp/config.yaml),
#      ONLY (run part of a suite: comma- or space-separated test identifiers
#      inside it, e.g. ONLY=AgelloTests/AppStateTests/testMockModeSendsWithoutDownloadedModel
#      scripts/device-harness.sh unit; not with `all`),
#      OUT (default: build/device-harness, or build/mac-harness with PLATFORM=mac),
#      AGELLO_TELEMETRY (engine telemetry level in our LiteRT-LM builds, default 2),
#      XCBEAUTIFY (path to xcbeautify, or "off" for raw output; default:
#      Homebrew's, looked up directly so other xcbeautify copies in PATH are ignored).
# Outputs: $OUT/<suite>.xcresult, $OUT/<suite>.log (raw xcodebuild output),
#          $OUT/attachments/, $OUT/harness-report.json
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
      ui | screenshots | memory)
        echo "The $SUITE suite runs on the iPhone only, not with PLATFORM=mac." >&2
        exit 2
        ;;
    esac
    # The Mac's destination id is its provisioning UDID.
    DEVICE_ID="$(system_profiler SPHardwareDataType | sed -n 's/.*Provisioning UDID: *//p')"
    OUT="${OUT:-$ROOT/build/mac-harness}"
    # Keep the Mac awake until this script exits.
    caffeinate -dims -w $$ &
    ;;
  *) echo "Unknown PLATFORM: $PLATFORM (iphone or mac)" >&2; exit 2 ;;
esac
BUNDLE_ID="com.patricedery.agello"
mkdir -p "$OUT"
# Lets the in-app report survive crash relaunches within this run only.
export TEST_RUNNER_HARNESS_RUN_ID="run-$(date +%s)"
# Engine telemetry level for our LiteRT-LM builds (ignored by Google's): 2 records span timings
# and GPU time at no measurable cost; each scenario's snapshot lands in its report entry.
export TEST_RUNNER_AGELLO_TELEMETRY="${AGELLO_TELEMETRY:-2}"

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
    -project "$ROOT/Agello.xcodeproj" -scheme Agello -configuration Debug \
    -destination "id=$DEVICE_ID" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    -resultBundlePath "$result" "$@"
}

run_suite() {
  name="$1"
  shift
  result="$OUT/$name.xcresult"
  rm -rf "$result"
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
  if [ "$PLATFORM" = mac ]; then
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
  unit) scopes="AgelloTests" ;;
  inference) scopes="AgelloDeviceTests/InferenceScenarioTests" ;;
  files) scopes="AgelloDeviceTests/KnowledgeScenarioTests" ;;
  web) scopes="AgelloDeviceTests/WebScenarioTests" ;;
  ui) scopes="AgelloUITests" ;;
  thinking)
    export TEST_RUNNER_HARNESS_THINKING=1
    scopes="AgelloDeviceTests/ThinkingScenarioTests"
    ;;
  memory)
    export TEST_RUNNER_HARNESS_MEMORY=1
    scopes="AgelloDeviceTests/MemoryEnvelopeScenarioTests"
    ;;
  probes)
    export TEST_RUNNER_HARNESS_PROBES=1
    scopes="AgelloDeviceTests/ProbeScenarioTests"
    ;;
  calibrate)
    export TEST_RUNNER_HARNESS_CALIBRATE=1
    scopes="AgelloDeviceTests/CalibrationScenarioTests"
    ;;
  screenshots)
    export TEST_RUNNER_HARNESS_SCREENSHOTS=1
    scopes="AgelloUITests/ScreenshotTourUITests"
    ;;
  all)
    if [ -n "${ONLY:-}" ]; then
      echo "ONLY needs a single suite (unit, inference, ui…), not all." >&2
      exit 2
    fi
    run_suite unit -only-testing:AgelloTests "$@" || status=$?
    inference_status=0
    run_suite inference -only-testing:AgelloDeviceTests/InferenceScenarioTests \
      -only-testing:AgelloDeviceTests/KnowledgeScenarioTests \
      -only-testing:AgelloDeviceTests/WebScenarioTests "$@" || inference_status=$?
    [ "$status" -eq 0 ] && status=$inference_status
    if [ "$PLATFORM" = iphone ]; then
      ui_status=0
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
pull_report
exit $status

#!/bin/sh
# On-device test harness for iRTChat (physical iPhone only).
#
# Usage:
#   scripts/device-harness.sh [unit|inference|files|web|ui|all|thinking|memory|calibrate|probes] [extra xcodebuild args...]
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
#   all        unit, inference + files, then ui.
#
# Env: DEVICE_ID (default: deviceId from the git-ignored .mobilebuildmcp/config.yaml),
#      ONLY (run part of a suite: comma- or space-separated test identifiers
#      inside it, e.g. ONLY=iRTChatTests/AppStateTests/testMockModeSendsWithoutDownloadedModel
#      scripts/device-harness.sh unit; not with `all`),
#      OUT (default: build/device-harness),
#      XCBEAUTIFY (path to xcbeautify, or "off" for raw output; default:
#      Homebrew's, looked up directly so other xcbeautify copies in PATH are ignored).
# Outputs: $OUT/<suite>.xcresult, $OUT/<suite>.log (raw xcodebuild output),
#          $OUT/attachments/, $OUT/harness-report.json
set -eu

SUITE="${1:-all}"
[ $# -gt 0 ] && shift
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/device.sh
. "$ROOT/scripts/lib/device.sh"
resolve_device_id "$ROOT"
OUT="${OUT:-$ROOT/build/device-harness}"
BUNDLE_ID="com.patricedery.irtchat"
mkdir -p "$OUT"
# Lets the in-app report survive crash relaunches within this run only.
export TEST_RUNNER_HARNESS_RUN_ID="run-$(date +%s)"

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
    -project "$ROOT/iRTChat.xcodeproj" -scheme iRTChat -configuration Debug \
    -destination "id=$DEVICE_ID" -allowProvisioningUpdates \
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
  mkdir -p "$OUT/attachments/$name"
  xcrun xcresulttool export attachments --path "$result" \
    --output-path "$OUT/attachments/$name" >/dev/null 2>&1 || true
  return "$suite_status"
}

pull_report() {
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
  unit) scopes="iRTChatTests" ;;
  inference) scopes="iRTChatDeviceTests/InferenceScenarioTests" ;;
  files) scopes="iRTChatDeviceTests/KnowledgeScenarioTests" ;;
  web) scopes="iRTChatDeviceTests/WebScenarioTests" ;;
  ui) scopes="iRTChatUITests" ;;
  thinking)
    export TEST_RUNNER_HARNESS_THINKING=1
    scopes="iRTChatDeviceTests/ThinkingScenarioTests"
    ;;
  memory)
    export TEST_RUNNER_HARNESS_MEMORY=1
    scopes="iRTChatDeviceTests/MemoryEnvelopeScenarioTests"
    ;;
  probes)
    export TEST_RUNNER_HARNESS_PROBES=1
    scopes="iRTChatDeviceTests/ProbeScenarioTests"
    ;;
  calibrate)
    export TEST_RUNNER_HARNESS_CALIBRATE=1
    scopes="iRTChatDeviceTests/CalibrationScenarioTests"
    ;;
  all)
    if [ -n "${ONLY:-}" ]; then
      echo "ONLY needs a single suite (unit, inference, ui…), not all." >&2
      exit 2
    fi
    run_suite unit -only-testing:iRTChatTests "$@" || status=$?
    inference_status=0
    run_suite inference -only-testing:iRTChatDeviceTests/InferenceScenarioTests \
      -only-testing:iRTChatDeviceTests/KnowledgeScenarioTests \
      -only-testing:iRTChatDeviceTests/WebScenarioTests "$@" || inference_status=$?
    [ "$status" -eq 0 ] && status=$inference_status
    ui_status=0
    run_suite ui -only-testing:iRTChatUITests "$@" || ui_status=$?
    [ "$status" -eq 0 ] && status=$ui_status
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

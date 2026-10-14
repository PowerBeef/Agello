#!/bin/sh
# Look at Agello on the physical iPhone outside of test runs.
#
# Usage:
#   scripts/device-run.sh logs [seconds] [app arguments...]
#       (Re)launch the installed app and save its output (os_log, including the
#       engine/generation/lifecycle categories, and LiteRT-LM's native logs)
#       for N seconds (default 30). App arguments go to the app, e.g.
#       `logs 20 --mock-engine`. The app keeps running afterwards.
#   scripts/device-run.sh screenshot [name]
#       Save the iPhone's screen as a PNG.
#   scripts/device-run.sh crashes [pull]
#       List Agello's crash and resource reports on the iPhone; `pull` copies
#       them. Symbolicate with Axiom's xcsym tools.
#
# The app must already be installed (a harness run or an Xcode build installs it).
# Env: DEVICE_ID (default: deviceId from the git-ignored .mobilebuildmcp/config.yaml),
#      OUT (default: build/device-run).
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/device.sh
. "$ROOT/scripts/lib/device.sh"
resolve_device_id "$ROOT"
OUT="${OUT:-$ROOT/build/device-run}"
BUNDLE_ID="com.patricedery.irtchat"
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

COMMAND="${1:-}"
[ $# -gt 0 ] && shift

case "$COMMAND" in
  logs)
    seconds=30
    case "${1:-}" in
      '' | *[!0-9]*) ;;
      *) seconds="$1"; shift ;;
    esac
    log="$OUT/logs-$STAMP.log"
    echo "Logging Agello for ${seconds}s (keep the iPhone unlocked)..."
    # OS_ACTIVITY_DT_MODE mirrors os_log to the console, as when Xcode runs the app.
    DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE=1 xcrun devicectl device process launch \
      --device "$DEVICE_ID" --console --terminate-existing "$BUNDLE_ID" "$@" \
      >"$log" 2>&1 &
    pid=$!
    sleep "$seconds"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    if ! grep -q "Launched application" "$log"; then
      echo "Launch failed (is the iPhone unlocked and the app installed?):" >&2
      tail -n 5 "$log" >&2
      exit 1
    fi
    app_lines="$(grep -cE '\[(engine|generation|lifecycle)\]' "$log" || true)"
    echo "Log: $log ($(wc -l <"$log" | tr -d ' ') lines, $app_lines from the app's categories)"
    ;;
  screenshot)
    png="$OUT/${1:-screen-$STAMP}.png"
    xcrun devicectl device capture screenshot --device "$DEVICE_ID" \
      --destination "$png" --quiet
    echo "Screenshot: $png"
    ;;
  crashes)
    listing="$OUT/.crash-listing.json"
    xcrun devicectl device info files --device "$DEVICE_ID" \
      --domain-type systemCrashLogs --quiet --json-output "$listing" >/dev/null
    reports="$(jq -r '.result.files[]
      | select((.resources.isDirectory | not) and (.name | startswith("Agello")))
      | "\(.metadata.lastModDate)\t\(.relativePath)"' "$listing" | sort -r)"
    rm -f "$listing"
    if [ -z "$reports" ]; then
      echo "No Agello reports on the iPhone."
      exit 0
    fi
    if [ "${1:-}" = pull ]; then
      mkdir -p "$OUT/crashes"
      echo "$reports" | while IFS="$(printf '\t')" read -r _ path; do
        xcrun devicectl device copy from --device "$DEVICE_ID" \
          --domain-type systemCrashLogs --source "$path" \
          --destination "$OUT/crashes/$(basename "$path")" --quiet
        echo "$OUT/crashes/$(basename "$path")"
      done
    else
      echo "$reports"
    fi
    ;;
  *)
    echo "Usage: scripts/device-run.sh logs [seconds] [app arguments...] | screenshot [name] | crashes [pull]" >&2
    exit 2
    ;;
esac

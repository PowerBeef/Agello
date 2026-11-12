#!/bin/sh
# One bench case with no UI driver attached (docs/HARNESS.md, H3): the installed app is launched
# with the case's prompt as its draft and sends it itself, tracing the reply. For telling what
# the driver's accessibility session costs: compare with the same case in
# `scripts/device-harness.sh bench`, which also installs the Release build this needs.
#
# Usage: scripts/bench-direct.sh CASE_ID      (an id of AgelloUITests/BenchCases.swift)
# It sets the case's Think, as the driver does (AGELLO_BENCH_THINK). The app must be a Release
# build: run the bench first, or scripts/phone-bench.sh, which installs one per runtime.
# The traces land in build/device-harness/bench-direct/.
# It relaunches the app, so it refuses (exit 3) while a harness run holds the iPhone.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE="${1:?Usage: scripts/bench-direct.sh CASE_ID}"
# shellcheck source=scripts/lib/device.sh
. "$ROOT/scripts/lib/device.sh"
resolve_device_id "$ROOT"
# shellcheck source=scripts/lib/harness-lock.sh
. "$ROOT/scripts/lib/harness-lock.sh"
harness_refuse_while_running "$ROOT"
BUNDLE_ID="com.patricedery.agello"
OUT="$ROOT/build/device-harness/bench-direct"
rm -rf "$OUT"
mkdir -p "$OUT"

# The case's prompt and Think, as scripts/phone-bench.sh sends them (no cooling: this measures
# the phone as it is).
spec="$(python3 "$ROOT/scripts/phone-bench.py" case "$ROOT/AgelloUITests/BenchCases.swift" "$CASE" --cool off)"
environment="$(echo "$spec" | sed -n 1p)"
arguments="$(echo "$spec" | sed -n 2p)"
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# A trace is named by its send time; the app keeps the last 40, so wait for a name, not a count.
launched="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
newest() {
  xcrun devicectl device info files --device "$DEVICE_ID" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" --subdirectory Documents/traces 2>/dev/null |
    grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z-[0-9A-Fa-f-]+\.json' |
    awk -v s="$launched" '$0 >= s' | head -1
}
caffeinate -dims -w $$ &
# shellcheck disable=SC2086 # the app's arguments are words
xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing \
  --environment-variables "$environment" "$BUNDLE_ID" -- $arguments >/dev/null
echo "Sent $CASE with no driver; waiting for its trace…"
waited=0
while [ -z "$(newest)" ] && [ "$waited" -lt 600 ]; do
  sleep 10
  waited=$((waited + 10))
done
# The title and memory helpers follow the reply.
sleep 10
xcrun devicectl device copy from --device "$DEVICE_ID" --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" --source Documents/traces --destination "$OUT/traces" >/dev/null 2>&1
python3 - "$OUT/traces" "$started" <<'PY'
import datetime, json, os, sys
folder, started = sys.argv[1], datetime.datetime.fromisoformat(sys.argv[2].replace("Z", "+00:00"))
traces = []
for name in sorted(os.listdir(folder)):
    trace = json.load(open(os.path.join(folder, name)))
    if datetime.datetime.fromisoformat(trace["startedAt"].replace("Z", "+00:00")) >= started - datetime.timedelta(seconds=5):
        traces.append(trace)
if not traces:
    sys.exit("No trace of this run: is the Release build with tracing installed (run the bench first)?")
trace = traces[-1]
stats, settings = trace.get("stats", {}), trace["settings"]
writing = [sample for sample in trace.get("timeline", []) if sample["chunks"] > 0]
def rate(samples):
    if len(samples) < 2: return 0.0
    return (samples[-1]["chunks"] - samples[0]["chunks"]) / max(0.001, samples[-1]["seconds"] - samples[0]["seconds"])
third = max(1, len(writing) // 3)
thermal = sorted({sample["thermalState"] for sample in trace.get("timeline", [])})
print(f"Ended: {trace['ended']} after {trace['seconds']:.1f} s; {stats.get('outputTokens', '?')} tokens at {stats.get('decodeTokensPerSecond', 0):.1f} tok/s")
print(f"Settings: window {settings['window']}, Think {settings['thinkingBudget'] if settings['think'] else 'off'}, optimized {settings['optimized']}")
print(f"Engine over time: {rate(writing[:third]):.1f} / {rate(writing[third:2 * third]):.1f} / {rate(writing[2 * third:]):.1f} chunks/s by thirds; thermal state {' to '.join(map(str, thermal))}")
print(f"Work: {json.dumps(trace.get('work', {}))[:300]}")
print(f"Frames: {json.dumps(trace.get('frames', {}))}")
PY
echo "Traces: $OUT/traces"

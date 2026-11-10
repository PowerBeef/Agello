#!/bin/sh
# Compare runtime builds through the app's engine on this Mac (docs/CLI.md): `agello bench` once
# per build and round, the builds taking turns, then the comparison and the answer checks.
#
# Usage:
#   scripts/cli-bench.sh [ARM ...] [-- options for agello bench]
#
#   ARM   NAME or NAME=PACKAGE. A build of the command line against one LiteRT-LM checkout:
#           release            what the app ships (Vendor/LiteRT-LM)
#           next               the fork's local build (../agello-arms/next/LiteRT-LM)
#           NAME=/abs/path     any checkout whose folder is named LiteRT-LM
#           NAME=release|next  the same build under another name (to measure the noise)
#         Default: release. The first arm is the base the others are compared with.
#
#   scripts/cli-bench.sh release next -- --only todo,explain,ttl-cache
#   ROUNDS=5 scripts/cli-bench.sh release again=release -- --only explain
#
# Env: ROUNDS (default 3: each build runs the cases that many times, one process a time),
#      OUT (default build/cli/runs/<time>), CHECKS (off skips the answer checks),
#      QUIET_WAIT (seconds to wait for the GPU to be free before each process, default 60;
#      a run that starts anyway is flagged suspect in its records), REPEAT (per process, default 1).
#
# One measuring run at a time on this Mac: it takes the harness lock (exit 3 while an iPhone
# run or another of these holds it) and keeps the Mac awake. Builds happen before any
# measuring, the answer checks after it: both would disturb the speeds.
# Outputs in OUT: <arm>.jsonl (records), <arm>.traces/, compare.txt, report.md, cli-bench.log.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/harness-lock.sh
. "$ROOT/scripts/lib/harness-lock.sh"
ROUNDS="${ROUNDS:-3}"
REPEAT="${REPEAT:-1}"
QUIET_WAIT="${QUIET_WAIT:-60}"
OUT="${OUT:-$ROOT/build/cli/runs/$(date +%Y%m%d-%H%M%S)}"
FORK="$ROOT/../LiteRT-LM/tools/agello-bench"

arms=""
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    *) arms="$arms $1"; shift ;;
  esac
done
[ -n "$arms" ] || arms=" release"

package_of() {
  case "$1" in
    release) echo "$ROOT/Vendor/LiteRT-LM" ;;
    next) (cd "$ROOT/../agello-arms/next/LiteRT-LM" 2>/dev/null && pwd) || { echo "No checkout at ../agello-arms/next/LiteRT-LM" >&2; exit 2; } ;;
    /*) echo "$1" ;;
    *) echo "An arm is release, next or NAME=/abs/path (got $1)." >&2; exit 2 ;;
  esac
}

LOCK="$(harness_lock_dir "$ROOT")"
mkdir -p "$(dirname "$LOCK")" "$OUT"
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
LOG="$OUT/cli-bench.log"
: >"$LOG"
printf 'pid=%s\nroot=%s\nplatform=mac\nsuite=cli-bench\nlog=%s\nlast=yes\nstarted=%s\n' \
  $$ "$ROOT" "$LOG" "$(date '+%Y-%m-%d %H:%M')" >"$LOCK/info"
caffeinate -dims -w $$ &

# 1. Build every arm before measuring anything. Arms on the same package share a build.
names=""
for arm in $arms; do
  name="${arm%%=*}"
  source="${arm#*=}"
  package="$(package_of "$source")"
  scratch="$ROOT/build/cli/$(basename "$(dirname "$package")")-$(printf '%s' "$package" | shasum | cut -c1-8)"
  [ "$package" = "$ROOT/Vendor/LiteRT-LM" ] && scratch="$ROOT/build/cli/release"
  echo "Building $name ($package)…"
  if ! (cd "$ROOT" && LITERTLM_PACKAGE="$package" swift build -c release --scratch-path "$scratch") >>"$LOG" 2>&1; then
    echo "The build of $name failed: see $LOG" >&2
    exit 1
  fi
  binary="$scratch/release/agello"
  build="$("$binary" env --trace-dir "$OUT/env-traces" 2>/dev/null | python3 -c 'import json, sys; m = json.load(sys.stdin)["machine"]; print((m.get("runtimeBuild") or {}).get("build_id", "no build id"), m["runtimeSHA256"][:12])')"
  echo "  $name: runtime build $build"
  eval "binary_$name=\"\$binary\""
  names="$names $name"
done
rm -rf "$OUT/env-traces" "$OUT/runtime.log"
# The edit guard lets target edits through from here: the binaries are built.
echo "Test Suite 'cli-bench' started" >>"$LOG"

gpu_busy() {
  ioreg -r -c IOAccelerator -d 1 2>/dev/null | sed -n 's/.*"Device Utilization %"=\([0-9]*\).*/\1/p' | head -1
}
wait_for_quiet() {
  waited=0
  busy="$(gpu_busy)"
  while [ "${busy:-0}" -gt 30 ] && [ "$waited" -lt "$QUIET_WAIT" ]; do
    [ "$waited" -eq 0 ] && echo "  The GPU is $busy % busy: waiting up to ${QUIET_WAIT}s for it to be free…"
    sleep 5
    waited=$((waited + 5))
    busy="$(gpu_busy)"
  done
}

# 2. Measure: the arms take turns, one process each, so drift lands on all of them alike.
status=0
round=1
while [ "$round" -le "$ROUNDS" ]; do
  for name in $names; do
    eval "binary=\"\$binary_$name\""
    wait_for_quiet
    echo "Round $round of $ROUNDS, $name:"
    "$binary" bench --label "$name" --out "$OUT/$name.jsonl" --warmup --repeat "$REPEAT" "$@" 2>&1 | sed 's/^/  /' || status=$?
  done
  round=$((round + 1))
done

# 3. After the measuring: the comparison, then the answer checks.
files=""
for name in $names; do files="$files $OUT/$name.jsonl"; done
base="${names# }"
base="${base%% *}"
if [ -f "$FORK/compare.py" ]; then
  # shellcheck disable=SC2086
  python3 "$FORK/compare.py" $files --base "$base" | tee "$OUT/compare.txt"
else
  echo "No fork checkout at ../LiteRT-LM: the comparison (compare.py) is skipped."
fi
if [ "${CHECKS:-on}" != off ]; then
  # shellcheck disable=SC2086
  python3 "$ROOT/scripts/cli-report.py" $files --out "$OUT/report.md" || status=$?
fi
echo
echo "Records, traces and reports: $OUT"
"$ROOT/scripts/storage.sh" brief || true
exit $status

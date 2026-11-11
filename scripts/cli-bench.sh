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
#      REPEAT (per process, default 1), and for the Mac's load (docs/CLI.md, "System load"):
#      QUIET (off: no readiness check, no extra rounds; for a run read only for its replies),
#      QUIET_WAIT (seconds to wait for the Mac to be ready before measuring, default 120; still
#      busy after that, the run refuses with exit 4 and what to fix),
#      MIN_CLEAN (undisturbed runs wanted of each case and build, default 3 or ROUNDS if less),
#      EXTRA_ROUNDS (the most rounds added to get them, default 3).
#
# One measuring run at a time on this Mac: it takes the harness lock (exit 3 while an iPhone
# run or another of these holds it) and keeps the Mac awake. Builds happen before any
# measuring, the answer checks after it: both would disturb the speeds.
#
# The Mac's load: scripts/mac-ready.sh must say ready before the first run and is asked again
# before each process; afterwards scripts/cli-load.py reads from the records which runs were
# disturbed and by what, rounds are added while a case lacks undisturbed runs, and the
# comparison is made on the undisturbed records. Start it and leave the Mac alone, the Claude
# session that started it included.
# Outputs in OUT: <arm>.jsonl (records), <arm>.traces/, load.txt (what was disturbed, and each
# build's best run), compare.txt (undisturbed records), compare-all.txt (every record),
# clean/ (the undisturbed records), report.md, cli-bench.log.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/harness-lock.sh
. "$ROOT/scripts/lib/harness-lock.sh"
ROUNDS="${ROUNDS:-3}"
REPEAT="${REPEAT:-1}"
QUIET="${QUIET:-on}"
QUIET_WAIT="${QUIET_WAIT:-120}"
EXTRA_ROUNDS="${EXTRA_ROUNDS:-3}"
MIN_CLEAN="${MIN_CLEAN:-3}"
[ "$MIN_CLEAN" -gt "$ROUNDS" ] && MIN_CLEAN="$ROUNDS"
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

# 2. Measure: the arms take turns, one process each, so drift lands on all of them alike.
files=""
for name in $names; do files="$files $OUT/$name.jsonl"; done
if [ "$QUIET" != off ]; then
  # Refuse a Mac that's busy: the numbers wouldn't be worth the run.
  if ! MAC_READY_OWN_LOCK=1 "$ROOT/scripts/mac-ready.sh" --wait "$QUIET_WAIT"; then
    echo "Not measured. Free the Mac and run it again, or QUIET=off for a run read only for its replies." >&2
    exit 4
  fi
fi
status=0
measure_round() {
  round_label="$1"
  shift
  for name in $names; do
    eval "binary=\"\$binary_$name\""
    # Busy again between two processes: wait a little, then measure anyway. The records say
    # afterwards whether the run was disturbed.
    if [ "$QUIET" != off ]; then
      SAMPLE=5 MAC_READY_OWN_LOCK=1 "$ROOT/scripts/mac-ready.sh" --quiet --wait 60 | sed 's/^/  /' || true
    fi
    echo "Round $round_label, $name:"
    "$binary" bench --label "$name" --out "$OUT/$name.jsonl" --warmup --repeat "$REPEAT" "$@" 2>&1 | sed 's/^/  /' || status=$?
  done
}
round=1
while [ "$round" -le "$ROUNDS" ]; do
  measure_round "$round of $ROUNDS" "$@"
  round=$((round + 1))
done
# Which runs the Mac's load disturbed; more rounds while a case lacks undisturbed ones.
if [ "$QUIET" != off ]; then
  extra=0
  # shellcheck disable=SC2086
  until python3 "$ROOT/scripts/cli-load.py" $files --min-clean "$MIN_CLEAN" >/dev/null; do
    if [ "$extra" -ge "$EXTRA_ROUNDS" ]; then
      echo "Still short of undisturbed runs after $EXTRA_ROUNDS extra rounds: the Mac isn't quiet (see load.txt)."
      break
    fi
    extra=$((extra + 1))
    echo "Some cases have fewer than $MIN_CLEAN undisturbed runs: one more round ($extra of at most $EXTRA_ROUNDS)."
    measure_round "$((ROUNDS + extra)) (extra)" "$@"
  done
fi

# 3. After the measuring: the comparison, then the answer checks.
base="${names# }"
base="${base%% *}"
compared="$files"
if [ "$QUIET" != off ]; then
  # shellcheck disable=SC2086
  python3 "$ROOT/scripts/cli-load.py" $files --clean-dir "$OUT/clean" --min-clean "$MIN_CLEAN" --base "$base" --out "$OUT/load.txt" || true
  compared=""
  for name in $names; do compared="$compared $OUT/clean/$name.jsonl"; done
fi
if [ -f "$FORK/compare.py" ]; then
  if [ "$QUIET" != off ]; then
    # Every record, for the file; the undisturbed ones are the comparison to read.
    # shellcheck disable=SC2086
    python3 "$FORK/compare.py" $files --base "$base" >"$OUT/compare-all.txt" 2>&1 || true
    echo
    echo "The comparison below is on the undisturbed records (every record: compare-all.txt)."
  fi
  # shellcheck disable=SC2086
  python3 "$FORK/compare.py" $compared --base "$base" | tee "$OUT/compare.txt"
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

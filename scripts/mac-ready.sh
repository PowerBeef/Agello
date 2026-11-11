#!/bin/sh
# Is this Mac quiet enough for a measuring run (scripts/cli-bench.sh)? It samples what the Mac is
# doing for a few seconds and says ready or not, with what to fix.
#
# Usage:
#   scripts/mac-ready.sh              sample for 10 s and report
#   scripts/mac-ready.sh --wait 120   check again every 10 s, for up to 120 s, until it's ready
#   scripts/mac-ready.sh --quiet      print only when it isn't ready (cli-bench.sh, between runs)
#
# Exit codes: 0 ready (warnings don't count), 4 not ready, 2 bad usage.
# Env: SAMPLE (seconds sampled, default 10), and the limits:
#   READY_GPU (the GPU's median utilization, default 20 %): a still desktop sits at 12 to 17 %,
#     a browser tab that animates or a session streaming text at 15 to 25 % and more;
#   READY_GPU_MAX (the highest sample, default 35 %);
#   READY_CPU (cores busy with everything else, default 1.5);
#   READY_MEMORY (free memory, default 25 %).
# Why these: on 2026-11-11 the same build decoded 15 % slower on short cases while the desktop's
# GPU use went from 14 % to 15-22 %, and three times slower beside a process using the GPU fully
# (docs/BACKEND.md, "The ledger"). A run that starts ready can still be disturbed part-way:
# scripts/cli-load.py reads that from the records afterwards.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SAMPLE="${SAMPLE:-10}"
READY_GPU="${READY_GPU:-20}"
READY_GPU_MAX="${READY_GPU_MAX:-35}"
READY_CPU="${READY_CPU:-1.5}"
READY_MEMORY="${READY_MEMORY:-25}"
WAIT=0
QUIET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --wait) WAIT="${2:?--wait takes seconds}"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    *) echo "Usage: scripts/mac-ready.sh [--wait SECONDS] [--quiet]" >&2; exit 2 ;;
  esac
done

gpu_now() {
  ioreg -r -c IOAccelerator -d 1 2>/dev/null | sed -n 's/.*"Device Utilization %"=\([0-9]*\).*/\1/p' | head -1
}

# One sampling pass. Sets REPORT (the table) and PROBLEMS (one line each; empty when ready).
sample() {
  cores="$(sysctl -n hw.ncpu)"
  # CPU: top's second sample is the interval's; the first is since boot.
  top_out="$(mktemp)"
  top -l 2 -n 0 -s "$SAMPLE" >"$top_out" 2>/dev/null &
  top_pid=$!
  samples=""
  i=0
  while [ "$i" -lt "$SAMPLE" ]; do
    g="$(gpu_now)"
    [ -n "$g" ] && samples="$samples $g"
    sleep 1
    i=$((i + 1))
  done
  wait "$top_pid" 2>/dev/null
  idle="$(grep 'CPU usage' "$top_out" | tail -1 | sed -n 's/.* \([0-9.]*\)% idle.*/\1/p')"
  rm -f "$top_out"
  busy="$(awk -v idle="${idle:-100}" -v n="$cores" 'BEGIN {printf "%.1f", (100 - idle) * n / 100}')"
  # shellcheck disable=SC2086 # the samples are numbers
  gpu_median="$(printf '%s\n' $samples | sort -n | awk '{v[NR] = $1} END {if (NR) print v[int((NR + 1) / 2)]; else print ""}')"
  # shellcheck disable=SC2086
  gpu_max="$(printf '%s\n' $samples | sort -n | tail -1)"
  free="$(memory_pressure 2>/dev/null | sed -n 's/.*free percentage: \([0-9]*\)%.*/\1/p')"
  swap="$(sysctl -n vm.swapusage 2>/dev/null | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p')"
  limit="$(pmset -g therm 2>/dev/null | sed -n 's/.*CPU_Speed_Limit[^0-9]*\([0-9]*\).*/\1/p' | head -1)"
  lowpower="$(pmset -g 2>/dev/null | sed -n 's/^ *lowpowermode *\([0-9]\).*/\1/p' | head -1)"
  power="$(pmset -g batt 2>/dev/null | sed -n "s/.*'\(.*\)'.*/\1/p" | head -1)"

  PROBLEMS=""
  WARNINGS=""
  problem() { PROBLEMS="$PROBLEMS$1
"; }
  warning() { WARNINGS="$WARNINGS$1
"; }
  mark() { [ "$1" = ok ] && echo "ok" || echo "TOO BUSY"; }

  gpu_state=ok
  if [ -z "$gpu_median" ]; then
    gpu_line="not readable"
    warning "The GPU's utilization can't be read (ioreg)."
  else
    if [ "$gpu_median" -gt "$READY_GPU" ] || [ "$gpu_max" -gt "$READY_GPU_MAX" ]; then
      gpu_state=busy
      problem "The GPU is ${gpu_median} % busy (highest ${gpu_max} %; the limits are ${READY_GPU} and ${READY_GPU_MAX} %): something is drawing or computing on it. Close or still the animating window, or wait for the other run."
    fi
    gpu_line="${gpu_median} % median, ${gpu_max} % highest"
  fi
  cpu_state=ok
  if awk -v b="$busy" -v l="$READY_CPU" 'BEGIN {exit !(b > l)}'; then
    cpu_state=busy
    hogs="$(ps -Ao pcpu=,comm= -r | head -3 | awk '{cpu = $1; $1 = ""; n = split($0, parts, "/"); printf "%s%s (%s %%)", sep, parts[n], cpu; sep = ", "}')"
    problem "Other work keeps ${busy} cores busy (the limit is ${READY_CPU}): ${hogs}."
  fi
  mem_state=ok
  if [ -n "$free" ] && [ "$free" -lt "$READY_MEMORY" ]; then
    mem_state=busy
    problem "Only ${free} % of memory is free (the limit is ${READY_MEMORY} %): the model would push the Mac into swap."
  fi
  heat_state=ok
  heat_line="no limit"
  if [ -n "$limit" ] && [ "$limit" -lt 100 ]; then
    heat_state=busy
    heat_line="CPU limited to ${limit} %"
    problem "The Mac is hot: macOS limits the CPU to ${limit} %. Let it cool."
  fi
  power_state=ok
  if [ "${lowpower:-0}" = 1 ]; then
    power_state=busy
    problem "Low Power Mode is on: it slows the CPU and the GPU."
  fi
  case "$power" in *Battery*) warning "On battery: macOS may hold the speed back. Plug it in for numbers to keep." ;; esac

  # Work that isn't loading the Mac this second but can at any moment.
  others="$(pgrep -fl 'xcodebuild|swift-build|swift-frontend|/clang|bazel\(|xctest|agello bench' 2>/dev/null |
    grep -v "mac-ready" | awk '{name = $2; n = split(name, parts, "/"); print parts[n] " (pid " $1 ")"}' | sort -u | head -5 | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  if [ -n "$others" ]; then
    case "$others" in *bazel*) hint=" A Bazel server trims its cache while idle: stop it with bazelisk shutdown." ;; *) hint="" ;; esac
    warning "Running beside it, and able to load the Mac part-way through: ${others}.${hint}"
  fi
  # shellcheck source=scripts/lib/harness-lock.sh
  . "$ROOT/scripts/lib/harness-lock.sh"
  if [ -z "${MAC_READY_OWN_LOCK:-}" ] && running="$(harness_lock_info "$(harness_lock_dir "$ROOT")" 2>/dev/null)"; then
    problem "A harness run holds the lock: $(echo "$running" | tr '\n' ' ')"
  fi

  REPORT="$(
    printf 'This Mac over %s s:\n' "$SAMPLE"
    printf '  %-8s %-34s %s\n' GPU "$gpu_line" "$(mark "$gpu_state")"
    printf '  %-8s %-34s %s\n' CPU "${busy} of ${cores} cores busy" "$(mark "$cpu_state")"
    printf '  %-8s %-34s %s\n' Memory "${free:-?} % free, ${swap:-?} MB of swap used" "$(mark "$mem_state")"
    printf '  %-8s %-34s %s\n' Heat "$heat_line" "$(mark "$heat_state")"
    printf '  %-8s %-34s %s\n' Power "${power:-unknown}$([ "${lowpower:-0}" = 1 ] && echo ', Low Power Mode')" "$(mark "$power_state")"
  )"
}

waited=0
while :; do
  sample
  [ -z "$PROBLEMS" ] && break
  [ "$waited" -ge "$WAIT" ] && break
  [ -z "$QUIET" ] && echo "Not ready yet (waited ${waited}s of ${WAIT}s): $(printf '%s' "$PROBLEMS" | head -1)"
  waited=$((waited + SAMPLE))
done

if [ -n "$PROBLEMS" ]; then
  echo "$REPORT"
  printf '%s' "$PROBLEMS" | sed 's/^/  - /'
  [ -n "$WARNINGS" ] && printf '%s' "$WARNINGS" | sed 's/^/  - Also: /'
  echo "Not ready for a measuring run."
  exit 4
fi
if [ -z "$QUIET" ]; then
  echo "$REPORT"
  [ -n "$WARNINGS" ] && printf '%s' "$WARNINGS" | sed 's/^/  - Note: /'
  echo "Ready for a measuring run. Leave the Mac alone while it runs, this session included."
fi
exit 0

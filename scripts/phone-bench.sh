#!/bin/sh
# Compare runtime builds on the iPhone (docs/HARNESS.md, "Runtime builds on the iPhone"), as
# scripts/cli-bench.sh does on this Mac: the app is built once per runtime, the builds are
# installed in turns, and each case is sent with no UI driver, the app tracing the reply. The
# traces become the records the Mac's tools read: which runs heat disturbed, whether the replies
# are identical, and the speeds compared on the undisturbed runs.
#
# Usage:
#   scripts/phone-bench.sh [ARM ...] [-- CASE ...]
#
#   ARM   NAME or NAME=SOURCE:
#           release            what the app ships (Vendor/LiteRT-LM as committed)
#           next               the fork's local build (../agello-arms/next/LiteRT-LM, its dist/)
#           NAME=/abs/path     any checkout of the fork with a built dist/
#           NAME=release|next  the same build under another name (to measure the noise)
#         Default: release next. The first arm is the base the others are compared with.
#   CASE  Bench cases (AgelloUITests/BenchCases.swift) without Search. Default: explain email
#         file-report, the Mac's B3 cases. Only a case's first message is sent.
#
#   scripts/phone-bench.sh release next
#   ROUNDS=5 scripts/phone-bench.sh release next -- explain email
#   scripts/phone-bench.sh --read build/phone/runs/<time>    read a run again; no phone needed
#
# Env: ROUNDS (default 3: each build runs every case that many times; the builds take turns, the
#      order reversed every other round, so a reinstall comes once per round),
#      OUT (default build/phone/runs/<time>), DEVICE_ID, PREFLIGHT (off skips it),
#      COOL (on, the default: before each send the app waits, up to ten minutes, for the phone to
#      cool to nominal; off sends at once),
#      MIN_CLEAN (undisturbed runs wanted of each case and build, default 3 or ROUNDS if less),
#      EXTRA_ROUNDS (the most rounds added to get them, default 2),
#      BUILD_PRIORITY (background, the default: the two builds run at background priority and on
#      BUILD_JOBS jobs (default 4), so other work keeps this Mac and the builds take longer;
#      normal: full speed), CHECKS (off skips the answer checks).
#
# What it needs: the iPhone connected, unlocked and set to Auto-Lock Never for the whole run (an
# install leaves it on its home screen), iPhone Mirroring closed, a Focus on, the models
# downloaded; plugged in is best. This Mac builds the app twice at the start, then only installs
# and launches: how busy it is doesn't reach the phone's numbers.
#
# One run at a time: it takes the harness lock (exit 3 while another run holds it). The edit
# guard holds the Agello* folders until both apps are built. Vendor/LiteRT-LM must be as
# committed: the script vendors each runtime to build it and puts it back, also when stopped.
# Exit codes: 0 done, 1 a build, an install or a reading failed, 2 usage, 3 another run,
# 4 the preflight refused or the phone stayed locked.
# Outputs in OUT: manifest.jsonl (each launch), traces/ (the app's traces), <arm>.jsonl (the
# records), load.txt (what heat disturbed, each build's best run), compare.txt (the undisturbed
# records), compare-all.txt (every record), replies.txt and replies/, report.md (the answer
# checks), build-<arm>.log, phone-bench.log. The built apps (apps/) are deleted at the end.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/device.sh
. "$ROOT/scripts/lib/device.sh"
# shellcheck source=scripts/lib/harness-lock.sh
. "$ROOT/scripts/lib/harness-lock.sh"
ROUNDS="${ROUNDS:-3}"
COOL="${COOL:-on}"
EXTRA_ROUNDS="${EXTRA_ROUNDS:-2}"
MIN_CLEAN="${MIN_CLEAN:-3}"
[ "$MIN_CLEAN" -gt "$ROUNDS" ] && MIN_CLEAN="$ROUNDS"
BUILD_PRIORITY="${BUILD_PRIORITY:-background}"
BUILD_JOBS="${BUILD_JOBS:-4}"
OUT="${OUT:-$ROOT/build/phone/runs/$(date +%Y%m%d-%H%M%S)}"
HELPER="$ROOT/scripts/phone-bench.py"
CASES_FILE="$ROOT/AgelloUITests/BenchCases.swift"
FORK="$ROOT/../LiteRT-LM/tools/agello-bench"
BUNDLE_ID="com.patricedery.agello"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData"

# The record files of the builds in $names, by name: the reading runs from inside OUT, whose path
# may hold spaces (this checkout's does), which would split an unquoted list of full paths.
record_files() {
  labels="$(echo "$names" | sed 's/^ *//; s/ /,/g')"
  files=""
  compared=""
  for name in $names; do
    files="$files $name.jsonl"
    compared="$compared clean/$name.jsonl"
  done
  base="${names# }"
  base="${base%% *}"
}
read_records() {
  python3 "$HELPER" records "$OUT" --hardware "$hardware" --labels "$labels" >"$OUT/records.txt" 2>&1
}
# 3. Read a run: the records, heat, the replies, the speeds.
read_run() {
  record_files
  read_status=0
  read_records || read_status=1
  tee -a "$LOG" <"$OUT/records.txt"
  echo
  # shellcheck disable=SC2086 # file names without spaces, read from inside OUT
  (cd "$OUT" && python3 "$ROOT/scripts/cli-load.py" $files --device iPhone --clean-dir clean \
    --min-clean "$MIN_CLEAN" --base "$base" --out load.txt) | tee -a "$LOG" || true
  if [ -f "$FORK/compare.py" ]; then
    # shellcheck disable=SC2086
    (cd "$OUT" && python3 "$FORK/compare.py" $files --base "$base" >compare-all.txt 2>&1) || true
    echo
    echo "The comparison below is on the undisturbed records (every record: compare-all.txt)."
    # shellcheck disable=SC2086
    (cd "$OUT" && python3 "$FORK/compare.py" $compared --base "$base" 2>&1 | tee compare.txt) | tee -a "$LOG"
  else
    echo "No fork checkout at ../LiteRT-LM: the comparison (compare.py) is skipped."
  fi
  if [ "${CHECKS:-on}" != off ]; then
    # shellcheck disable=SC2086
    (cd "$OUT" && python3 "$ROOT/scripts/cli-report.py" $files --out report.md) >>"$LOG" 2>&1 || true
  fi
  return $read_status
}

# --read DIR: read a run again (a run cut short, or after a change to the reading), no phone.
if [ "${1:-}" = --read ]; then
  OUT="$(cd "${2:?--read takes a run folder}" && pwd)"
  LOG="$OUT/phone-bench.log"
  names="$(python3 -c 'import json, sys; print(" ".join(dict.fromkeys(json.loads(l)["label"] for l in open(sys.argv[1]) if l.strip())))' "$OUT/manifest.jsonl")"
  names=" $names"
  hardware="$(head -1 "$OUT/$(echo "$names" | awk '{print $1}').jsonl" 2>/dev/null | python3 -c 'import json, sys; print(json.loads(sys.stdin.readline())["machine"]["hardware"])' 2>/dev/null || echo iPhone)"
  read_run
  exit $?
fi
resolve_device_id "$ROOT"

arms=""
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    *) arms="$arms $1"; shift ;;
  esac
done
[ -n "$arms" ] || arms=" release next"
cases="$*"
[ -n "$cases" ] || cases="explain email file-report"

# release, or the checkout whose dist/ holds the runtime.
source_of() {
  case "$1" in
    release) echo release ;;
    next) (cd "$ROOT/../agello-arms/next/LiteRT-LM" 2>/dev/null && pwd) || { echo "No checkout at ../agello-arms/next/LiteRT-LM" >&2; exit 2; } ;;
    /*) echo "$1" ;;
    *) echo "An arm is release, next or NAME=/abs/path (got $1)." >&2; exit 2 ;;
  esac
}
names=""
for arm in $arms; do
  name="${arm%%=*}"
  source="$(source_of "${arm#*=}")"
  if [ "$source" != release ] && [ ! -d "$source/dist/CLiteRTLM.xcframework/ios-arm64" ]; then
    echo "$name: no iPhone runtime in $source/dist (agello/build-xcframework.sh builds it)." >&2
    exit 2
  fi
  eval "source_$name=\"\$source\""
  names="$names $name"
done
for case in $cases; do
  python3 "$HELPER" case "$CASES_FILE" "$case" >/dev/null || exit 2
done
if [ -e "$OUT/manifest.jsonl" ]; then
  echo "$OUT holds an earlier run: delete it or choose another OUT." >&2
  exit 2
fi
if [ -n "$(git -C "$ROOT" status --porcelain -- Vendor/LiteRT-LM)" ] || [ -e "$ROOT/Vendor/LiteRT-LM/dist" ]; then
  echo "Vendor/LiteRT-LM isn't as committed (a local runtime vendored?): put it back first." >&2
  echo "  git checkout -- Vendor/LiteRT-LM && git clean -fdq Vendor/LiteRT-LM && rm -rf Vendor/LiteRT-LM/dist" >&2
  exit 2
fi
if [ "${PREFLIGHT:-on}" != off ]; then
  device_preflight || exit 4
fi

LOCK="$(harness_lock_dir "$ROOT")"
mkdir -p "$(dirname "$LOCK")" "$OUT/traces" "$OUT/apps"
# A full path: the reading runs from inside it.
OUT="$(cd "$OUT" && pwd)"
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
VENDORED=""
# Xcode keeps the runtime it last built with (2026-11-12: an app built for the shipped runtime
# carried the pruned one, twice). A build doesn't resolve the package again when
# Vendor/LiteRT-LM changes, and the step that embeds the framework in the app compares dates:
# the shipped framework is older than the pruned one already in the app, so it was never copied.
# So after each switch the package is resolved explicitly, and the last runtime's precompiled
# module and built frameworks go, the one inside the app included.
forget_runtime() {
  rm -rf "$DERIVED"/Agello-*/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules/*/CLiteRTLM-*.pcm \
    "$DERIVED"/Agello-*/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules/CLiteRTLM-*.pcm \
    "$DERIVED"/Agello-*/Build/Products/*-iphoneos/CLiteRTLM.framework \
    "$DERIVED"/Agello-*/Build/Products/*-iphoneos/Agello.app/Frameworks/CLiteRTLM.framework
  xcodebuild -resolvePackageDependencies -project "$ROOT/Agello.xcodeproj" -scheme Agello >>"$LOG" 2>&1
}
# The committed runtime back in Vendor/LiteRT-LM, and Xcode resolved to it.
restore_vendor() {
  git -C "$ROOT" checkout -- Vendor/LiteRT-LM
  git -C "$ROOT" clean -fdq Vendor/LiteRT-LM
  rm -rf "$ROOT/Vendor/LiteRT-LM/dist"
  forget_runtime || true
  VENDORED=""
}
cleanup() {
  [ -n "$VENDORED" ] && restore_vendor
  rm -rf "$LOCK"
}
# The runtime build id inside an app's framework (litert_lm_get_build_info's JSON).
runtime_in() {
  strings "$1/Frameworks/CLiteRTLM.framework/CLiteRTLM" 2>/dev/null |
    grep -oE '"build_id":"[0-9a-f]+"' | head -1 | sed 's/.*:"//; s/"$//'
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
LOG="$OUT/phone-bench.log"
: >"$LOG"
printf 'pid=%s\nroot=%s\nplatform=iphone\nsuite=phone-bench\nlog=%s\nlast=yes\nstarted=%s\n' \
  $$ "$ROOT" "$LOG" "$(date '+%Y-%m-%d %H:%M')" >"$LOCK/info"
caffeinate -dims -w $$ &
say() {
  echo "$*"
  echo "$*" >>"$LOG"
}
hardware="$(xcrun devicectl list devices 2>/dev/null | grep "$DEVICE_ID" | grep -o 'iPhone [0-9A-Za-z ]*(iPhone[0-9,]*)' | head -1)"
[ -n "$hardware" ] || hardware="iPhone"
say "Phone comparison on $hardware:$(for n in $names; do printf ' %s' "$n"; done); cases $cases; $ROUNDS rounds; cooling $COOL. Records: $OUT"

# 1. Build the app once per runtime, before anything is measured. Arms on the same runtime share
# an app.
build_app() {
  name="$1"
  source="$2"
  if [ "$source" = release ]; then
    restore_vendor
  else
    "$ROOT/Vendor/use-local-litert.sh" "$source" >>"$LOG" 2>&1
    VENDORED=1
    forget_runtime
  fi
  priority=""
  jobs=""
  if [ "$BUILD_PRIORITY" = background ]; then
    priority="taskpolicy -b nice -n 15"
    jobs="-jobs $BUILD_JOBS"
  fi
  say "Building the app with $name's runtime (Release, $BUILD_PRIORITY priority)…"
  started="$(date +%s)"
  # shellcheck disable=SC2086 # priority and jobs are words or nothing
  if ! $priority xcodebuild build -project "$ROOT/Agello.xcodeproj" -scheme Agello -configuration Release \
    -destination "id=$DEVICE_ID" -allowProvisioningUpdates -allowProvisioningDeviceRegistration $jobs \
    >"$OUT/build-$name.log" 2>&1; then
    say "The build of $name failed: $OUT/build-$name.log"
    exit 1
  fi
  # The app target's own block: the scheme lists its extensions too.
  products="$(xcodebuild -showBuildSettings -project "$ROOT/Agello.xcodeproj" -scheme Agello \
    -configuration Release -destination "id=$DEVICE_ID" 2>/dev/null |
    awk '/^Build settings for action build and target / {target = $NF}
      target == "Agello:" && /^ *TARGET_BUILD_DIR = / {sub(/^ *TARGET_BUILD_DIR = /, ""); print; exit}')"
  if [ ! -d "$products/Agello.app" ]; then
    say "No Agello.app in $products after the build of $name."
    exit 1
  fi
  rm -rf "$OUT/apps/$name"
  mkdir -p "$OUT/apps/$name"
  ditto "$products/Agello.app" "$OUT/apps/$name/Agello.app"
  runtime="$(runtime_in "$OUT/apps/$name/Agello.app")"
  expected=""
  [ "$source" != release ] && expected="$(sed -n 's/^Build id: *//p' "$source/dist/BUILD-INFO.txt" | head -1)"
  if [ -z "$runtime" ] || { [ -n "$expected" ] && [ "$runtime" != "$expected" ]; }; then
    say "The app built for $name carries runtime ${runtime:-unknown}, not ${expected:-the shipped one}: stopping."
    exit 1
  fi
  eval "runtime_$name=\"\$runtime\""
  say "  built in $(($(date +%s) - started)) s, runtime $runtime"
}
built=""
for name in $names; do
  eval "source=\"\$source_$name\""
  app_of=""
  for other in $built; do
    eval "other_source=\"\$source_$other\""
    [ "$other_source" = "$source" ] && app_of="$other"
  done
  if [ -z "$app_of" ]; then
    build_app "$name" "$source"
    built="$built $name"
    app_of="$name"
  fi
  eval "app_$name=\"\$OUT/apps/\$app_of/Agello.app\""
done
[ -n "$VENDORED" ] && restore_vendor
# Builds from different runtimes must carry different runtimes.
for name in $built; do
  for other in $built; do
    [ "$name" = "$other" ] && continue
    eval "a=\"\$runtime_$name\"; b=\"\$runtime_$other\""
    if [ "$a" = "$b" ]; then
      say "The apps for $name and $other carry the same runtime ($a): stopping."
      exit 1
    fi
  done
done
# The edit guard lets target edits through from here: both apps are built.
echo "Test Suite 'phone-bench' started" >>"$LOG"

# 2. Measure.
locked() {
  xcrun devicectl device info lockState --device "$DEVICE_ID" 2>/dev/null | grep -q "passcodeRequired: true"
}
wait_unlocked() {
  locked || return 0
  say "The iPhone is locked: unlock it (and set Auto-Lock to Never). Waiting up to ten minutes…"
  waited=0
  while locked; do
    if [ "$waited" -ge 600 ]; then
      say "Still locked after ten minutes: stopping. What ran so far is read below."
      return 4
    fi
    sleep 15
    waited=$((waited + 15))
  done
}
trace_names() {
  xcrun devicectl device info files --device "$DEVICE_ID" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" --subdirectory Documents/traces 2>/dev/null |
    grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z-[0-9A-Fa-f-]+\.json' | sort -u
}
installed=""
stopped=""
# run_case NAME ROUND CASE WARMUP: one launch, waiting for its trace. Its variables start with
# rc_ (sh has no locals, and the callers loop over name and case).
run_case() {
  rc_name="$1"
  rc_round="$2"
  rc_case="$3"
  rc_warmup="$4"
  rc_spec="$(python3 "$HELPER" case "$CASES_FILE" "$rc_case" --cool "$COOL" 2>/dev/null)"
  rc_environment="$(echo "$rc_spec" | sed -n 1p)"
  rc_arguments="$(echo "$rc_spec" | sed -n 2p)"
  rc_wait="$(echo "$rc_spec" | sed -n 3p)"
  rc_prompt="$(echo "$rc_spec" | sed -n 4p)"
  wait_unlocked || { stopped=4; return 0; }
  # The trace's name is its send time: anything named after the launch is this case's.
  rc_launched="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
  rc_status=traced
  rc_trace=""
  # After "--", the app's own arguments (-memoryEnabled would read as devicectl's -e otherwise).
  # shellcheck disable=SC2086 # the app's arguments are words
  if ! xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing \
    --environment-variables "$rc_environment" "$BUNDLE_ID" -- $rc_arguments >>"$LOG" 2>&1; then
    rc_status="launch failed"
  else
    rc_waited=0
    while :; do
      rc_trace="$(trace_names | awk -v s="$rc_launched" '$0 >= s' | head -1)"
      [ -n "$rc_trace" ] && break
      if [ "$rc_waited" -ge "$rc_wait" ]; then
        rc_status="no trace after $rc_wait s"
        break
      fi
      sleep 10
      rc_waited=$((rc_waited + 10))
    done
  fi
  if [ -n "$rc_trace" ]; then
    # The title helper adds itself to the trace a few seconds after the reply.
    sleep 10
    if ! xcrun devicectl device copy from --device "$DEVICE_ID" --domain-type appDataContainer \
      --domain-identifier "$BUNDLE_ID" --source "Documents/traces/$rc_trace" \
      --destination "$OUT/traces/$rc_trace" >>"$LOG" 2>&1; then
      rc_status="trace not copied"
    fi
  fi
  python3 -c 'import json, sys; keys = ["label", "round", "case", "warmup", "launched", "trace", "status"]; values = [sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4] == "yes", sys.argv[5], sys.argv[6], sys.argv[7]]; print(json.dumps(dict(zip(keys, values), prompt=json.loads(sys.argv[8])), ensure_ascii=False))' \
    "$rc_name" "$rc_round" "$rc_case" "$rc_warmup" "$rc_launched" "$rc_trace" "$rc_status" "$rc_prompt" >>"$OUT/manifest.jsonl"
  rc_label="$rc_case"
  [ "$rc_warmup" = yes ] && rc_label="warm-up"
  if [ "$rc_status" = traced ]; then
    say "  $rc_name, $rc_label: $(python3 "$HELPER" show "$OUT/traces/$rc_trace")"
  else
    say "  $rc_name, $rc_label: $rc_status"
  fi
}
# measure_round ROUND: every build runs every case once; even rounds take the builds in reverse.
measure_round() {
  order="$names"
  if [ $(($1 % 2)) -eq 0 ]; then
    order=""
    for name in $names; do order="$name $order"; done
  fi
  say "Round $1:"
  for name in $order; do
    eval "app=\"\$app_$name\""
    if [ "$app" != "$installed" ]; then
      wait_unlocked || { stopped=4; return 0; }
      if ! xcrun devicectl device install app --device "$DEVICE_ID" "$app" >>"$LOG" 2>&1; then
        say "Installing $name's app failed: see $LOG"
        stopped=1
        return 0
      fi
      installed="$app"
      # The first load of a runtime writes its engine cache (the last one's is deleted): not measured.
      run_case "$name" "$1" warmup yes
      [ -n "$stopped" ] && return 0
    fi
    for case in $cases; do
      run_case "$name" "$1" "$case" no
      [ -n "$stopped" ] && return 0
    done
  done
  # Not the test above as the last status: under set -e a round would end the script.
  return 0
}
record_files
round=1
while [ "$round" -le "$ROUNDS" ] && [ -z "$stopped" ]; do
  measure_round "$round"
  round=$((round + 1))
done
# More rounds while a case lacks undisturbed runs (cli-load.py exits with 3 then).
extra=0
while [ -z "$stopped" ] && [ "$extra" -lt "$EXTRA_ROUNDS" ]; do
  read_records || break
  short=0
  # shellcheck disable=SC2086
  (cd "$OUT" && python3 "$ROOT/scripts/cli-load.py" $files --device iPhone --min-clean "$MIN_CLEAN") >/dev/null || short=$?
  [ "$short" -eq 3 ] || break
  extra=$((extra + 1))
  say "Some cases have fewer than $MIN_CLEAN undisturbed runs: one more round ($extra of at most $EXTRA_ROUNDS)."
  measure_round "$((ROUNDS + extra))"
done

# 3. Read the run.
status=0
echo
read_run || status=$?
rm -rf "$OUT/apps"
echo
echo "Records, traces and reports: $OUT"
"$ROOT/scripts/storage.sh" brief || true
[ -n "$stopped" ] && exit "$stopped"
exit $status

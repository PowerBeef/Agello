#!/bin/sh
# Antigravity PreToolUse hook (file-editing tools):
# 1. While a harness run is building a checkout, deny edits to that checkout's
#    targets (Agello*/, Vendor/LiteRT-LM/, the Xcode project included) until its
#    last xcodebuild has started testing.
# 2. While build-xcframework.sh holds ../LiteRT-LM/dist/.bazel.lock, deny edits
#    anywhere under the locked LiteRT-LM root so ~/.cache/bazel-disk is never poisoned.
# Everything else (docs, .agents/, scripts/, unlocked checkouts) passes.
set -u

input="$(cat 2>/dev/null || true)"
MAIN="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=scripts/lib/harness-lock.sh
. "$MAIN/scripts/lib/harness-lock.sh"

HARNESS_LOCK="$(harness_lock_dir "$MAIN")"
IRT_ROOT="$(dirname "$(dirname "$HARNESS_LOCK")")"
if [ -d "$MAIN/../LiteRT-LM" ]; then
  DEFAULT_LITERT_ROOT="$MAIN/../LiteRT-LM"
else
  DEFAULT_LITERT_ROOT="$IRT_ROOT/../LiteRT-LM"
fi
BAZEL_LOCK="$DEFAULT_LITERT_ROOT/dist/.bazel.lock"

harness_active=0
if info="$(harness_lock_info "$HARNESS_LOCK")" && harness_lock_building "$info"; then
  harness_active=1
fi

bazel_active=0
if bazel_info="$(harness_lock_info "$BAZEL_LOCK")"; then
  bazel_active=1
fi

[ "$harness_active" -eq 1 ] || [ "$bazel_active" -eq 1 ] || exit 0

file="$(printf '%s' "$input" | jq -r '.toolCall.args.Path // .toolCall.args.TargetFile // .toolCall.args.AbsolutePath // .toolCall.args.path // empty' 2>/dev/null)"
[ -n "$file" ] || exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)" || cwd=""
[ -n "$cwd" ] || cwd="$MAIN"

resolve_path() {
  base="$1"
  target="$2"
  /usr/bin/python3 -c 'import os, sys; print(os.path.realpath(os.path.join(sys.argv[1], sys.argv[2])))' "$base" "$target" 2>/dev/null && return 0
  case "$target" in
    /*) p="$target" ;;
    *) p="$base/$target" ;;
  esac
  suffix=""
  while [ ! -d "$p" ] && [ "$p" != "/" ] && [ "$p" != "." ]; do
    suffix="/$(basename "$p")$suffix"
    p="$(dirname "$p")"
  done
  dir="$(cd -P "$p" 2>/dev/null && pwd)" || return 1
  printf '%s%s\n' "${dir%/}" "$suffix"
}

resolved_file="$(resolve_path "$cwd" "$file")" || resolved_file="$file"

if [ "$bazel_active" -eq 1 ]; then
  bazel_root="$(harness_lock_value "$bazel_info" root)"
  [ -n "$bazel_root" ] || bazel_root="$DEFAULT_LITERT_ROOT"
  resolved_bazel_root="$(resolve_path "$MAIN" "$bazel_root")" || resolved_bazel_root="$bazel_root"
  case "$resolved_file" in
    "$resolved_bazel_root" | "$resolved_bazel_root"/*)
      bazel_target="$(harness_lock_value "$bazel_info" target)"
      [ -n "$bazel_target" ] || bazel_target="//agello:CLiteRTLM"
      bazel_pid="$(harness_lock_value "$bazel_info" pid)"
      reason="A Bazel build (\`$bazel_target\`, pid $bazel_pid) holds $BAZEL_LOCK: wait for build-xcframework.sh to finish before editing $resolved_bazel_root so ~/.cache/bazel-disk is never poisoned. Stage changes in the artifact scratch/ folder meanwhile."
      jq -n --arg reason "$reason" '{decision: "deny", reason: $reason}'
      exit 0
      ;;
  esac
fi

if [ "$harness_active" -eq 1 ]; then
  root="$(harness_lock_value "$info" root)"
  resolved_root="$(resolve_path "$MAIN" "$root")" || resolved_root="$root"
  case "$resolved_file" in
    "$resolved_root"/Agello*/* | "$resolved_root"/Vendor/LiteRT-LM/*)
      reason="A harness run (\`$(harness_lock_value "$info" suite)\`, pid $(harness_lock_value "$info" pid)) is building $resolved_root: its Agello* and Vendor/LiteRT-LM folders stay as they are until its last suite starts testing. Stage the change in the artifact scratch/ folder and apply it after the run, or work on files outside the targets (docs/, .agents/, scripts/)."
      jq -n --arg reason "$reason" '{decision: "deny", reason: $reason}'
      exit 0
      ;;
  esac
fi

exit 0

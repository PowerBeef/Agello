#!/bin/sh
# Antigravity PreToolUse hook (file-editing tools): while a harness run is
# building a checkout, an edit to that checkout's targets (Agello*/,
# Vendor/LiteRT-LM/, the Xcode project included) lands half-way through the
# build. Deny those edits until the run's last xcodebuild has started testing.
# Everything else (docs, .agents/, scripts/, other checkouts) passes.
set -u

input="$(cat 2>/dev/null || true)"
MAIN="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=scripts/lib/harness-lock.sh
. "$MAIN/scripts/lib/harness-lock.sh"
info="$(harness_lock_info "$(harness_lock_dir "$MAIN")")" || exit 0
harness_lock_building "$info" || exit 0

file="$(printf '%s' "$input" | jq -r '.toolCall.args.Path // .toolCall.args.TargetFile // .toolCall.args.path // empty' 2>/dev/null)"
root="$(harness_lock_value "$info" root)"
case "$file" in
  "$root"/Agello*/* | "$root"/Vendor/LiteRT-LM/*) ;;
  *) exit 0 ;;
esac

reason="A harness run (\`$(harness_lock_value "$info" suite)\`, pid $(harness_lock_value "$info" pid)) is building $root: its Agello* and Vendor/LiteRT-LM folders stay as they are until its last suite starts testing. Stage the change in the artifact scratch/ folder and apply it after the run, or work on files outside the targets (docs/, .agents/, scripts/)."
jq -n --arg reason "$reason" '{decision: "deny", reason: $reason}'

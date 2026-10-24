#!/bin/sh
# PreToolUse hook (Edit, Write, MultiEdit, NotebookEdit): while a harness run
# builds a checkout, an edit to that checkout's targets (Agello*/, the project
# included) lands half-way through the build. Deny those edits, from any
# session, until the run's last xcodebuild has started testing. Everything
# else (docs, .claude/, scripts/, other checkouts) passes.
set -u

input="$(cat)"
MAIN="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
# shellcheck source=scripts/lib/harness-lock.sh
. "$MAIN/scripts/lib/harness-lock.sh"
info="$(harness_lock_info "$(harness_lock_dir "$MAIN")")" || exit 0
harness_lock_building "$info" || exit 0

file="$(echo "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
root="$(harness_lock_value "$info" root)"
case "$file" in
  "$root"/Agello*/*) ;;
  *) exit 0 ;;
esac

reason="A harness run (\`$(harness_lock_value "$info" suite)\`, pid $(harness_lock_value "$info" pid)) is building $root: its Agello* folders stay as they are until its last suite starts testing. Stage the change in the scratchpad and apply it after the run, or work on files outside the targets (docs, .claude/, scripts/)."
jq -n --arg reason "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'

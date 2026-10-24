#!/bin/sh
# SessionStart hook: prints what a session needs before it starts work, into
# Claude's context. The roadmap's "Current status", git state, free disk, the
# iPhone's connection, and any harness run in progress.
# In a desktop worktree session this runs in the main checkout
# ($CLAUDE_PROJECT_DIR); the session's own checkout is the input's `cwd`.
set -u

MAIN="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cwd="$(jq -r '.cwd // empty' 2>/dev/null)" || cwd=""
[ -n "$cwd" ] || cwd="$MAIN"
# shellcheck source=scripts/lib/harness-lock.sh
. "$MAIN/scripts/lib/harness-lock.sh"

echo "Session context (.claude/hooks/session-start.sh):"
echo
awk '/^## Current status/ {p = 1; print; next} p && /^## / {exit} p' "$MAIN/docs/ROADMAP.md"

top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || top="$cwd"
branch="$(git -C "$top" branch --show-current 2>/dev/null)"
changed="$(git -C "$top" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
unpushed="$(git -C "$MAIN" rev-list --count origin/main..main 2>/dev/null || echo "?")"
if [ "$top" = "$MAIN" ]; then
  echo "- Git: \`$branch\`, $changed changed files; $unpushed commits on main not pushed (push only when asked)."
else
  echo "- Git: worktree \`$branch\` ($top), $changed changed files; main has $unpushed commits not pushed. Merge the branch into main once verified (see CLAUDE.md, \"Claude desktop app\")."
fi

free_kb="$(df -k / | awk 'NR == 2 {print $4}')"
free_gb=$((free_kb / 1048576))
if [ "$free_gb" -lt 30 ]; then
  echo "- Disk: ${free_gb} GB free on /, low: clean up scratch before a build."
else
  echo "- Disk: ${free_gb} GB free on /."
fi

# The iPhone from DEVICE_ID or .mobilebuildmcp/config.yaml, as device.sh reads it.
device="$(
  # shellcheck source=scripts/lib/device.sh
  . "$MAIN/scripts/lib/device.sh"
  resolve_device_id "$MAIN" 2>/dev/null
  echo "$DEVICE_ID"
)"
if [ -n "$device" ]; then
  listing="$(mktemp)"
  xcrun devicectl list devices --json-output "$listing" --quiet >/dev/null 2>&1
  phone="$(jq -r --arg id "$device" '.result.devices[]? | select(.hardwareProperties.udid == $id)
    | "\(.deviceProperties.name): " + ({"wired": "connected by cable", "localNetwork": "reachable over the local network"}[.connectionProperties.transportType // ""] // "not connected")' \
    "$listing" 2>/dev/null)"
  rm -f "$listing"
  echo "- ${phone:-iPhone: not paired with this Mac}."
else
  echo "- iPhone: none configured (.mobilebuildmcp/config.yaml)."
fi

if info="$(harness_lock_info "$(harness_lock_dir "$MAIN")")"; then
  echo "- Harness: running \`$(harness_lock_value "$info" suite)\` on $(harness_lock_value "$info" platform) since $(harness_lock_value "$info" started) (pid $(harness_lock_value "$info" pid), $(harness_lock_value "$info" root)). Start no other run; leave its Agello* folders alone until it's testing."
else
  echo "- Harness: no run in progress."
fi

#!/bin/sh
# Antigravity SessionStart hook: injects Agello's session handoff context into
# the conversation as a systemMessage step.
# Captures: docs/ROADMAP.md "Current status", git state, disk use
# (scripts/storage.sh brief), iPhone reachability, and any active harness lock.
set -u

input="$(cat 2>/dev/null || true)"
MAIN="$(cd "$(dirname "$0")/../.." && pwd)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)" || cwd=""
[ -n "$cwd" ] || cwd="$MAIN"
# shellcheck source=scripts/lib/harness-lock.sh
. "$MAIN/scripts/lib/harness-lock.sh"

build_context() {
  echo "Session context (.agents/hooks/session-start.sh):"
  echo
  awk '/^## Current status/ {p = 1; print; next} p && /^## / {exit} p' "$MAIN/docs/ROADMAP.md"

  top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || top="$cwd"
  branch="$(git -C "$top" branch --show-current 2>/dev/null)"
  changed="$(git -C "$top" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  unpushed="$(git -C "$MAIN" rev-list --count origin/main..main 2>/dev/null || echo "?")"
  if [ "$top" = "$MAIN" ]; then
    echo "- Git: \`$branch\`, $changed changed files; $unpushed commits on main not pushed (push only when asked)."
  else
    echo "- Git: worktree \`$branch\` ($top), $changed changed files; main has $unpushed commits not pushed. Merge the branch into main once verified (see AGENTS.md, \"Antigravity workflow\")."
  fi

  # The project's disk use against its budget, with any scratch to delete.
  if ! "$MAIN/scripts/storage.sh" brief 2>/dev/null; then
    echo "- Storage: $(df -h / | awk 'NR == 2 {print $4}') free on / (scripts/storage.sh could not read all project folders: run it outside the sandbox)."
  fi

  # The iPhone from DEVICE_ID or .mobilebuildmcp/config.yaml, as device.sh reads it.
  device="$(
    # shellcheck source=scripts/lib/device.sh
    . "$MAIN/scripts/lib/device.sh"
    resolve_device_id "$MAIN" 2>/dev/null
    echo "${DEVICE_ID:-}"
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
}

body="$(build_context)"
jq -n --arg msg "$body" '{injectSteps: [{systemMessage: {systemMessage: $msg}}]}'

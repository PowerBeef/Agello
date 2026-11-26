#!/bin/sh
# Antigravity SessionStart hook: injects Agello's session handoff context into
# the conversation as a systemMessage step.
# Prints live operational state FIRST (git, disk, iPhone, harness lock), then
# docs/ROADMAP.md "Current status" defensively capped at 3,000 bytes.
set -u

input="$(cat 2>/dev/null || true)"
MAIN="$(cd "$(dirname "$0")/../.." && pwd)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)" || cwd=""
[ -n "$cwd" ] || cwd="$MAIN"
# shellcheck source=scripts/lib/harness-lock.sh
. "$MAIN/scripts/lib/harness-lock.sh"

run_with_timeout() {
  secs="$1"
  shift
  /usr/bin/perl -e '
    my $secs = shift @ARGV;
    my $pid = fork();
    exit 127 unless defined $pid;
    if ($pid == 0) {
      setpgrp(0, 0);
      exec @ARGV;
      exit 127;
    }
    local $SIG{ALRM} = sub {
      kill "TERM", -$pid;
      select(undef, undef, undef, 0.2);
      kill "KILL", -$pid;
      exit 124;
    };
    alarm $secs;
    waitpid($pid, 0);
    exit($? >> 8);
  ' "$secs" "$@"
}

build_context() {
  echo "Session context (.agents/hooks/session-start.sh):"
  echo

  # 1. Live operational state FIRST so it can never be truncated.
  top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || top="$cwd"
  branch="$(git -C "$top" branch --show-current 2>/dev/null)"
  changed="$(git -C "$top" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  unpushed="$(git -C "$MAIN" rev-list --count origin/main..main 2>/dev/null || echo "?")"
  if [ "$top" = "$MAIN" ]; then
    echo "- Git: \`$branch\`, $changed changed files; $unpushed commits on main not pushed (push only when asked)."
  else
    echo "- Git: worktree \`$branch\` ($top), $changed changed files; main has $unpushed commits not pushed. Merge the branch into main once verified (see AGENTS.md, \"Antigravity workflow\")."
  fi

  # Disk use against the 40 GB project budget, with any scratch to clean.
  if ! "$MAIN/scripts/storage.sh" brief 2>/dev/null; then
    echo "- Storage: $(df -h / | awk 'NR == 2 {print $4}') free on / (scripts/storage.sh could not read all project folders: run it outside the sandbox)."
  fi

  # Configured iPhone reachability (bounded to 5 s so wedged devicectl never stalls startup).
  device="$(
    # shellcheck source=scripts/lib/device.sh
    . "$MAIN/scripts/lib/device.sh"
    resolve_device_id "$MAIN" 2>/dev/null
    echo "${DEVICE_ID:-}"
  )"
  if [ -n "$device" ]; then
    listing="$(mktemp)"
    run_with_timeout 5 xcrun devicectl list devices --json-output "$listing" --quiet >/dev/null 2>&1
    dc_rc=$?
    if [ "$dc_rc" -eq 124 ]; then
      echo "- iPhone: devicectl timed out (>5 s)."
    else
      phone="$(jq -r --arg id "$device" '.result.devices[]? | select(.hardwareProperties.udid == $id)
        | "\(.deviceProperties.name): " + ({"wired": "connected by cable", "localNetwork": "reachable over the local network"}[.connectionProperties.transportType // ""] // "not connected")' \
        "$listing" 2>/dev/null)"
      echo "- ${phone:-iPhone: not paired with this Mac}."
    fi
    rm -f "$listing"
  else
    echo "- iPhone: none configured (.mobilebuildmcp/config.yaml)."
  fi

  if info="$(harness_lock_info "$(harness_lock_dir "$MAIN")")"; then
    echo "- Harness: running \`$(harness_lock_value "$info" suite)\` on $(harness_lock_value "$info" platform) since $(harness_lock_value "$info" started) (pid $(harness_lock_value "$info" pid), $(harness_lock_value "$info" root)). Start no other run; leave its Agello* and Vendor/LiteRT-LM folders alone until it's testing."
  else
    echo "- Harness: no run in progress."
  fi

  # 2. Active roadmap handoff, defensively capped at 3,000 bytes.
  echo
  status="$(awk '/^## Current status/ {p = 1; print; next} p && /^## / {exit} p' "$MAIN/docs/ROADMAP.md")"
  status_bytes="$(printf '%s' "$status" | wc -c | tr -d ' ')"
  if [ "$status_bytes" -gt 3000 ]; then
    printf '%s' "$status" | head -c 3000
    echo
    echo "... (Current status truncated at 3,000 B; read docs/ROADMAP.md and trim ## Current status <= 3 KB)"
  else
    printf '%s\n' "$status"
  fi
}

body="$(build_context)"
jq -n --arg msg "$body" '{injectSteps: [{systemMessage: {systemMessage: $msg}}]}'

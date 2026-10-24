# Shared by scripts/device-harness.sh and the Claude Code hooks in
# .claude/hooks/ (sourced, not run). One harness run at a time on this
# machine: runs share the iPhone or this Mac, and the hooks read the lock to
# guard the checkout being built. The lock is a folder in the main checkout's
# build/, so worktrees share it; its `info` file holds key=value lines:
# pid, root (the checkout being built), platform, suite, log (the current
# suite's raw log), last (yes on the run's last xcodebuild), started.

# Prints the lock folder for the checkout at $1.
harness_lock_dir() {
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || common="$1/.git"
  echo "$(dirname "$common")/build/.harness.lock"
}

# Prints the running harness's info from the lock folder $1, or fails when no
# run holds it (a lock whose process is gone is stale).
harness_lock_info() {
  info="$(cat "$1/info" 2>/dev/null)" || return 1
  pid="$(echo "$info" | sed -n 's/^pid=//p')"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  echo "$info"
}

# Prints one key's value from info text $1.
harness_lock_value() {
  echo "$1" | sed -n "s/^$2=//p"
}

# Succeeds while the run in info text $1 may still build: before its last
# xcodebuild has started testing. Edits to its targets wait until then.
harness_lock_building() {
  [ "$(harness_lock_value "$1" last)" = yes ] || return 0
  log="$(harness_lock_value "$1" log)"
  ! grep -q "^Test Suite '.*' started" "$log" 2>/dev/null
}

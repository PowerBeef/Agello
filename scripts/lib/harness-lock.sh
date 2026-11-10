# Shared by scripts/device-harness.sh, the scripts that relaunch the app
# (device-run.sh, bench-direct.sh), scripts/storage.sh and the Claude Code
# hooks in .claude/hooks/ (sourced, not run). One harness run at a time on this
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

# For scripts that relaunch the app on the iPhone: exits with 3 while a harness
# run on the iPhone holds the lock for the checkout at $1, since a relaunch
# would end the test host and the suite with it.
harness_refuse_while_running() {
  running="$(harness_lock_info "$(harness_lock_dir "$1")")" || return 0
  [ "$(harness_lock_value "$running" platform)" = mac ] && return 0
  echo "A harness run holds the iPhone ($(harness_lock_value "$running" suite), pid $(harness_lock_value "$running" pid)): relaunching the app would end it. Wait for it to finish." >&2
  exit 3
}

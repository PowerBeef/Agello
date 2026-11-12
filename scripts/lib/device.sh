# Shared by the device scripts (sourced, not run). resolve_device_id sets DEVICE_ID from the
# environment, or from deviceId in the git-ignored .mobilebuildmcp/config.yaml; device_preflight
# says whether the iPhone is ready for a run.
# Usage: resolve_device_id <repo-root>

resolve_device_id() {
  local_config="$1/.mobilebuildmcp/config.yaml"
  if [ -z "${DEVICE_ID:-}" ] && [ -f "$local_config" ]; then
    DEVICE_ID="$(sed -n 's/^[[:space:]]*deviceId:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' \
      "$local_config" | head -n 1)"
  fi
  case "${DEVICE_ID:-}" in
    "" | "<your-iphone-udid>")
      echo "No device. Set DEVICE_ID=<udid>, or copy .mobilebuildmcp/config.example.yaml" >&2
      echo "to .mobilebuildmcp/config.yaml and set deviceId (xcrun devicectl list devices)." >&2
      exit 2
      ;;
  esac
}

# Before an iPhone run builds anything: the one thing to fix, if there is one, and 4. A locked
# phone otherwise stalls the run at "Unlock iPhone to Continue" after the whole build.
# Usage: device_preflight (after resolve_device_id)
device_preflight() {
  if ! xcrun devicectl list devices 2>/dev/null | grep "$DEVICE_ID" | grep -q "available\|connected"; then
    echo "Preflight: the iPhone ($DEVICE_ID) isn't reachable. Connect it, then run again." >&2
    return 4
  fi
  if xcrun devicectl device info lockState --device "$DEVICE_ID" 2>/dev/null | grep -q "passcodeRequired: true"; then
    if pgrep -f ScreenContinuity >/dev/null 2>&1; then
      echo "Preflight: the iPhone is locked and iPhone Mirroring is open, which keeps it locked. Close iPhone Mirroring and unlock the iPhone, then run again." >&2
    else
      echo "Preflight: the iPhone is locked. Unlock it (and keep it unlocked for the run), then run again." >&2
    fi
    return 4
  fi
  if pgrep -f ScreenContinuity >/dev/null 2>&1; then
    echo "Preflight: iPhone Mirroring is open. It connects when the phone locks and would stop the run: close it." >&2
    return 4
  fi
  free_gb="$(df -g / | awk 'NR == 2 {print $4}')"
  if [ "${free_gb:-99}" -lt 10 ]; then
    echo "Preflight: only $free_gb GB free on this Mac; a build needs room. Run scripts/storage.sh." >&2
    return 4
  fi
  return 0
}

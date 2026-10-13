# Shared by the device scripts (sourced, not run). Sets DEVICE_ID from the
# environment, or from deviceId in the git-ignored .mobilebuildmcp/config.yaml.
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

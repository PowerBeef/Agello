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
  if ! xcrun devicectl list devices </dev/null 2>/dev/null | grep "$DEVICE_ID" | grep -q "available\|connected"; then
    echo "Preflight: the iPhone ($DEVICE_ID) isn't reachable. Connect it, then run again." >&2
    return 4
  fi
  if xcrun devicectl device info lockState --device "$DEVICE_ID" </dev/null 2>/dev/null | grep -q "passcodeRequired: true"; then
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

# Parse `devicectl device info details --json-output <file>` into `<percent|unknown>\t<state>`.
# Handles Xcode CoreDevice's `DeviceBatteryInfo` / `DeviceBatteryState` Codable payloads as well
# as flat/legacy battery & power keys, returning `unknown\tunknown` when keys are absent.
parse_devicectl_battery_json() {
  python3 -c '
import json, re, sys

def norm_level(v):
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, str):
        m = re.match(r"^\s*(-?\d+(?:\.\d+)?)\s*%?\s*$", v)
        if not m:
            return None
        pct = "%" in v
        v = float(m.group(1))
        if v < 0:
            return None
        if not pct and 0.0 < v <= 1.0 and "." in m.group(1):
            return int(round(v * 100))
        return int(round(v)) if 0.0 <= v <= 100.0 else None
    if isinstance(v, float):
        if v < 0:
            return None
        if 0.0 < v <= 1.0:
            return int(round(v * 100))
        return int(round(v)) if 0.0 <= v <= 100.0 else None
    if isinstance(v, int):
        return v if 0 <= v <= 100 else None
    return None

def norm_state_obj(v):
    if isinstance(v, dict):
        if "charging" in v and isinstance(v["charging"], dict):
            return "plugged in" if v["charging"].get("isFailingToCharge") is True else "charging"
        for k, mapped in (
            ("charging", "charging"),
            ("charged", "plugged in"),
            ("full", "plugged in"),
            ("pluggedIn", "plugged in"),
            ("draining", "unplugged"),
            ("unplugged", "unplugged"),
            ("discharging", "unplugged"),
            ("onBattery", "unplugged"),
        ):
            if k in v and isinstance(v[k], dict):
                return mapped
        if "notSupported" in v or "unknown" in v:
            return None
    if isinstance(v, str):
        s = re.sub(r"[\s_-]+", "", v.strip().lower())
        if s == "charging":
            return "charging"
        if s in ("charged", "full", "fullycharged", "plugged", "pluggedin", "ac", "acpower", "external", "externalpower", "connected", "wired", "wireless", "mains"):
            return "plugged in"
        if s in ("unplugged", "draining", "discharging", "battery", "batterypower", "onbattery", "disconnected", "internal"):
            return "unplugged"
    return None

def extract(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            root = json.load(f)
    except Exception:
        return "unknown", "unknown"
    if not isinstance(root, dict):
        return "unknown", "unknown"
    res = root.get("result") if isinstance(root.get("result"), dict) else root

    scopes = []
    seen = set()
    def push(d, in_batt=False):
        if isinstance(d, dict) and id(d) not in seen:
            seen.add(id(d))
            scopes.append((d, in_batt))
            for k, sub in d.items():
                if isinstance(sub, dict):
                    kl = k.lower()
                    push(sub, in_batt or ("battery" in kl or "power" in kl or "charge" in kl))

    for top_key in ("properties", "deviceProperties", "hardwareProperties"):
        if isinstance(res.get(top_key), dict):
            push(res[top_key])
    push(res)

    level = None
    for d, in_batt in scopes:
        for k in ("batteryLevel", "batteryCurrentCapacity", "currentCapacity", "batteryPercentage", "batteryPercent", "chargePercentage"):
            if k in d:
                level = norm_level(d[k])
                if level is not None:
                    break
        if level is None and in_batt:
            for k in ("level", "percentage", "percent", "capacity"):
                if k in d:
                    level = norm_level(d[k])
                    if level is not None:
                        break
        if level is None and "battery" in d and not isinstance(d["battery"], dict):
            level = norm_level(d["battery"])
        if level is not None:
            break

    state = None
    is_charging = None
    ext_connected = None
    fully_charged = None
    failing_charge = None
    for d, in_batt in scopes:
        for k in ("batteryState", "chargingState", "powerState", "externalPowerState", "powerSource"):
            if k in d:
                state = norm_state_obj(d[k])
                if state is not None:
                    break
        if state is None and in_batt:
            for k in ("state", "status"):
                if k in d:
                    state = norm_state_obj(d[k])
                    if state is not None:
                        break
        if state is not None:
            break
        for k in ("batteryIsCharging", "isCharging", "charging"):
            if k in d and isinstance(d[k], bool) and is_charging is None:
                is_charging = d[k]
        for k in ("externalConnected", "isPluggedIn", "pluggedIn", "acPowered", "externalPowerConnected"):
            if k in d and isinstance(d[k], bool) and ext_connected is None:
                ext_connected = d[k]
        for k in ("fullyCharged", "isCharged", "charged"):
            if k in d and isinstance(d[k], bool) and fully_charged is None:
                fully_charged = d[k]
        if "isFailingToCharge" in d and isinstance(d["isFailingToCharge"], bool) and failing_charge is None:
            failing_charge = d["isFailingToCharge"]

    if state is None:
        if is_charging is True:
            state = "plugged in" if failing_charge is True else "charging"
        elif ext_connected is True or fully_charged is True:
            state = "plugged in"
        elif ext_connected is False or is_charging is False:
            state = "unplugged"

    return (str(level) if level is not None else "unknown"), (state or "unknown")

lvl, st = extract(sys.argv[1] if len(sys.argv) > 1 else "")
print(f"{lvl}\t{st}")
' "${1:-}"
}

# Query the iPhone's battery level and charging/power state via `devicectl` (bounded by 5 s).
device_battery_info() {
  batt_tmp="$(mktemp "${TMPDIR:-/tmp}/agello-batt.XXXXXX")"
  perl -e 'alarm 5; exec @ARGV' xcrun devicectl device info details \
    --device "$DEVICE_ID" --timeout 5 --json-output "$batt_tmp" --quiet \
    </dev/null >/dev/null 2>&1 || true
  parse_devicectl_battery_json "$batt_tmp"
  rm -f "$batt_tmp"
}

# Print iPhone battery % & charging state before benchmark runs, warning when < 50% unplugged
# (never failing preflight if battery keys are absent or unknown).
device_battery_preflight() {
  batt_info="$(device_battery_info)"
  batt_pct="${batt_info%%	*}"
  batt_state="${batt_info#*	}"
  if [ "$batt_pct" = unknown ]; then
    DEVICE_BATTERY_LINE="Preflight: iPhone battery unknown (power: $batt_state)."
  else
    DEVICE_BATTERY_LINE="Preflight: iPhone battery ${batt_pct}% ($batt_state)."
  fi
  echo "$DEVICE_BATTERY_LINE"
  DEVICE_BATTERY_WARNING=""
  case "$batt_pct" in
    '' | *[!0-9]*) ;;
    *)
      if [ "$batt_pct" -lt 50 ] && [ "$batt_state" = unplugged ]; then
        DEVICE_BATTERY_WARNING="WARNING: iPhone battery is ${batt_pct}% unplugged — A19 Pro GPU step time can slow by up to +23% even at nominal thermalState (plug in >= 80% for clean speed baselines)."
        echo "$DEVICE_BATTERY_WARNING" >&2
      fi
      ;;
  esac
  return 0
}

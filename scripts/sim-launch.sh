#!/bin/sh
# Boot an iOS Simulator, grant sandboxed Calendar/Reminders/Contacts/Photos/Location permissions,
# spoof GPS coordinates for Maps testing, ensure `agello serve` is running on 127.0.0.1,
# build `AgelloSim`, install it, and launch it.
#
# Usage:
#   scripts/sim-launch.sh [--reset] [--no-build] [--no-serve] [--mock]
# Env:
#   SIM_DEVICE    Simulator name or UDID (default: "iPhone 18 Pro")
#   SIM_PORT      agello serve loopback port (default: 8091)
#   SIM_LOCATION  lat,lon for Maps "near me" testing (default: 45.5017,-73.5673, Montreal)
#   SIM_GPU       Metal GPU family emulation for agello serve (default: Apple_A19_Pro; native/off for native)
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM_DEVICE="${SIM_DEVICE:-iPhone 18 Pro}"
SIM_PORT="${SIM_PORT:-8091}"
SIM_LOCATION="${SIM_LOCATION:-45.5017,-73.5673}"
BUNDLE_ID="com.patricedery.agello.sim"
RESET=0
BUILD=1
START_SERVE=1
MOCK=0

for arg in "$@"; do
  case "$arg" in
    --reset) RESET=1 ;;
    --no-build) BUILD=0 ;;
    --no-serve) START_SERVE=0 ;;
    --mock) MOCK=1; START_SERVE=0 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# 1. Resolve Simulator UDID (accepts either a UDID or a device name).
UDID="$(xcrun simctl list devices available -j | python3 -c "
import json, sys
target = sys.argv[1]
data = json.load(sys.stdin)['devices']
for runtime, devs in data.items():
    if 'iOS' not in runtime:
        continue
    for d in devs:
        if d.get('udid') == target or d.get('name') == target:
            print(d['udid'])
            sys.exit(0)
sys.exit(1)
" "$SIM_DEVICE")" || {
  echo "Simulator '$SIM_DEVICE' not found. Available iOS simulators:" >&2
  xcrun simctl list devices available | grep -E "iPhone|iOS" >&2
  exit 1
}

echo "Simulator: $SIM_DEVICE ($UDID)"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

# 2. Ensure `agello serve` is listening on 127.0.0.1:$SIM_PORT unless --no-serve / --mock.
if [ "$START_SERVE" -eq 1 ]; then
  BIN="$ROOT/build/cli/release/release/agello"
  PID_FILE="$ROOT/build/sim/serve.pid"
  mkdir -p "$ROOT/build/sim"
  if [ "$BUILD" -eq 1 ] || [ ! -x "$BIN" ]; then
    echo "Building release Mac CLI (agello serve)..."
    swift build --package-path "$ROOT" -c release --scratch-path "$ROOT/build/cli/release" </dev/null
  fi
  expected_build="$("$BIN" env --trace-dir "$ROOT/build/sim/env-traces" </dev/null 2>/dev/null \
    | python3 -c '
import json, sys
try:
    rb = (json.load(sys.stdin).get("machine") or {}).get("runtimeBuild")
    if isinstance(rb, dict):
        print(rb.get("build_id") or "unknown")
    elif isinstance(rb, str) and rb:
        print(rb)
    else:
        print("unknown")
except Exception:
    print("")
')"
  rm -rf "$ROOT/build/sim/env-traces"

  health_json="$(curl -sf "http://127.0.0.1:$SIM_PORT/health" 2>/dev/null || true)"
  if [ -n "$health_json" ]; then
    restart_reason="$(python3 -c '
import json, sys
raw, expected = sys.argv[1], sys.argv[2]
if not expected:
    sys.exit(0)
try:
    data = json.loads(raw)
except Exception:
    print("invalid /health JSON")
    sys.exit(0)
if not isinstance(data, dict):
    print("unexpected /health payload")
    sys.exit(0)
rb = None
for key in ("runtime_build", "runtimeBuild", "build"):
    if key in data and data[key] is not None:
        val = data[key]
        if isinstance(val, dict):
            val = val.get("build_id")
        if isinstance(val, str) and val != "":
            rb = val
            break
if rb is not None and rb != expected:
    print(f"runtime_build {rb} != expected {expected}")
' "$health_json" "$expected_build")"
    if [ -z "$restart_reason" ] && [ -f "$PID_FILE" ] && [ "$BIN" -nt "$PID_FILE" ]; then
      restart_reason="rebuilt CLI binary is newer than running daemon"
    fi
    if [ -n "$restart_reason" ]; then
      echo "Restarting agello serve on 127.0.0.1:$SIM_PORT ($restart_reason)..."
      killed_serve=0
      serve_pid=""
      if [ -f "$PID_FILE" ]; then
        serve_pid="$(tr -d '[:space:]' <"$PID_FILE")"
        case "$serve_pid" in
          '' | *[!0-9]*) serve_pid="" ;;
          *)
            serve_comm="$(ps -p "$serve_pid" -o comm= 2>/dev/null || true)"
            case "$serve_comm" in
              *agello*)
                kill "$serve_pid" 2>/dev/null || true
                killed_serve=1
                ;;
            esac
            ;;
        esac
        rm -f "$PID_FILE"
      fi
      if [ "$killed_serve" -eq 0 ]; then
        pkill -f "$BIN serve --port $SIM_PORT" 2>/dev/null \
          || pkill -f "agello serve --port $SIM_PORT" 2>/dev/null || true
      fi
      for _ in $(seq 1 25); do
        if ! curl -sf "http://127.0.0.1:$SIM_PORT/health" >/dev/null 2>&1; then
          if [ "$killed_serve" -eq 0 ] || ! kill -0 "$serve_pid" 2>/dev/null; then
            break
          fi
        fi
        sleep 0.2
      done
      if [ "$killed_serve" -eq 1 ] && kill -0 "$serve_pid" 2>/dev/null; then
        kill -9 "$serve_pid" 2>/dev/null || true
        sleep 0.2
      fi
      health_json=""
    fi
  fi

  if [ -z "$health_json" ]; then
    # Translate SIM_GPU to AGELLO_SIMULATE_APPLE_GPU (matching cli-test.sh / cli-bench.sh).
    if [ -z "${AGELLO_SIMULATE_APPLE_GPU+x}" ]; then
      SIM_GPU="${SIM_GPU:-Apple_A19_Pro}"
      case "$SIM_GPU" in
        native | off | none | "") unset AGELLO_SIMULATE_APPLE_GPU ;;
        *) export AGELLO_SIMULATE_APPLE_GPU="$SIM_GPU" ;;
      esac
    elif [ -z "$AGELLO_SIMULATE_APPLE_GPU" ]; then
      unset AGELLO_SIMULATE_APPLE_GPU
    fi
    echo "Starting agello serve on 127.0.0.1:$SIM_PORT (GPU profile: ${AGELLO_SIMULATE_APPLE_GPU:-native})..."
    if [ -n "${AGELLO_SIMULATE_APPLE_GPU:-}" ]; then
      nohup env AGELLO_SIMULATE_APPLE_GPU="$AGELLO_SIMULATE_APPLE_GPU" MallocLargeCache=0 "$BIN" serve \
        --port "$SIM_PORT" --model-id google/gemma-4-E4B-it \
        >"$ROOT/build/sim/serve.log" 2>&1 </dev/null &
    else
      nohup env MallocLargeCache=0 "$BIN" serve \
        --port "$SIM_PORT" --model-id google/gemma-4-E4B-it \
        >"$ROOT/build/sim/serve.log" 2>&1 </dev/null &
    fi
    echo $! >"$PID_FILE"
    ready=0
    for _ in $(seq 1 60); do
      if curl -sf "http://127.0.0.1:$SIM_PORT/health" >/dev/null 2>&1; then
        ready=1
        break
      fi
      sleep 1
    done
    if [ "$ready" -ne 1 ]; then
      echo "agello serve did not become ready in 60s. See build/sim/serve.log:" >&2
      tail -n 30 "$ROOT/build/sim/serve.log" >&2
      exit 1
    fi
  fi
  echo "agello serve ready: $(curl -sf "http://127.0.0.1:$SIM_PORT/health")"
fi

# 3. Build AgelloSim for iOS Simulator.
DERIVED="$ROOT/build/sim/DerivedData"
if [ "$BUILD" -eq 1 ]; then
  echo "Building AgelloSim for Simulator..."
  xcodebuild build \
    -project "$ROOT/Agello.xcodeproj" \
    -scheme AgelloSim \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED" \
    -quiet </dev/null
fi

APP_PATH="$DERIVED/Build/Products/Debug-iphonesimulator/AgelloSim.app"
if [ ! -d "$APP_PATH" ]; then
  echo "Expected built app at $APP_PATH" >&2
  exit 1
fi

# 4. Install, grant sandboxed permissions, spoof GPS location, and launch.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP_PATH"

for perm in calendar reminders contacts photos location location-always; do
  xcrun simctl privacy "$UDID" grant "$perm" "$BUNDLE_ID" 2>/dev/null || true
done
xcrun simctl location "$UDID" set "$SIM_LOCATION" 2>/dev/null || true

LAUNCH_ARGS=""
if [ "$RESET" -eq 1 ]; then LAUNCH_ARGS="$LAUNCH_ARGS --uitest-reset"; fi
if [ "$MOCK" -eq 1 ]; then
  LAUNCH_ARGS="$LAUNCH_ARGS --mock-engine"
else
  LAUNCH_ARGS="$LAUNCH_ARGS --remote-engine http://127.0.0.1:$SIM_PORT/v1"
fi

# shellcheck disable=SC2086
xcrun simctl launch "$UDID" "$BUNDLE_ID" $LAUNCH_ARGS
echo "Launched $BUNDLE_ID on $SIM_DEVICE ($UDID) at location $SIM_LOCATION."

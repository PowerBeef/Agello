#!/bin/sh
# Does the Mac command line (docs/CLI.md) still build? It compiles the app's engine files, so an
# app change can break it: a platform type without its twin in AgelloCLI/Sources/Platform/, or
# an engine file outside the folders Package.swift lists.
#
# Usage: scripts/cli-check.sh [--build]
# Prints one line and exits 0 (builds), 1 (broken) or 0 with a note when this checkout has never
# built the tool (--build builds it anyway: about 300 MB in build/cli/release).
# scripts/device-harness.sh runs it at the end of every run.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$ROOT/build/cli/release"
# The reading of the Mac's load in a run's records (scripts/cli-load.py), on made-up records.
if ! check="$(python3 "$ROOT/scripts/cli-load.py" --self-test 2>&1)"; then
  echo "- Mac command line: the load reading is BROKEN. $(echo "$check" | head -1)"
  exit 1
fi
# The reading of an iPhone comparison's traces (scripts/phone-bench.py), on made-up traces.
if ! check="$(python3 "$ROOT/scripts/phone-bench.py" --self-test 2>&1)"; then
  echo "- Mac command line: the iPhone comparison's reading is BROKEN. $(echo "$check" | head -1)"
  exit 1
fi
if [ ! -d "$SCRATCH" ] && [ "${1:-}" != --build ]; then
  echo "- Mac command line: not built in this checkout (scripts/cli-check.sh --build)."
  exit 0
fi
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
if (cd "$ROOT" && swift build -c release --scratch-path "$SCRATCH") >"$log" 2>&1; then
  echo "- Mac command line: builds."
  exit 0
fi
clean="$(sed 's/\x1b\[[0-9;]*m//g' "$log")"
# The compiler's own line (file:line:column: error: …) says more than the build system's.
first="$(echo "$clean" | grep -m 1 -E ':[0-9]+:[0-9]+: error:' | sed "s|$ROOT/||" | cut -c1-240)"
[ -n "$first" ] || first="$(echo "$clean" | grep -m 1 'error:' | cut -c1-240)"
[ -n "$first" ] || first="No error line in the output of swift build."
echo "- Mac command line: BROKEN. $first"
echo "  Fix it with the change that broke it: swift build -c release --scratch-path build/cli/release (docs/CLI.md)."
exit 1

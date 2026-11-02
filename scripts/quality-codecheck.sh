#!/bin/bash
# The quality bench's code, checked on this Mac: Swift type-checked against the iOS SDK, Python
# byte-compiled. Reads the replies probe 24 (test24_QualityBench) attached in a harness OUT folder.
#
# Usage: scripts/quality-codecheck.sh [OUT]   (default: build/macos-harness)
set -u
OUT="${1:-$(cd "$(dirname "$0")/.." && pwd)/build/macos-harness}"
cd "$OUT/attachments/probes" || { echo "No attachments in $OUT" >&2; exit 2; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
python3 - "$WORK" <<'PY'
import json, os, re, sys
work = sys.argv[1]
for test in json.load(open("manifest.json")):
    for attachment in test["attachments"]:
        name = attachment["suggestedHumanReadableName"].split("_")[0]
        if not name.startswith("quality-"):
            continue
        reply = open(attachment["exportedFileName"]).read().split("**Reply:**", 1)[-1]
        for language, extension in (("swift", "swift"), ("python", "py")):
            blocks = re.findall(r"```" + language + r"\n(.*?)```", reply, re.S)
            if blocks:
                open(os.path.join(work, f"{name}.{extension}"), "w").write("\n\n".join(blocks))
PY
for file in "$WORK"/*.swift; do
  [ -e "$file" ] || continue
  errors="$(xcrun --sdk iphoneos swiftc -typecheck -target arm64-apple-ios27.0 -swift-version 5 "$file" 2>&1 | grep 'error:' | sed 's/^.*error: //' | sort -u)"
  echo "$(basename "$file"): $(printf '%s' "$errors" | grep -c .) distinct Swift errors"
  [ -n "$errors" ] && printf '%s\n' "$errors" | sed 's/^/    /' | head -10
done
for file in "$WORK"/*.py; do
  [ -e "$file" ] || continue
  if python3 -m py_compile "$file" 2>/dev/null; then echo "$(basename "$file"): compiles"
  else echo "$(basename "$file"): fails"; python3 -m py_compile "$file" 2>&1 | tail -1 | sed 's/^/    /'; fi
done

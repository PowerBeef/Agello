#!/bin/sh
# Build Agello against a local LiteRT-LM build, for testing on this Mac or the iPhone.
# Vendors Package.swift, swift/ and LICENSE from a checkout of the fork's agello-next line,
# plus the CLiteRTLM.xcframework its agello/build-xcframework.sh wrote to dist/
# (copied to Vendor/LiteRT-LM/dist/, which git ignores).
# Usage:
#   Vendor/use-local-litert.sh [path/to/LiteRT-LM]   # default: ../agello-arms/next/LiteRT-LM
# Back to the committed (released) package:
#   git checkout -- Vendor/LiteRT-LM && git clean -fdq Vendor/LiteRT-LM && rm -rf Vendor/LiteRT-LM/dist
# Don't commit Vendor/LiteRT-LM while it points at dist/: nobody else has that build.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/../agello-arms/next/LiteRT-LM}"
SRC="$(cd "$SRC" && pwd)"
if [ ! -d "$SRC/dist/CLiteRTLM.xcframework" ]; then
  echo "No $SRC/dist/CLiteRTLM.xcframework: run agello/build-xcframework.sh there first." >&2
  exit 2
fi
DEST="$ROOT/Vendor/LiteRT-LM"
rm -rf "$DEST"
mkdir -p "$DEST/dist"
cp "$SRC/Package.swift" "$SRC/LICENSE" "$DEST/"
cp -R "$SRC/swift" "$DEST/swift"
cp -R "$SRC/dist/CLiteRTLM.xcframework" "$SRC/dist/BUILD-INFO.txt" "$DEST/dist/"
echo "Agello now builds against the local LiteRT-LM in $SRC:"
cat "$DEST/dist/BUILD-INFO.txt"

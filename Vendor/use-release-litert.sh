#!/bin/sh
# Vendor a released build of our LiteRT-LM (PowerBeef/agello-litert-lm, branch agello-next):
# Package.swift, swift/ and LICENSE from the fork at REF, with the CLiteRTLM binary target pointed
# at the GitHub release TAG (agello/release-xcframework.sh made it) and its checksum.
# Usage:
#   REF=<agello-next commit> TAG=<release tag> Vendor/use-release-litert.sh
# Commit the result; then update Vendor/README.md, NOTICE (the release's THIRD_PARTY_NOTICES.md)
# and the README's "Vendored LiteRT-LM" section, and run the suites on the iPhone.
# Back to Google's binary: REF=<agello commit> Vendor/refresh-litert-lm.sh.
set -eu
REF="${REF:?set REF to the agello-next commit the release was built from}"
TAG="${TAG:?set TAG to the release tag}"
REPO="${REPO:-PowerBeef/agello-litert-lm}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="https://github.com/$REPO/releases/download/$TAG"
CHECKSUM="$(curl -sL --fail "$BASE/checksum.txt" | tr -d '[:space:]')"
if ! printf '%s' "$CHECKSUM" | grep -Eq '^[0-9a-f]{64}$'; then
  echo "No checksum.txt in release $TAG of $REPO." >&2
  exit 2
fi
REF="$REF" "$ROOT/Vendor/refresh-litert-lm.sh"
URL="$BASE/CLiteRTLM.xcframework.zip" CHECKSUM="$CHECKSUM" perl -0pi -e \
  's|      path: "dist/CLiteRTLM.xcframework"|      url: "$ENV{URL}",\n      checksum: "$ENV{CHECKSUM}"|' \
  "$ROOT/Vendor/LiteRT-LM/Package.swift"
if ! grep -q "checksum: \"$CHECKSUM\"" "$ROOT/Vendor/LiteRT-LM/Package.swift"; then
  echo "Vendor/LiteRT-LM/Package.swift's binary target wasn't rewritten: is REF on agello-next?" >&2
  exit 1
fi
echo "Vendored $REPO@$REF with release $TAG (checksum $CHECKSUM)."

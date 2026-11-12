#!/bin/sh
# Vendor a released build of our LiteRT-LM (PowerBeef/agello-litert-lm, branch agello-next):
# Package.swift, swift/ and LICENSE from the fork at REF, with the CLiteRTLM binary target pointed
# at the GitHub release TAG (agello/release-xcframework.sh made it) and its checksum.
# Usage:
#   REF=<agello-next commit> TAG=<release tag> Vendor/use-release-litert.sh
# Commit the result; then update Vendor/README.md, NOTICE (the release's THIRD_PARTY_NOTICES.md)
# and the README's "Vendored LiteRT-LM" section, and run the suites on the iPhone.
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
# The package surface (Package.swift, swift/, LICENSE) from the fork at REF.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -sL --fail -o "$TMP/litertlm.tar.gz" "https://github.com/${REPO}/archive/${REF}.tar.gz"
mkdir "$TMP/src"
tar xzf "$TMP/litertlm.tar.gz" -C "$TMP/src"
SRC="$(find "$TMP/src" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
rm -rf "$ROOT/Vendor/LiteRT-LM"
mkdir -p "$ROOT/Vendor/LiteRT-LM"
cp "$SRC/Package.swift" "$SRC/LICENSE" "$ROOT/Vendor/LiteRT-LM/"
cp -r "$SRC/swift" "$ROOT/Vendor/LiteRT-LM/swift"
URL="$BASE/CLiteRTLM.xcframework.zip" CHECKSUM="$CHECKSUM" perl -0pi -e \
  's|      path: "dist/CLiteRTLM.xcframework"|      url: "$ENV{URL}",\n      checksum: "$ENV{CHECKSUM}"|' \
  "$ROOT/Vendor/LiteRT-LM/Package.swift"
if ! grep -q "checksum: \"$CHECKSUM\"" "$ROOT/Vendor/LiteRT-LM/Package.swift"; then
  echo "Vendor/LiteRT-LM/Package.swift's binary target wasn't rewritten: is REF on agello-next?" >&2
  exit 1
fi
# A different CLiteRTLM.framework under the same module name leaves a stale precompiled module
# in DerivedData ("module.modulemap has been modified since the module file was built").
# A build doesn't resolve the package again by itself and would keep the last framework (a
# local one too, 2026-11-12), and the app's embedded copy is only replaced by a newer file:
# the built frameworks go, the app's included, and the package is resolved now.
rm -rf "$HOME"/Library/Developer/Xcode/DerivedData/Agello-*/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules/CLiteRTLM-*.pcm \
  "$HOME"/Library/Developer/Xcode/DerivedData/Agello-*/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules/*/CLiteRTLM-*.pcm \
  "$HOME"/Library/Developer/Xcode/DerivedData/Agello-*/Build/Products/*-iphoneos/CLiteRTLM.framework \
  "$HOME"/Library/Developer/Xcode/DerivedData/Agello-*/Build/Products/Debug-*/CLiteRTLM.framework \
  "$HOME"/Library/Developer/Xcode/DerivedData/Agello-*/Build/Products/*/Agello.app/Frameworks/CLiteRTLM.framework
xcodebuild -resolvePackageDependencies -project "$ROOT/Agello.xcodeproj" -scheme Agello >/dev/null 2>&1 || true
echo "Vendored $REPO@$REF with release $TAG (checksum $CHECKSUM)."

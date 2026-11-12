#!/bin/sh
# Build Agello against a local LiteRT-LM build, for testing on this Mac or the iPhone.
# Vendors Package.swift, swift/ and LICENSE from a checkout of the fork's agello-next line,
# plus the CLiteRTLM.xcframework its agello/build-xcframework.sh wrote to dist/
# (copied to Vendor/LiteRT-LM/dist/, which git ignores).
# Usage:
#   Vendor/use-local-litert.sh [path/to/LiteRT-LM]   # default: ../agello-arms/next/LiteRT-LM
# Back to the committed (released) package:
#   git checkout -- Vendor/LiteRT-LM && git clean -fdq Vendor/LiteRT-LM && rm -rf Vendor/LiteRT-LM/dist
#   then delete what this script deletes in DerivedData (below) and resolve the package again
#   (xcodebuild -resolvePackageDependencies -project Agello.xcodeproj -scheme Agello): otherwise
#   Xcode keeps building with the local framework. The harness report's runtimeBuild says which ran.
# LiteRT-LM's cache keys ignore the build: move the app's engine caches aside when switching
# builds (Library/Caches/com.patricedery.agello.litertlm in the app's container).
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
# cp -R copies symbolic links as links, which the Mac slice's versioned framework needs.
cp -R "$SRC/dist/CLiteRTLM.xcframework" "$SRC/dist/BUILD-INFO.txt" "$DEST/dist/"
# The Mac slice is a versioned framework (the fork's M0.1, 78e7edc4); older builds' isn't.
MAC="$DEST/dist/CLiteRTLM.xcframework/macos-arm64/CLiteRTLM.framework"
if [ ! -f "$MAC/Versions/A/CLiteRTLM" ] || [ ! -L "$MAC/Versions/Current" ] || [ ! -L "$MAC/CLiteRTLM" ]; then
  echo "$MAC isn't a versioned framework: rebuild it with the fork's agello-next (78e7edc4 or later)." >&2
  exit 2
fi
# A different CLiteRTLM.framework under the same module name leaves a stale precompiled module
# in DerivedData ("module.modulemap has been modified since the module file was built").
# A build doesn't resolve the package again by itself and would keep the last framework
# (2026-11-12), and the app's embedded copy is only replaced by a newer file: the built
# frameworks go, the app's included, and the package is resolved below.
rm -rf "$HOME"/Library/Developer/Xcode/DerivedData/Agello-*/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules/CLiteRTLM-*.pcm \
  "$HOME"/Library/Developer/Xcode/DerivedData/Agello-*/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules/*/CLiteRTLM-*.pcm \
  "$HOME"/Library/Developer/Xcode/DerivedData/Agello-*/Build/Products/*-iphoneos/CLiteRTLM.framework \
  "$HOME"/Library/Developer/Xcode/DerivedData/Agello-*/Build/Products/Debug-*/CLiteRTLM.framework \
  "$HOME"/Library/Developer/Xcode/DerivedData/Agello-*/Build/Products/*/Agello.app/Frameworks/CLiteRTLM.framework
xcodebuild -resolvePackageDependencies -project "$ROOT/Agello.xcodeproj" -scheme Agello >/dev/null 2>&1 || true
echo "Agello now builds against the local LiteRT-LM in $SRC:"
cat "$DEST/dist/BUILD-INFO.txt"
# Each slice's platform, from its binary and from its Info.plist (they must agree).
for slice in ios-arm64/CLiteRTLM.framework/Info.plist macos-arm64/CLiteRTLM.framework/Resources/Info.plist; do
  framework="$DEST/dist/CLiteRTLM.xcframework/${slice%%/CLiteRTLM.framework/*}/CLiteRTLM.framework"
  binary_platform="$(vtool -show-build "$framework/CLiteRTLM" | sed -n 's/^ *platform //p' | head -n 1)"
  plist_platform="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' \
    "$DEST/dist/CLiteRTLM.xcframework/$slice")"
  echo "${slice%%/*}: binary $binary_platform, Info.plist $plist_platform"
done

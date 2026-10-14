#!/bin/sh
# Refresh the vendored LiteRT-LM Swift package surface (Package.swift, swift/,
# LICENSE) from a GitHub ref.
# Usage:
#   REF=a3c0d0ef ./Vendor/refresh-litert-lm.sh      # the fork's agello branch, pinned (default repo)
#   REPO=google-ai-edge/LiteRT-LM REF=v0.19.0 ./Vendor/refresh-litert-lm.sh   # an upstream tag
# REF can be a branch, a tag or a commit; pin a commit for reproducible builds.
# TAG=... still works as an alias for REF.
set -eu
REPO="${REPO:-PowerBeef/LiteRT-LM}"
REF="${REF:-${TAG:-}}"
if [ -z "$REF" ]; then
  echo "Set REF to a branch, tag or commit, e.g. REF=a3c0d0ef $0" >&2
  exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
echo "Vendored ${REPO}@${REF} into Vendor/LiteRT-LM ($(du -sh "$ROOT/Vendor/LiteRT-LM" | cut -f1))"

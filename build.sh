#!/bin/bash
# Builds the engine into MediaDayKeyer.lrplugin/bin/mdkeyer (Apple silicon + Intel).
#   ./build.sh           build
#   ./build.sh release   build, then zip the plugin into dist/ for a GitHub release
set -euo pipefail
cd "$(dirname "$0")"
OUT=MediaDayKeyer.lrplugin/bin
mkdir -p "$OUT" build
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos14" src/main.swift -o "build/mdkeyer-$arch"
done
lipo -create build/mdkeyer-arm64 build/mdkeyer-x86_64 -output "$OUT/mdkeyer"
codesign --force --sign - "$OUT/mdkeyer"
echo "built $OUT/mdkeyer"

if [[ "${1:-}" == "release" ]]; then
  VERSION=$(sed -n 's/.*major *= *\([0-9]*\), *minor *= *\([0-9]*\), *revision *= *\([0-9]*\).*/\1.\2.\3/p' MediaDayKeyer.lrplugin/Info.lua)
  mkdir -p dist
  rm -f "dist/MediaDayKeyer-$VERSION.zip"
  ditto -c -k --norsrc --noextattr --noqtn --keepParent MediaDayKeyer.lrplugin "dist/MediaDayKeyer-$VERSION.zip"
  echo "packed dist/MediaDayKeyer-$VERSION.zip"
fi

#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
FLAGS='-std=c++17 -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations'
if [ "$(uname -s)" = Darwin ]; then
  OUT="${TMPDIR:-/tmp}/torrent-worker-runtime-$$"
  trap 'rm -f "$OUT"' EXIT
  xcrun clang++ $FLAGS -framework Foundation -framework AVFoundation -framework CoreMedia -framework CoreGraphics tests/torrent-worker-runtime.mm -o "$OUT"
  "$OUT"
  SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
  xcrun --sdk iphoneos clang++ $FLAGS -arch arm64e -miphoneos-version-min=15.0 -isysroot "$SDK" -fsyntax-only btworker/main.mm
else
  SDK="${PVX_SDK:-/root/theos/sdks/iPhoneOS16.5.sdk}"
  clang++ $FLAGS -target arm64e-apple-ios15.0 -isysroot "$SDK" -fsyntax-only btworker/main.mm
  clang++ $FLAGS -target arm64e-apple-ios15.0 -isysroot "$SDK" -fsyntax-only tests/torrent-worker-runtime.mm
  echo 'PASS strict iOS cross syntax (worker + runtime tests); executable tests require macOS'
fi

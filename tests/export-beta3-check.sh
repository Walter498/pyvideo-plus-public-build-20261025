#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" = Darwin ]; then
  OUT="${TMPDIR:-/tmp}/export-beta3-$$"
  trap 'rm -f "$OUT"' EXIT
  xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations -framework Foundation tests/export-beta3.m -o "$OUT"
  "$OUT"
  SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
  xcrun --sdk iphoneos clang -arch arm64e -miphoneos-version-min=15.0 -isysroot "$SDK" -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations -I src -fsyntax-only src/TaskSupport.m
else
  SDK="${PVX_SDK:-/root/theos/sdks/iPhoneOS16.5.sdk}"
  clang -target arm64e-apple-ios15.0 -isysroot "$SDK" -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations -I src -fsyntax-only src/TaskSupport.m
  clang -target arm64-apple-ios15.0 -isysroot "$SDK" -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations -DPVX_TEST=1 -DPVX_FOUNDATION_TEST=1 -fsyntax-only tests/export-beta3.m
  echo 'PASS iOS SDK strict syntax; executable Foundation tests require macOS'
fi

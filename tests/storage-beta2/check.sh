#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
OUT=$(mktemp -d /tmp/pvx-storage-check.XXXXXX)
trap 'rm -rf "$OUT"' EXIT HUP INT TERM
clang -x c -Wall -Wextra -Werror "$ROOT/tests/storage-beta2/io.c" -o "$OUT/io"
"$OUT/io"
if [ "$(uname -s)" = Darwin ]; then
 SDK=$(xcrun --sdk iphoneos --show-sdk-path)
else
 SDK=/root/theos/sdks/iPhoneOS16.5.sdk
fi
clang -target arm64-apple-ios15.0 -fobjc-arc -fblocks -fsyntax-only -isysroot "$SDK" -Wall -Wextra -Werror "$ROOT/storage/Storage.m"
clang -target arm64-apple-ios15.0 -fobjc-arc -fblocks -c -isysroot "$SDK" -Wall -Wextra -Werror "$ROOT/storage/Storage.m" -o "$OUT/Storage.o"
clang -target arm64-apple-ios15.0 -fobjc-arc -fblocks -c -isysroot "$SDK" -Wall -Wextra -Werror "$ROOT/storage/PVXHLSManifest.m" -o "$OUT/PVXHLSManifest.o"
clang -target arm64-apple-ios15.0 -fobjc-arc -fblocks -fsyntax-only -isysroot "$SDK" -Wall -Wextra -Werror -Wno-unused-function -Wno-unused-variable "$ROOT/tests/storage-beta2/mock.m"
echo 'PASS SDK16.5: strict production syntax + arm64 object; Foundation mock syntax only (not executed)'
# On macOS ONLY, execute the Foundation mock against production hook bodies:
if [ "$(uname -s)" = Darwin ]; then
    xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-function -Wno-unused-variable -Wno-deprecated-declarations "$ROOT/tests/storage-beta2/mock.m" "$ROOT/storage/PVXHLSManifest.m" -framework Foundation -framework AVFoundation -o "$OUT/mock"
    "$OUT/mock"
fi

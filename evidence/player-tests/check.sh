#!/bin/sh
# Cross-compilation only. No iOS installation or UI execution.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SDK26=/root/.ios-sdk/iPhoneOS26.5.sdk
SDK16=/root/theos/sdks/iPhoneOS16.5.sdk
OUT=$(mktemp -d /tmp/pvx-player-test.XXXXXX)
trap 'rm -rf "$OUT"' EXIT HUP INT TERM
for SDK in "$SDK26" "$SDK16"; do
    test -d "$SDK"
    echo "Checking Player.m with $(basename "$SDK"), deployment target iOS15"
    if [ "$SDK" = "$SDK26" ]; then
        clang -target arm64-apple-ios15.0 -fobjc-arc -fblocks -fsyntax-only \
            -isysroot "$SDK" -F"$SDK/System/Library/SubFrameworks" \
            -Wall -Wextra -Werror "$ROOT/src/Player.m"
        clang -target arm64-apple-ios15.0 -fobjc-arc -fblocks -c \
            -isysroot "$SDK" -F"$SDK/System/Library/SubFrameworks" \
            -Wall -Wextra -Werror "$ROOT/src/Player.m" -o "$OUT/Player26.o"
    else
        clang -target arm64-apple-ios15.0 -fobjc-arc -fblocks -fsyntax-only \
            -isysroot "$SDK" -Wall -Wextra -Werror "$ROOT/src/Player.m"
        clang -target arm64-apple-ios15.0 -fobjc-arc -fblocks -c \
            -isysroot "$SDK" -Wall -Wextra -Werror "$ROOT/src/Player.m" \
            -o "$OUT/Player16.o"
    fi
done
echo 'PASS: both SDKs, strict syntax and arm64 Mach-O object compilation; no runtime test'

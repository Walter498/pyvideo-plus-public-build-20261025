#!/bin/sh
# Runs real AVFoundation on macOS; Linux does Apple-SDK syntax checks only.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODE=auto
case "${1:-}" in
  --help|-h)
    cat <<'HELP'
Usage: sh tests/media-validator-check.sh [--syntax-only]
macOS: requires Xcode Command Line Tools, python3, ffmpeg (lavfi/libx264/AAC).
       Generates CC0 fixtures, links production module, runs real decode tests.
Linux: requires clang and Apple iPhoneOS SDK; performs syntax checks ONLY.
       SDK defaults to /root/theos/sdks/iPhoneOS16.5.sdk; override PVX_IOS_SDK.
--syntax-only: perform only arm64 iOS15+ compilation checks on either host.
Frameworks: Foundation AVFoundation CoreMedia CoreVideo CoreGraphics.
Does not connect to devices, install applications, or modify git.
HELP
    exit 0 ;;
  --syntax-only) MODE=syntax ;;
  '') ;;
  *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac
OUT=$(mktemp -d "${TMPDIR:-/tmp}/pvx-media-validator.XXXXXX")
trap 'rm -rf "$OUT"' EXIT HUP INT TERM
if [ "$(uname -s)" = Darwin ] && [ "$MODE" = auto ]; then
    command -v python3 >/dev/null
    command -v ffmpeg >/dev/null
    python3 "$ROOT/tests/media-validator-fixtures.py" "$OUT/fixtures"
    # Legacy asynchronous loading APIs are intentional for iOS15 compatibility.
    xcrun --sdk macosx clang -mmacosx-version-min=13.0 -fobjc-arc -fblocks \
        -Wall -Wextra -Werror -Wno-deprecated-declarations \
        "$ROOT/storage/PVXMediaValidator.m" "$ROOT/tests/media-validator-test.m" \
        -framework Foundation -framework AVFoundation -framework CoreMedia \
        -framework CoreVideo -framework CoreGraphics -o "$OUT/media-validator-test"
    "$OUT/media-validator-test" "$OUT/fixtures"
else
    if [ "$(uname -s)" = Darwin ]; then
        SDK=${PVX_IOS_SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}
    else
        SDK=${PVX_IOS_SDK:-/root/theos/sdks/iPhoneOS16.5.sdk}
    fi
    test -d "$SDK" || { echo "Missing Apple SDK: $SDK" >&2; exit 2; }
    clang -target arm64-apple-ios15.0 -isysroot "$SDK" -fobjc-arc -fblocks \
        -fsyntax-only -Wall -Wextra -Werror -Wno-deprecated-declarations \
        "$ROOT/storage/PVXMediaValidator.m" "$ROOT/tests/media-validator-test.m"
    echo 'PASS production + test strict iOS15 syntax; no media decode executed on Linux'
fi

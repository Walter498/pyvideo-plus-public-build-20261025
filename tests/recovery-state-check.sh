#!/bin/sh
# fake-remux only: production recovery + real AVFoundation, NOT original iOS libav.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
MODE=auto
case "${1:-}" in
    --help|-h)
        cat <<'HELP'
Usage: sh tests/recovery-state-check.sh [--syntax-only]
macOS: Xcode Command Line Tools, python3, ffmpeg (lavfi/libx264/AAC).
Runs six production recovery lifecycle cases using explicit fake-remux C exports.
Copies generated CC0 H264/AAC MP4, runs actual AVFoundation output validation.
188-byte non-media HLS fragments test localizer semantics ONLY; no HLS decoding.
Does NOT prove original iOS libav remux works. No devices, installs, or git writes.
Linux: strict Apple-SDK syntax checks ONLY, then exit 77 (runtime unavailable).
--syntax-only: syntax checks only, exit 0 on success (no execution claim).
PVX_IOS_SDK overrides /root/theos/sdks/iPhoneOS16.5.sdk on Linux.
HELP
        exit 0 ;;
    --syntax-only) MODE=syntax ;;
    '') ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac
OUT=$(mktemp -d "${TMPDIR:-/tmp}/pvx-recovery-state.XXXXXX")
trap 'rm -rf "$OUT"' EXIT HUP INT TERM
# Storage.m is included once by the test, bringing in the real PVXRecovery.inc.
set -- "$ROOT/tests/recovery-state-test.m" \
    "$ROOT/storage/PVXHLSManifest.m" "$ROOT/storage/PVXHLSLocalizer.m" "$ROOT/storage/PVXLibavInput.m" \
    "$ROOT/storage/PVXNativeRemux.m" "$ROOT/storage/PVXMediaValidator.m"
if [ "$(uname -s)" = Darwin ] && [ "$MODE" = auto ]; then
    command -v python3 >/dev/null
    command -v ffmpeg >/dev/null
    python3 "$ROOT/tests/media-validator-fixtures.py" "$OUT/fixtures"
    xcrun --sdk macosx clang -mmacosx-version-min=13.0 -fobjc-arc -fblocks \
        -DPVX_NATIVE_REMUX_TESTING=1 -Wall -Wextra -Werror \
        -Wno-unused-function -Wno-unused-variable -Wno-unused-parameter \
        -Wno-deprecated-declarations "$@" \
        -framework Foundation -framework AVFoundation -framework CoreMedia \
        -framework CoreVideo -framework CoreGraphics -Wl,-export_dynamic \
        -o "$OUT/recovery-state-test"
    "$OUT/recovery-state-test" "$OUT/fixtures"
else
    if [ "$(uname -s)" = Darwin ]; then
        SDK=${PVX_IOS_SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}
    else
        SDK=${PVX_IOS_SDK:-/root/theos/sdks/iPhoneOS16.5.sdk}
    fi
    test -d "$SDK" || { echo "Missing Apple SDK: $SDK" >&2; exit 2; }
    clang -target arm64-apple-ios15.0 -isysroot "$SDK" -fobjc-arc -fblocks \
        -DPVX_NATIVE_REMUX_TESTING=1 -fsyntax-only -Wall -Wextra -Werror \
        -Wno-unused-function -Wno-unused-variable -Wno-unused-parameter \
        -Wno-deprecated-declarations "$@"
    echo 'PASS syntax ONLY: production recovery + all modules + fake-remux test (no decode executed)'
    if [ "$MODE" = auto ]; then
        echo 'SKIP macOS runtime unavailable; fake-remux lifecycle tests NOT executed (exit 77)' >&2
        exit 77
    fi
fi

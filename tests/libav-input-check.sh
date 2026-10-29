#!/bin/sh
# Actual production Foundation execution requires macOS; Linux is syntax-only.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODE=${1:-}
case "$MODE" in ''|--syntax-only) ;; *) echo "usage: sh tests/libav-input-check.sh [--syntax-only]" >&2; exit 2;; esac
WORK=${PVX_LIBAV_INPUT_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/pvx libav input.XXXXXX")}
mkdir -p "$WORK"
echo "Libav input artifacts: $WORK"
python3 -c 'import ast,pathlib,sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())' "$ROOT/tests/libav-input-media.py"
if [ "$(uname -s)" != Darwin ] || [ "$MODE" = --syntax-only ]; then
    if [ "$(uname -s)" = Darwin ]; then
        SDK=${PVX_IOS_SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}
    else
        SDK=${PVX_IOS_SDK:-/root/theos/sdks/iPhoneOS16.5.sdk}
    fi
    test -d "$SDK" || { echo "Missing Apple SDK: $SDK" >&2; exit 2; }
    clang -target arm64-apple-ios15.0 -isysroot "$SDK" -fobjc-arc -fblocks \
        -fsyntax-only -Wall -Wextra -Werror -I "$ROOT/storage" \
        "$ROOT/tests/libav-input-test.m" "$ROOT/storage/PVXLibavInput.m"
    echo 'PASS Apple SDK syntax ONLY; Foundation runtime not executed.'
    [ "$MODE" = --syntax-only ] && exit 0
    echo 'SKIP runtime: macOS Foundation required.'
    exit 77
fi
for tool in ffmpeg ffprobe openssl; do command -v "$tool" >/dev/null 2>&1 || { echo "Missing $tool" >&2; exit 2; }; done
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -I "$ROOT/storage" "$ROOT/tests/libav-input-test.m" "$ROOT/storage/PVXLibavInput.m" \
    -framework Foundation -o "$WORK/input test"
python3 "$ROOT/tests/libav-input-media.py" --cli "$WORK/input test" --work-dir "$WORK"

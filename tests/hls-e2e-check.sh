#!/bin/sh
# macOS host media semantics, NOT proof of iOS/libav remux success.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODE=${1:-}
case "$MODE" in ''|--syntax-only) ;; *) echo "usage: sh tests/hls-e2e-check.sh [--syntax-only]" >&2; exit 2;; esac
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pvx hls e2e.XXXXXX")
echo "HLS E2E artifacts (retained): $WORK"
if [ "$(uname -s)" != Darwin ] || [ "$MODE" = --syntax-only ]; then
    if [ "$(uname -s)" = Darwin ]; then
        SDK=${PVX_IOS_SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}
    else
        SDK=${PVX_IOS_SDK:-/root/theos/sdks/iPhoneOS16.5.sdk}
    fi
    test -d "$SDK" || { echo "Missing Apple SDK: $SDK" >&2; exit 2; }
    if ! clang -target arm64-apple-ios15.0 -isysroot "$SDK" -fobjc-arc -fblocks \
        -fsyntax-only -Wall -Wextra -Werror -I "$ROOT/storage" \
        "$ROOT/tests/hls-e2e-cli.m" "$ROOT/storage/PVXHLSLocalizer.m" \
        "$ROOT/storage/PVXHLSManifest.m" >"$WORK/compile.stdout" 2>"$WORK/compile.stderr"; then
        cat "$WORK/compile.stderr" >&2
        exit 1
    fi
    python3 -c 'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())' "$ROOT/tests/hls-e2e-media.py"
    echo 'PASS Apple SDK syntax ONLY; no Foundation execution or media runtime evidence.'
    [ "$MODE" = --syntax-only ] && exit 0
    echo 'SKIP runtime: macOS Foundation + ffmpeg lavfi/libx264 + ffprobe + openssl required.'
    exit 77
fi
if ! xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -I "$ROOT/storage" "$ROOT/tests/hls-e2e-cli.m" \
    "$ROOT/storage/PVXHLSLocalizer.m" "$ROOT/storage/PVXHLSManifest.m" \
    -framework Foundation -o "$WORK/hls e2e cli" \
    >"$WORK/compile.stdout" 2>"$WORK/compile.stderr"; then
    cat "$WORK/compile.stderr" >&2
    exit 1
fi
python3 "$ROOT/tests/hls-e2e-media.py" --cli "$WORK/hls e2e cli" --work-dir "$WORK"

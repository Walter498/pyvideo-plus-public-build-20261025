#!/bin/sh
set -eu
if [ "$(uname -s)" != Darwin ]; then
    echo 'SKIP: host tests require macOS Foundation/dyld (exit 77); no device execution' >&2
    exit 77
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/native-remux.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
CC=$(xcrun --find clang)
SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
export SDKROOT
"$CC" -fobjc-arc -Wall -Wextra -Werror -I"$ROOT/storage" "$ROOT/tests/native-agent-identity.m" -framework Foundation -o "$TMP/identity"
"$TMP/identity"
# All executables compile the production .m, not a replacement implementation.
"$CC" -fobjc-arc -fblocks -Wall -Wextra -Werror -DPVX_NATIVE_REMUX_TESTING=1 \
    -I"$ROOT/storage" "$ROOT/storage/PVXNativeRemux.m" "$ROOT/tests/native-remux-adapter.m" \
    -framework Foundation -framework AVFoundation -framework CoreMedia -Wl,-export_dynamic -o "$TMP/adapter"
"$TMP/adapter"
"$CC" -dynamiclib "$ROOT/tests/native-remux-foreign.c" -o "$TMP/foreign.dylib"
"$CC" -fobjc-arc -fblocks -Wall -Wextra -Werror -I"$ROOT/storage" \
    "$ROOT/storage/PVXNativeRemux.m" "$ROOT/tests/native-remux-resolver.m" \
    -framework Foundation -framework AVFoundation -framework CoreMedia -Wl,-export_dynamic -o "$TMP/resolver"
"$TMP/resolver" resolve
"$TMP/resolver" resolve "$TMP/foreign.dylib"
"$CC" -fobjc-arc -fblocks -Wall -Wextra -Werror -DEXPORT_MAIN_REMUX=1 -I"$ROOT/storage" \
    "$ROOT/storage/PVXNativeRemux.m" "$ROOT/tests/native-remux-resolver.m" \
    -framework Foundation -framework AVFoundation -framework CoreMedia -Wl,-export_dynamic -o "$TMP/production"
"$TMP/production" lock-contract

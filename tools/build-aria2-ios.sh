#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/third-party/aria2"
SRC="$OUT/src"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p "$OUT"
if [ ! -d "$SRC/.git" ]; then
  rm -rf "$SRC"
  git clone --depth 1 https://github.com/aria2/aria2.git "$SRC"
fi
cd "$SRC"
# aria2's no-TLS configure path in current release leaves two teardown calls
# outside ENABLE_SSL; remove those calls for the iOS no-TLS build.
python3 - <<'PY'
from pathlib import Path
p=Path('src/Platform.cc'); s=p.read_text(); s=s.replace('  SocketCore::setClientTLSContext(nullptr);\n','').replace('  SocketCore::setServerTLSContext(nullptr);\n',''); p.write_text(s)
PY
if [ ! -f configure ]; then autoreconf -f -i
fi
rm -f config.status
CC="xcrun --sdk iphoneos clang -arch arm64e -isysroot $SDK -miphoneos-version-min=15.0"
CXX="xcrun --sdk iphoneos clang++ -arch arm64e -isysroot $SDK -miphoneos-version-min=15.0 -stdlib=libc++"
CFLAGS="-Os -fvisibility=hidden"
CXXFLAGS="-Os -fvisibility=hidden -stdlib=libc++"
LDFLAGS="-arch arm64e -isysroot $SDK -miphoneos-version-min=15.0"
PKG_CONFIG=/usr/bin/false
export PKG_CONFIG
./configure --host=arm-apple-darwin --disable-werror --enable-static --disable-shared --disable-nls --disable-libxml2 --without-gnutls --without-openssl --without-appletls --without-wintls --disable-rpc --disable-websocket --disable-metalink --without-sqlite3 CC="$CC" CXX="$CXX" CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS -Wno-deprecated-declarations" LDFLAGS="$LDFLAGS"
make -j2
BIN="$(find . -type f -name aria2c -perm -111 | head -1)"
if [ -z "$BIN" ]; then echo 'aria2c binary not found' >&2; exit 1; fi
cp "$BIN" "$ROOT/build/PyVideoAria2c"
chmod 755 "$ROOT/build/PyVideoAria2c"
file "$ROOT/build/PyVideoAria2c"

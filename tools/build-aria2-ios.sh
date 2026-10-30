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
if [ ! -f configure ]; then autoreconf -f -i
fi
rm -f config.status
CC="xcrun --sdk iphoneos clang -arch arm64e -isysroot $SDK -miphoneos-version-min=15.0"
CXX="xcrun --sdk iphoneos clang++ -arch arm64e -isysroot $SDK -miphoneos-version-min=15.0 -stdlib=libc++"
CFLAGS="-Os -fvisibility=hidden"
CXXFLAGS="-Os -fvisibility=hidden -stdlib=libc++"
LDFLAGS="-arch arm64e -isysroot $SDK -miphoneos-version-min=15.0"
./configure --host=arm-apple-darwin --enable-static --disable-shared --disable-nls --disable-libxml2 --without-gnutls --without-openssl --without-appletls --without-wintls --without-libgcrypt --without-libcares --disable-rpc --disable-websocket --disable-metalink --without-sqlite3 CC="$CC" CXX="$CXX" CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS"
make -j2 src/aria2c
cp src/aria2c "$ROOT/build/PyVideoAria2c"
chmod 755 "$ROOT/build/PyVideoAria2c"
file "$ROOT/build/PyVideoAria2c"

#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/third-party/aria2"
SRC="$OUT/src"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p "$OUT"
ARIA2_REF="9e7273583f83e881e3ec067b523ba88724088d2f"
if [ ! -d "$SRC/.git" ]; then
  rm -rf "$SRC"
  git init "$SRC" >/dev/null
  git -C "$SRC" remote add origin https://github.com/aria2/aria2.git
  git -C "$SRC" fetch --depth 1 origin "$ARIA2_REF" >/dev/null
  git -C "$SRC" checkout --detach FETCH_HEAD >/dev/null
fi
cd "$SRC"
if [ "$(git rev-parse HEAD)" != "$ARIA2_REF" ]; then
  git fetch --depth 1 origin "$ARIA2_REF" >/dev/null
  git checkout --detach FETCH_HEAD >/dev/null
fi
git reset --hard "$ARIA2_REF" >/dev/null
git clean -fdx >/dev/null
GETTEXT_PREFIX="$(brew --prefix gettext 2>/dev/null || true)"
if [ -n "$GETTEXT_PREFIX" ]; then export PATH="$GETTEXT_PREFIX/bin:$GETTEXT_PREFIX/sbin:$PATH"; fi
command -v autoreconf >/dev/null
command -v autopoint >/dev/null || { echo 'gettext autopoint is required' >&2; exit 1; }
autoreconf -f -i
# aria2's no-TLS configure path in current release leaves two teardown calls
# outside ENABLE_SSL; remove those calls for the iOS no-TLS build.
python3 - <<'PY'
from pathlib import Path
p=Path('src/Platform.cc')
if not p.is_file(): raise SystemExit('aria2 source layout changed: missing src/Platform.cc')
s=p.read_text()
for needle in ('  SocketCore::setClientTLSContext(nullptr);\n','  SocketCore::setServerTLSContext(nullptr);\n'):
    if s.count(needle)!=1: raise SystemExit('aria2 no-TLS patch anchor changed: '+needle.strip())
    s=s.replace(needle,'')
p.write_text(s)
PY
if [ -f Makefile ]; then make distclean >/dev/null 2>&1 || true; fi
rm -f config.status
CC="xcrun --sdk iphoneos clang -arch arm64e -isysroot $SDK -miphoneos-version-min=15.0"
CXX="xcrun --sdk iphoneos clang++ -arch arm64e -isysroot $SDK -miphoneos-version-min=15.0 -stdlib=libc++"
CFLAGS="-Os -fvisibility=hidden"
CXXFLAGS="-Os -fvisibility=hidden -stdlib=libc++"
LDFLAGS="-arch arm64e -isysroot $SDK -miphoneos-version-min=15.0 -framework Security"
PKG_CONFIG=/usr/bin/false
export PKG_CONFIG
LIBS="-framework Security"
export LIBS
./configure --host=arm-apple-darwin --disable-werror --enable-static --disable-shared --disable-nls --disable-libxml2 --without-gnutls --without-openssl --without-appletls --without-wintls --without-libgcrypt --without-libcares --disable-rpc --disable-websocket --disable-metalink --without-sqlite3 CC="$CC" CXX="$CXX" CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS -Wno-deprecated-declarations" LDFLAGS="$LDFLAGS"
make -j2
BIN="$(python3 - "$SRC" <<'PY'
import os, subprocess, sys
root=sys.argv[1]
hits=[]
for directory, _, names in os.walk(root):
    if "aria2c" not in names:
        continue
    path=os.path.join(directory,"aria2c")
    if not os.access(path,os.X_OK):
        continue
    try:
        description=subprocess.check_output(["file","-b",path],text=True)
    except Exception:
        continue
    if "Mach-O" in description and "executable" in description:
        hits.append(path)
if not hits:
    raise SystemExit("aria2 Mach-O executable not found after link")
hits.sort(key=lambda p:("/.libs/" not in p, len(p)))
print(hits[0])
PY
)"
cp "$BIN" "$ROOT/build/PyVideoAria2c"
chmod 755 "$ROOT/build/PyVideoAria2c"
file "$ROOT/build/PyVideoAria2c" | tee "$OUT/aria2-file.txt"
case "$(file -b "$ROOT/build/PyVideoAria2c")" in
  *Mach-O*) : ;;
  *) echo 'aria2 output is not a Mach-O executable' >&2; exit 1;;
esac

#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/third-party/aria2"
SRC="$OUT/src"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p "$OUT"
ARIA2_REF="9e7273583f83e881e3ec067b523ba88724088d2f"
if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$SRC"
  git init "$SRC" >/dev/null
  git -C "$SRC" remote add origin https://github.com/aria2/aria2.git
fi
cd "$SRC"
git fetch --depth 1 origin "$ARIA2_REF" >/dev/null
git checkout --detach "$ARIA2_REF" >/dev/null
git reset --hard "$ARIA2_REF" >/dev/null
git clean -fdx >/dev/null
test "$(git rev-parse HEAD)" = "$ARIA2_REF"
# Distribute the exact upstream source, including licenses, plus our build recipe.
git archive --format=tar --prefix=aria2/ "$ARIA2_REF" | gzip -n > "$OUT/aria2-source.tar.gz"
for license in COPYING AUTHORS LICENSE.OpenSSL; do cp "$license" "$OUT/$license"; done
# Upstream has no COPYRIGHT file: retain its copyright-bearing source notice.
if [ -f COPYRIGHT ]; then cp COPYRIGHT "$OUT/COPYRIGHT"; else
  git show "$ARIA2_REF:src/main.cc" > "$OUT/COPYRIGHT"
fi
cp "$ROOT/tools/build-aria2-ios.sh" "$OUT/build-aria2-ios.sh"
printf '%s\n' 'aria2 1.37.0; GPL-2.0-or-later with upstream exceptions; see COPYING and source headers.' \
  "Source: https://github.com/aria2/aria2.git commit $ARIA2_REF" \
  "Retrieve: git clone https://github.com/aria2/aria2.git; git checkout $ARIA2_REF" \
  'Exact source: aria2-source.tar.gz. Build recipe: build-aria2-ios.sh. No source patches.' \
  'TLS backend: Apple SecureTransport (Security + CoreFoundation); no OpenSSL linked.' \
  'LICENSE.OpenSSL is retained as an upstream notice, not a linked-library claim.' > "$OUT/NOTICE"
GETTEXT_PREFIX="$(brew --prefix gettext 2>/dev/null || true)"
if [ -n "$GETTEXT_PREFIX" ]; then export PATH="$GETTEXT_PREFIX/bin:$GETTEXT_PREFIX/sbin:$PATH"; fi
command -v autoreconf >/dev/null
command -v autopoint >/dev/null || { echo 'gettext autopoint is required' >&2; exit 1; }
autoreconf -f -i
CC="xcrun --sdk iphoneos clang -arch arm64e -isysroot $SDK -miphoneos-version-min=15.0"
CXX="xcrun --sdk iphoneos clang++ -arch arm64e -isysroot $SDK -miphoneos-version-min=15.0 -stdlib=libc++"
CFLAGS="-Os -fvisibility=hidden -Wno-deprecated-declarations"
# iOS does not expose the macOS-only server DH-parameter setter. This
# upstream switch omits that server optimization; HTTPS client TLS is retained.
CXXFLAGS="$CFLAGS -stdlib=libc++ -DCIPHER_NO_DHPARAM"
LDFLAGS="-arch arm64e -isysroot $SDK -miphoneos-version-min=15.0 -framework Security -framework CoreFoundation"
export PKG_CONFIG=/usr/bin/false
export LIBS="-framework Security -framework CoreFoundation"
./configure --host=arm-apple-darwin --disable-werror --enable-static --disable-shared --disable-nls --disable-libxml2 --without-gnutls --without-openssl --with-appletls --without-wintls --without-libgcrypt --without-libcares --disable-rpc --disable-websocket --disable-metalink --without-sqlite3 CC="$CC" CXX="$CXX" CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS"
# Fail closed if configure silently omitted HTTPS support.
rg '^#define HAVE_APPLETLS 1$' config.h
rg '^#define ENABLE_SSL 1$' config.h
make -j2
BIN="$(python3 - "$SRC" <<'PY'
from pathlib import Path
import struct,sys
for p in (Path(sys.argv[1])/'src/.libs/aria2c', Path(sys.argv[1])/'src/aria2c'):
    if not p.is_file(): continue
    b=p.read_bytes()
    if len(b)<32: continue
    magic,cpu,sub,kind=struct.unpack_from('<IIII',b)
    if magic==0xfeedfacf and cpu==0x100000c and sub&0xffffff==2 and kind==2:
        print(p);break
else: raise SystemExit('no arm64e Mach-O executable in explicit aria2 output candidates')
PY
)"
cp "$BIN" "$ROOT/build/PyVideoAria2c"
chmod 755 "$ROOT/build/PyVideoAria2c"
file "$ROOT/build/PyVideoAria2c" | tee "$OUT/aria2-file.txt"
otool -L "$ROOT/build/PyVideoAria2c" | tee "$OUT/aria2-dependencies.txt"
python3 - "$OUT" "$ARIA2_REF" "$SDK" <<'PY'
from pathlib import Path
import hashlib,json,re,subprocess,sys
out=Path(sys.argv[1]);deps=(out/'aria2-dependencies.txt').read_text()
paths=[line.strip().split(' (',1)[0] for line in deps.splitlines()[1:] if line.strip()]
assert paths and all(p.startswith(('/usr/lib/','/System/Library/Frameworks/')) for p in paths),paths
assert not any(re.search(r'lib(ssl|crypto|gnutls|gcrypt)',p) for p in paths),paths
assert any('/Security.framework/' in p for p in paths),paths
assert any('/CoreFoundation.framework/' in p for p in paths),paths
files=['COPYING','COPYRIGHT','AUTHORS','LICENSE.OpenSSL','NOTICE','build-aria2-ios.sh','aria2-source.tar.gz','aria2-file.txt','aria2-dependencies.txt']
info={'engine':'aria2','version':'1.37.0','gitCommit':sys.argv[2],
      'sourceURL':'https://github.com/aria2/aria2.git','sourcePatches':[],
      'tlsBackend':'AppleTLS','compileDefines':['CIPHER_NO_DHPARAM'],'architecture':'arm64e','minimumIOS':'15.0',
      'sdk':sys.argv[3],'compiler':subprocess.check_output(['xcrun','clang','--version'],text=True),
      'dependencies':paths,'files':{n:hashlib.sha256((out/n).read_bytes()).hexdigest() for n in files}}
assert re.search(r'AC_INIT\(\[aria2\],\[1\.37\.0\]',(out/'src/configure.ac').read_text())
(out/'provenance.json').write_text(json.dumps(info,indent=2)+'\n')
PY

#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
# Execute the unchanged production POSIX commit function, not a reimplementation.
python3 - "$OUT" <<'PY'
import pathlib,sys
source=pathlib.Path('src/Collection.m').read_text()
start=source.index('static int PVXCollectionCommit(')
end=source.index('\nstatic BOOL PVXCollectionWrite',start)
production=source[start:end]
harness=r'''
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
'''+production+r'''
int main(int argc,char **argv){
 assert(argc==2);char dir[4096],file[4096],linkpath[4096],temporary[4096];
 assert(snprintf(dir,sizeof dir,"%s/queue",argv[1])>0);assert(!mkdir(dir,0700));
 const char bytes[]="readable request";
 assert(PVXCollectionCommit(dir,"task.plist",bytes,sizeof bytes)==0);
 assert(snprintf(file,sizeof file,"%s/task.plist",dir)>0);
 int fd=open(file,O_RDONLY);assert(fd>=0);char actual[sizeof bytes];
 assert(read(fd,actual,sizeof actual)==sizeof actual);assert(!memcmp(bytes,actual,sizeof bytes));close(fd);
 struct stat st;assert(!stat(file,&st));assert((st.st_mode&0777)==0600);
 assert(PVXCollectionCommit("/does-not-exist-pvx","task.plist",bytes,sizeof bytes)!=0);
 assert(snprintf(linkpath,sizeof linkpath,"%s/link",argv[1])>0);assert(!symlink(dir,linkpath));
 assert(PVXCollectionCommit(linkpath,"other.plist",bytes,sizeof bytes)!=0);
 assert(snprintf(temporary,sizeof temporary,"%s/.write-blocked.plist",dir)>0);
 fd=open(temporary,O_CREAT|O_WRONLY,0600);assert(fd>=0);close(fd);
 assert(PVXCollectionCommit(dir,"blocked.plist",bytes,sizeof bytes)!=0);
 puts("PASS production C commit runtime: zero success + readable exact bytes + 0600; missing directory, symlink and collision fail");
 return 0;
}
'''
pathlib.Path(sys.argv[1],'writer.c').write_text(harness)
PY
cc -Wall -Wextra -Werror "$OUT/writer.c" -o "$OUT/writer"
"$OUT/writer" "$OUT"
if [ "$(uname -s)" = Darwin ]; then
  xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation tests/magnet-normalizer.m -o "$OUT/normalizer"
  "$OUT/normalizer"
else
  SDK="${PVX_SDK:-/root/theos/sdks/iPhoneOS16.5.sdk}"
  for FILE in tests/magnet-normalizer.m tests/webkit-beta3-ui.m src/Collection.m src/DownloadsUI.m src/TaskSupport.m; do
    clang -target arm64e-apple-ios15.0 -isysroot "$SDK" -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations -I src -fsyntax-only "$FILE"
  done
  echo 'PASS strict iOS syntax. Foundation and WebKit producer/UI runtime still require macOS/simulator; NOT executed here.'
fi

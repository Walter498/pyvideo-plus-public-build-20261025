#define _GNU_SOURCE
#include <sys/types.h>
#include <unistd.h>
#include <errno.h>
#include <stddef.h>
#include <string.h>
static int mode;
static ssize_t inject_write(int fd, const void *p, size_t n) {
    if (mode == 1) { errno = ENOSPC; return -1; }
    if (mode == 2 && n > 7) n = 7;
    return write(fd, p, n);
}
static int inject_link(const char *a, const char *b) {
    if (mode && !strcmp(a, "source")) { errno=EXDEV; return -1; }
    return link(a,b);
}
#define link inject_link
#define write inject_write
#define PVX_STORAGE_IO_TEST 1
#include "../../storage/Storage.m"
#undef write
#include <assert.h>
#include <dirent.h>
static void put(const char *path, const char *s) {
    int fd = open(path, O_WRONLY|O_CREAT|O_TRUNC, 0600);
    assert(fd >= 0); assert(write(fd,s,strlen(s)) == (ssize_t)strlen(s)); close(fd);
}
int main(void) {
    char dir[] = "/tmp/pvx-storage-XXXXXX";
    assert(mkdtemp(dir)); assert(!chdir(dir));
    put("source", "actual complete media bytes");
    assert(PVXRetainDisk("source", "retained"));
    assert(PVXRetainDisk("source", "retained"));
    put("different", "conflicting media bytes!!!!");
    assert(!PVXRetainDisk("different", "retained"));
    assert(!symlink("source", "source-link"));
    assert(!PVXRetainDisk("source-link", "link-copy"));
    assert(!symlink("source", "dest-link"));
    assert(!PVXRetainDisk("source", "dest-link"));
    put("empty", ""); assert(!PVXRetainDisk("empty", "empty-copy"));
    assert(!PVXRetainDisk("missing", "missing-copy"));
    mode = 1; assert(!PVXRetainDisk("source", "full"));
    assert(access("full", F_OK)); assert(!access("source", F_OK));
    mode = 2; assert(PVXRetainDisk("source", "short-write"));
    mode = 0;
    DIR *d = opendir("."); assert(d); struct dirent *e;
    while ((e = readdir(d))) assert(strstr(e->d_name, ".XXXXXX") == NULL);
    closedir(d);
    const char *files[] = {"source","retained","different","source-link","dest-link","empty","short-write"};
    for (unsigned i=0;i<sizeof(files)/sizeof(files[0]);i++) assert(!unlink(files[i]));
    assert(!chdir("/")); assert(!rmdir(dir));
    puts("PASS disk: idempotence, collision, source/destination symlink, empty/missing, ENOSPC rollback, short writes");
}

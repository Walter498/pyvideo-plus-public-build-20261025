// Standalone PyVideoAgent 0.0.3 add-on. ARC, iOS 15+, Foundation only.
// The portable disk primitive is also compiled by tests/storage-beta2/io.c.
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

// No overwrite, no symlink traversal on leaf files, constant memory, durable
// staging then atomic link publication. Existing destinations must match bytes.
static int PVXSameFD(int a, int b) {
    struct stat sa, sb;
    if (fstat(a, &sa) || fstat(b, &sb) || !S_ISREG(sa.st_mode) ||
        !S_ISREG(sb.st_mode) || sa.st_size <= 0 || sa.st_size != sb.st_size) return 0;
    unsigned char x[65536], y[65536];
    if (lseek(a, 0, SEEK_SET) < 0 || lseek(b, 0, SEEK_SET) < 0) return 0;
    for (;;) {
        ssize_t n = read(a, x, sizeof(x));
        if (n < 0) { if (errno == EINTR) continue; return 0; }
        if (!n) return 1;
        size_t got = 0;
        while (got < (size_t)n) {
            ssize_t m = read(b, y + got, (size_t)n - got);
            if (m < 0 && errno == EINTR) continue;
            if (m <= 0) return 0;
            got += (size_t)m;
        }
        if (memcmp(x, y, (size_t)n)) return 0;
    }
}
static int PVXSyncParent(const char *path) {
    char *copy = strdup(path);
    if (!copy) return 0;
    char *slash = strrchr(copy, '/');
    if (slash) *slash = '\0';
    int fd = open(slash ? (*copy ? copy : "/") : ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    int ok = fd >= 0 && !fsync(fd);
    if (fd >= 0) close(fd);
    free(copy); return ok;
}
static int PVXRetainDisk(const char *source, const char *dest) {
    int in = open(source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (in < 0) return 0;
    struct stat before, after;
    if (fstat(in, &before) || !S_ISREG(before.st_mode) || before.st_size <= 0) {
        close(in); return 0;
    }
    int existing = open(dest, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (existing >= 0) {
        int equal = PVXSameFD(in, existing);
        close(existing); close(in); return equal;
    }
    // Agent final media is immutable in saving. Keep its inode without a second
    // full allocation; verify identity after publication before allowing cleanup.
    if (!link(source, dest)) {
        struct stat published;
        int ok = !lstat(dest, &published) && S_ISREG(published.st_mode) &&
            published.st_dev == before.st_dev && published.st_ino == before.st_ino;
        if (!ok) unlink(dest);
        if (ok) ok = PVXSyncParent(dest);
        close(in); return ok;
    }
    size_t len = strlen(dest) + 16;
    char *temp = malloc(len);
    if (!temp) { close(in); return 0; }
    snprintf(temp, len, "%s.XXXXXX", dest);
    int out = mkstemp(temp);
    int ok = out >= 0;
    unsigned char buffer[65536];
    off_t total = 0;
    while (ok) {
        ssize_t n = read(in, buffer, sizeof(buffer));
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { ok = 0; break; }
        if (!n) break;
        total += n;
        if (total > before.st_size) { ok = 0; break; }
        size_t sent = 0;
        while (sent < (size_t)n) {
            ssize_t m = write(out, buffer + sent, (size_t)n - sent);
            if (m < 0 && errno == EINTR) continue;
            if (m <= 0) { ok = 0; break; }
            sent += (size_t)m;
        }
    }
    if (ok) ok = !fstat(in, &after) && total == before.st_size &&
        before.st_size == after.st_size && before.st_mtime == after.st_mtime &&
        before.st_ctime == after.st_ctime && !fsync(out);
    if (out >= 0 && close(out)) ok = 0;
    if (ok && link(temp, dest)) {
        existing = open(dest, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        ok = existing >= 0 && PVXSameFD(in, existing);
        if (existing >= 0) close(existing);
    }
    unlink(temp); free(temp); close(in);
    return ok && PVXSyncParent(dest);
}

#ifndef PVX_STORAGE_IO_TEST
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <notify.h>
#include <dirent.h>
#include <math.h>

@interface NSObject (PVXStorageAgent)
- (BOOL)workerMode;
- (BOOL)reconciled;
- (BOOL)memoryReady;
- (NSMutableDictionary *)tasks;
- (NSMutableSet *)exports;
- (NSDictionary *)clearingRequest;
- (void)exportReady;
@end

static NSString *(*Root)(void);
static NSString *(*Media)(NSString *);
static BOOL (*Write)(id, NSString *, NSError **);
static void (*Notify)(NSString *);
static void (*Hook)(Class, SEL, IMP, IMP *);
static id (*OldTasks)(id, SEL);
static BOOL (*OldStart)(id, SEL);
static void (*OldExport)(id, SEL);
static void (*OldFinish)(id, SEL, id, BOOL, id, id);
static BOOL (*OldRemove)(id, SEL, id, NSError **);
static void (*OldDelete)(id, SEL, id);
static __weak id Worker;
static dispatch_source_t Timer;
static int NotificationToken;
// A getter view only. Never replaces Agent.tasks, never copies task records.
static _Thread_local void *ViewOwner;
static _Thread_local void *ViewTasks;
static _Thread_local void *ProtectedPaths;
static BOOL InExport;
static NSString *const Signal = @"com.crctdd.pyvideo.plus.storage";

static BOOL ValidID(id value) {
    return [value isKindOfClass:NSString.class] && [value length] == 36 &&
        [[NSUUID alloc] initWithUUIDString:value] != nil;
}
static NSString *Path(NSString *leaf) { return [Root() stringByAppendingPathComponent:leaf]; }
static BOOL SafeDirectory(NSString *path) {
    struct stat s;
    if (lstat(path.fileSystemRepresentation, &s)) {
        if (errno != ENOENT || mkdir(path.fileSystemRepresentation, 0700)) return NO;
        if (lstat(path.fileSystemRepresentation, &s)) return NO;
    }
    return S_ISDIR(s.st_mode) && !S_ISLNK(s.st_mode) && s.st_uid == geteuid();
}
static NSDictionary *ReadSmall(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat s;
    if (fstat(fd, &s) || !S_ISREG(s.st_mode) || s.st_size < 8 || s.st_size > 16384) {
        close(fd); return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)s.st_size];
    size_t count = 0;
    while (count < data.length) {
        ssize_t n = read(fd, (char *)data.mutableBytes + count, data.length - count);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); return nil; }
        count += (size_t)n;
    }
    close(fd);
    if (memcmp(data.bytes, "bplist00", 8)) return nil;
    id value = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
static BOOL Automatic(void) {
    NSString *p = Path(@"plus-preferences.plist");
    struct stat s;
    if (lstat(p.fileSystemRepresentation, &s) && errno == ENOENT) return YES;
    NSDictionary *prefs = ReadSmall(p);
    id value = prefs[@"autoSavePhotos"];
    if (prefs && !value) return YES;
    if (!value || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) return YES;
    return [value boolValue];
}
static id TasksView(id self, SEL cmd) {
    if (ViewOwner == (__bridge void *)self && ViewTasks) return (__bridge id)ViewTasks;
    return OldTasks(self, cmd);
}
static void Tick(void) {
    id agent = Worker;
    if (agent && [agent workerMode] && [agent reconciled]) [agent exportReady];
}
static BOOL Start(id self, SEL cmd) {
    BOOL result = OldStart(self, cmd);
    if (result && [self workerMode]) Worker = self;
    return result;
}

// Consume at most 32 requests and examine at most 256 directory entries per pass.
// Claim BEFORE Photos can start: crash => no automatic replay of authorization.
static NSString *Claim(id agent, NSDictionary *tasks) {
    NSString *dir = Path(@"plus-manual-photos");
    if (!SafeDirectory(dir)) return nil;
    DIR *d = opendir(dir.fileSystemRepresentation);
    if (!d) return nil;
    NSString *selected = nil;
    unsigned scanned = 0, processed = 0;
    struct dirent *entry;
    while (scanned++ < 256 && processed < 32 && (entry = readdir(d))) {
        NSString *name = [[NSString alloc] initWithUTF8String:entry->d_name];
        if (![name.pathExtension isEqual:@"plist"] || !ValidID(name.stringByDeletingPathExtension)) continue;
        processed++;
        NSString *p = [dir stringByAppendingPathComponent:name];
        NSDictionary *request = ReadSmall(p);
        NSString *uuid = request[@"id"];
        id created = request[@"created"];
        double age = [created isKindOfClass:NSNumber.class] ? NSDate.date.timeIntervalSince1970 - [created doubleValue] : INFINITY;
        NSDictionary *task = ValidID(uuid) ? tasks[uuid] : nil;
        NSString *state = task[@"state"];
        BOOL valid = [uuid isEqual:name.stringByDeletingPathExtension] && isfinite(age) && age >= -60 && age <= 86400;
        // Never replay saved, saving, uncertain, albumFailed or control transitions.
        if (!valid || !task || ![@[@"ready", @"queued", @"downloading", @"hls", @"remuxing", @"checking", @"converting"] containsObject:state]) {
            unlink(p.fileSystemRepresentation); continue;
        }
        if (![state isEqual:@"ready"] || [agent exports].count) continue;
        NSString *claim = [p stringByAppendingString:@".claimed"];
        // Atomic exclusive claim; unlike rename it cannot replace an old crash claim.
        if (link(p.fileSystemRepresentation, claim.fileSystemRepresentation)) continue;
        unlink(p.fileSystemRepresentation);
        selected = uuid;
        break;
    }
    closedir(d);
    return selected;
}
static void Export(id self, SEL cmd) {
    // Observed original entrypoints all run on main; refuse unknown concurrency.
    if (!NSThread.isMainThread || InExport || ![self workerMode]) return;
    Worker = self;
    if (![self reconciled] || ![self memoryReady] || [self clearingRequest] || [self exports].count) return;
    NSMutableDictionary *tasks = OldTasks(self, @selector(tasks));
    if (![tasks isKindOfClass:NSMutableDictionary.class]) return;
    BOOL automatic = Automatic();
    NSString *uuid = Claim(self, tasks);
    if (!automatic && !uuid) return;
    NSMutableDictionary *view = uuid ? [@{uuid: tasks[uuid]} mutableCopy] : tasks;
    InExport = YES;
    ViewOwner = (__bridge void *)self; ViewTasks = (__bridge void *)view;
    @try { OldExport(self, cmd); }
    @finally {
        ViewOwner = NULL; ViewTasks = NULL; InExport = NO;
        if (uuid) unlink(Path([NSString stringWithFormat:@"plus-manual-photos/%@.plist.claimed", uuid]).fileSystemRepresentation);
    }
}

static BOOL Remove(id self, SEL cmd, NSString *path, NSError **error) {
    NSSet *protected = (__bridge id)ProtectedPaths;
    if (protected && [protected containsObject:path]) return YES;
    return OldRemove(self, cmd, path, error);
}
static void Finish(id self, SEL cmd, id uuid, BOOL success, id error, id assetID) {
    NSDictionary *task = ValidID(uuid) ? OldTasks(self, @selector(tasks))[uuid] : nil;
    BOOL eligible = NSThread.isMainThread && success && ![self clearingRequest] &&
        [[self exports] containsObject:uuid] && [task[@"state"] isEqual:@"saving"];
    NSSet *protected = nil;
    NSString *retained = nil;
    if (eligible) {
        NSString *original = Media(uuid);
        NSString *compatible = [original stringByAppendingString:@".compatible.mp4"];
        retained = Path([NSString stringWithFormat:@"retained/%@.mp4", uuid]);
        // Prefer original; only use compatible when original is absent.
        struct stat st;
        BOOL originalExists = !lstat(original.fileSystemRepresentation, &st);
        NSString *source = originalExists ? original : compatible;
        BOOL copied = SafeDirectory(Path(@"retained")) && PVXRetainDisk(source.fileSystemRepresentation, retained.fileSystemRepresentation);
        if (copied) {
            NSMutableDictionary *metadata = [@{@"id":uuid, @"source":originalExists ? @"original" : @"compatible", @"created":@(NSDate.date.timeIntervalSince1970)} mutableCopy];
            if ([task[@"mediaBytes"] isKindOfClass:NSNumber.class]) metadata[@"mediaBytes"] = task[@"mediaBytes"];
            Write(metadata, [retained stringByAppendingString:@".plist"], NULL);
        } else {
            // Disk full/permission/collision: preserve both exact media leaves while
            // original commits the real Photos success and savedAt/assetID.
            protected = [NSSet setWithObjects:original, compatible, nil];
        }
    }
    void *previous = ProtectedPaths;
    ProtectedPaths = (__bridge void *)protected;
    @try { OldFinish(self, cmd, uuid, success, error, assetID); }
    @finally { ProtectedPaths = previous; }
    if (eligible) Notify(Signal);
}
static void Delete(id self, SEL cmd, id uuid) {
    OldDelete(self, cmd, uuid);
    NSDictionary *task = ValidID(uuid) ? OldTasks(self, @selector(tasks))[uuid] : nil;
    if ([task[@"state"] isEqual:@"deleted"]) {
        NSString *p = Path([NSString stringWithFormat:@"retained/%@.mp4", uuid]);
        unlink(p.fileSystemRepresentation);
        unlink([p stringByAppendingString:@".plist"].fileSystemRepresentation);
    }
}

static void (*OldClear)(id, SEL);
static void Clear(id self, SEL cmd) {
    BOOL wasClearing = [self clearingRequest] != nil;
    OldClear(self, cmd);
    if (!wasClearing || [self clearingRequest] || [OldTasks(self, @selector(tasks)) count]) return;
    // Original clear-download list excludes our directory. Only after its barrier
    // completed, delete UUID-named retained leaves; never follow directory links.
    NSString *dir = Path(@"retained");
    if (!SafeDirectory(dir)) return;
    DIR *d = opendir(dir.fileSystemRepresentation);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        NSString *name = [[NSString alloc] initWithUTF8String:e->d_name];
        NSString *uuid = [name hasSuffix:@".mp4.plist"] ? [name substringToIndex:name.length - 10] : name.stringByDeletingPathExtension;
        if (ValidID(uuid) && ([name hasSuffix:@".mp4"] || [name hasSuffix:@".mp4.plist"])) {
            unlink([dir stringByAppendingPathComponent:name].fileSystemRepresentation);
        }
    }
    closedir(d);
}
static BOOL Signature(Class cls, SEL sel, const char *ret, unsigned count, const char **args) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method || method_getNumberOfArguments(method) != count + 2) return NO;
    char *type = method_copyReturnType(method);
    BOOL ok = type && !strcmp(type, ret);
    free(type);
    for (unsigned i = 0; ok && i < count + 2; i++) {
        type = method_copyArgumentType(method, i);
        const char *expected = i == 0 ? "@" : i == 1 ? ":" : args[i - 2];
        ok = type && !strcmp(type, expected);
        free(type);
    }
    return ok;
}
static BOOL KnownImage(void) {
    const struct mach_header_64 *h = (const void *)_dyld_get_image_header(0);
    static const unsigned char uuid[16] = {0xf2,0xff,0xad,0x31,0xea,0x7d,0x31,0xf1,0xb1,0x89,0x24,0x12,0x52,0x29,0x74,0x19};
    if (!h || h->magic != MH_MAGIC_64 || h->filetype != MH_EXECUTE) return NO;
    const char *p = (const char *)(h + 1), *end = p + h->sizeofcmds;
    for (uint32_t i = 0; i < h->ncmds; i++) {
        if (p + sizeof(struct load_command) > end) return NO;
        const struct load_command *lc = (const void *)p;
        if (lc->cmdsize < sizeof(*lc) || lc->cmdsize > (size_t)(end - p)) return NO;
        if (lc->cmd == LC_UUID && lc->cmdsize == sizeof(struct uuid_command)) {
            return !memcmp(((const struct uuid_command *)lc)->uuid, uuid, 16);
        }
        p += lc->cmdsize;
    }
    return NO;
}
#ifndef PVX_STORAGE_MOCK
__attribute__((constructor))
static void Install(void) {
    @autoreleasepool {
        if (![NSProcessInfo.processInfo.arguments.firstObject.lastPathComponent isEqual:@"PyVideoAgent"] || !KnownImage()) return;
        Class c = NSClassFromString(@"PVAgent");
        const char *finishArgs[] = {"@", "B", "@", "@"};
        const char *one[] = {"@"};
        const char *removeArgs[] = {"@", "^@"};
        // All checks happen before any mutation. Unsupported ABI leaves original intact.
        if (!c || !Signature(c, @selector(startWorker), "B", 0, NULL) ||
            !Signature(c, @selector(exportReady), "v", 0, NULL) ||
            !Signature(c, @selector(tasks), "@", 0, NULL) ||
            !Signature(c, @selector(workerMode), "B", 0, NULL) ||
            !Signature(c, @selector(reconciled), "B", 0, NULL) ||
            !Signature(c, @selector(memoryReady), "B", 0, NULL) ||
            !Signature(c, @selector(exports), "@", 0, NULL) ||
            !Signature(c, @selector(clearingRequest), "@", 0, NULL) ||
            !Signature(c, NSSelectorFromString(@"finishExport:success:error:assetID:"), "v", 4, finishArgs) ||
            !Signature(c, NSSelectorFromString(@"finishDeletion:"), "v", 1, one) ||
            !Signature(c, NSSelectorFromString(@"finishClearAll"), "v", 0, NULL) ||
            !Signature(NSFileManager.class, @selector(removeItemAtPath:error:), "B", 2, removeArgs)) return;
        Hook = (void *)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
        if (!Hook) {
            NSString *base = [NSProcessInfo.processInfo.arguments.firstObject stringByDeletingLastPathComponent];
            for (NSString *leaf in @[@".jbroot/usr/lib/libsubstrate.dylib", @".jbroot/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"]) {
                void *handle = dlopen([[base stringByAppendingPathComponent:leaf] fileSystemRepresentation], RTLD_NOW | RTLD_GLOBAL);
                if (handle) Hook = (void *)dlsym(handle, "MSHookMessageEx");
                if (Hook) break;
            }
        }
        Root = (void *)dlsym(RTLD_DEFAULT, "PVStateDirectory");
        Media = (void *)dlsym(RTLD_DEFAULT, "PVMediaPath");
        Write = (void *)dlsym(RTLD_DEFAULT, "PVWrite");
        Notify = (void *)dlsym(RTLD_DEFAULT, "PVNotify");
        if (!Hook || !Root || !Media || !Write || !Notify) return;
        // Require the original C entrypoints to belong to the executable image.
        void *symbols[] = {(void *)Root, (void *)Media, (void *)Write, (void *)Notify};
        for (unsigned i = 0; i < sizeof(symbols)/sizeof(symbols[0]); i++) {
            Dl_info info;
            if (!dladdr(symbols[i], &info) || info.dli_fbase != (void *)_dyld_get_image_header(0)) return;
        }
        if (!SafeDirectory(Root())) return;
        Hook(c, @selector(tasks), (IMP)TasksView, (IMP *)&OldTasks);
        Hook(NSFileManager.class, @selector(removeItemAtPath:error:), (IMP)Remove, (IMP *)&OldRemove);
        Hook(c, NSSelectorFromString(@"finishExport:success:error:assetID:"), (IMP)Finish, (IMP *)&OldFinish);
        Hook(c, NSSelectorFromString(@"finishDeletion:"), (IMP)Delete, (IMP *)&OldDelete);
        Hook(c, NSSelectorFromString(@"finishClearAll"), (IMP)Clear, (IMP *)&OldClear);
        Hook(c, @selector(startWorker), (IMP)Start, (IMP *)&OldStart);
        Hook(c, @selector(exportReady), (IMP)Export, (IMP *)&OldExport);
        dispatch_async(dispatch_get_main_queue(), ^{
            notify_register_dispatch(Signal.UTF8String, &NotificationToken, dispatch_get_main_queue(), ^(int token) { (void)token; Tick(); });
            Timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(Timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
            dispatch_source_set_event_handler(Timer, ^{ @autoreleasepool { Tick(); } });
            dispatch_resume(Timer);
        });
    }
}
#endif // !PVX_STORAGE_MOCK
#endif // !PVX_STORAGE_IO_TEST

// Independent PyVideo image worker. ARC / iOS 15+. No original-worker symbols.
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <dispatch/dispatch.h>
#import <notify.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <math.h>
#include <errno.h>

static const uint64_t PVXMaxBytes = 100ULL * 1024 * 1024;
static const NSUInteger PVXMaxPlist = 2 * 1024 * 1024;
static const char *PVXChanged = "com.crctdd.pyvideo.plus.images.tasks";
static BOOL PVXString(id x, NSUInteger n) {
    return [x isKindOfClass:NSString.class] && [x length] <= n &&
        [x rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
static BOOL PVXNumber(id x) {
    return [x isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)x) != CFBooleanGetTypeID() && isfinite([x doubleValue]);
}
static BOOL PVXID(id x) {
    if (!PVXString(x, 36) || [x length] != 36) return NO;
    NSUUID *u = [[NSUUID alloc] initWithUUIDString:x];
    return u && [u.UUIDString caseInsensitiveCompare:x] == NSOrderedSame;
}
static NSURL *PVXURL(id x) {
    if (!PVXString(x, 16384) || ![x length]) return nil;
    NSURLComponents *c = [NSURLComponents componentsWithString:x];
    if (!c || ![@[@"http", @"https"] containsObject:c.scheme.lowercaseString] ||
        !c.host.length || c.user || c.password || (c.port && (c.port.integerValue < 1 || c.port.integerValue > 65535))) return nil;
    c.fragment = nil;
    return c.URL;
}
static BOOL PVXKeys(NSDictionary *d, NSArray *keys) {
    if (![d isKindOfClass:NSDictionary.class]) return NO;
    for (id k in d) if (![k isKindOfClass:NSString.class] || ![keys containsObject:k]) return NO;
    return YES;
}
static BOOL PVXDirectory(NSString *path, int *outFD) {
    if (mkdir(path.fileSystemRepresentation, 0700) && errno != EEXIST) return NO;
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat st;
    if (fd < 0) return NO;
    if (fstat(fd, &st) || !S_ISDIR(st.st_mode) || st.st_uid != geteuid() || fchmod(fd, 0700)) { close(fd); return NO; }
    *outFD = fd;
    return YES;
}
static NSDictionary *PVXRead(int dir, NSString *name) {
    int fd = openat(dir, name.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != geteuid() || st.st_nlink != 1 || st.st_size < 8 || (uint64_t)st.st_size > PVXMaxPlist || fchmod(fd,0600)) { close(fd); return nil; }
    NSMutableData *b = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
    NSUInteger pos = 0;
    while (pos < b.length) {
        ssize_t n = read(fd, (char *)b.mutableBytes + pos, b.length - pos);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); return nil; }
        pos += n;
    }
    char extra;
    ssize_t n = read(fd, &extra, 1);
    close(fd);
    if (n != 0 || memcmp(b.bytes, "bplist00", 8)) return nil;
    NSPropertyListFormat f;
    id p = [NSPropertyListSerialization propertyListWithData:b options:NSPropertyListImmutable format:&f error:nil];
    return f == NSPropertyListBinaryFormat_v1_0 && [p isKindOfClass:NSDictionary.class] ? p : nil;
}
static BOOL PVXWrite(int dir, NSString *name, NSDictionary *value) {
    NSData *b = [NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!b || b.length > PVXMaxPlist) return NO;
    NSString *tmp = [@".write-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int fd = openat(dir, tmp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return NO;
    NSUInteger pos = 0;
    BOOL ok = YES;
    while (pos < b.length) {
        ssize_t n = write(fd, (const char *)b.bytes + pos, b.length - pos);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { ok = NO; break; }
        pos += n;
    }
    if (fsync(fd)) ok = NO;
    if (close(fd)) ok = NO;
    if (ok && renameat(dir,tmp.fileSystemRepresentation,dir,name.fileSystemRepresentation)) ok = NO;
    if (ok && fsync(dir)) ok = NO;
    if (!ok) unlinkat(dir,tmp.fileSystemRepresentation,0);
    return ok;
}
static BOOL PVXRemove(int dir, NSString *name) {
    if (unlinkat(dir, name.fileSystemRepresentation, 0) && errno != ENOENT) return NO;
    return fsync(dir) == 0;
}
static NSString *PVXFile(NSString *uuid) { return [uuid stringByAppendingString:@".plist"]; }

// Validate before NSHTTPCookie sees any untrusted property classes. Do not accept
// archived objects, arbitrary headers, filesystem URLs, or cookies without path.
static NSDictionary *PVXRequest(NSDictionary *d, NSString *uuid) {
    if (!PVXKeys(d,@[@"id",@"kind",@"url",@"title",@"page",@"created",@"headers",@"cookies",@"width",@"height",@"protocol",@"mime",@"sourceKind"]) ||
        !PVXID(d[@"id"]) || ![d[@"id"] isEqual:uuid] || ![d[@"kind"] isEqual:@"image"] ||
        !PVXURL(d[@"url"]) || !PVXString(d[@"title"],1024) || !PVXString(d[@"page"],16384) ||
        ([d[@"page"] length] && !PVXURL(d[@"page"])) || !PVXNumber(d[@"created"]) || [d[@"created"] doubleValue] < 0 ||
        ([d[@"width"] isKindOfClass:NSNumber.class] && (!PVXNumber(d[@"width"]) || [d[@"width"] doubleValue] < 0 || [d[@"width"] doubleValue] > 100000)) ||
        ([d[@"height"] isKindOfClass:NSNumber.class] && (!PVXNumber(d[@"height"]) || [d[@"height"] doubleValue] < 0 || [d[@"height"] doubleValue] > 100000)) ||
        !PVXKeys(d[@"headers"],@[@"Referer",@"User-Agent"]) ||
        ![d[@"cookies"] isKindOfClass:NSArray.class] || [d[@"cookies"] count] > 512) return nil;
    for (NSString *key in d[@"headers"]) {
        if (!PVXString(d[@"headers"][key], [key isEqual:@"Referer"] ? 16384 : 1024)) return nil;
        if ([key isEqual:@"Referer"] && [d[@"headers"][key] length] && !PVXURL(d[@"headers"][key])) return nil;
    }
    NSMutableArray *cookies = [NSMutableArray array];
    NSArray *allowed = @[NSHTTPCookieName,NSHTTPCookieValue,NSHTTPCookieDomain,NSHTTPCookiePath,
        NSHTTPCookieSecure,NSHTTPCookieExpires,NSHTTPCookieDiscard,NSHTTPCookieVersion,
        NSHTTPCookieMaximumAge,NSHTTPCookieOriginURL,NSHTTPCookiePort,NSHTTPCookieComment,NSHTTPCookieCommentURL,
        NSHTTPCookieSameSitePolicy,@"HttpOnly",@"HTTPOnly",@"Created",@"SameSite",@"SetByJavaScript"];
    for (id item in d[@"cookies"]) {
        if (!PVXKeys(item,allowed)) return nil;
        NSDictionary *p = item;
        for (NSString *key in p) {
            id v = p[key];
            if ([key isEqual:NSHTTPCookieExpires]) { if (![v isKindOfClass:NSDate.class]) return nil; }
            else if (!PVXString(v,8192) && !PVXNumber(v) && ![v isKindOfClass:NSNumber.class]) return nil;
        }
        NSString *name = p[NSHTTPCookieName], *value = p[NSHTTPCookieValue];
        NSString *domain = p[NSHTTPCookieDomain], *path = p[NSHTTPCookiePath];
        if (!PVXString(name,256) || !name.length || !PVXString(value,8192) || !PVXString(domain,253) || !domain.length ||
            !PVXString(path,2048) || ![path hasPrefix:@"/"] || [domain containsString:@"/"] || [domain containsString:@":"] ||
            [domain containsString:@" "] || [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"()<>@,;:\\\"/[]?={} \t"]].location != NSNotFound ||
            [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@";\r\n"]].location != NSNotFound) return nil;
        // Max-Age must not reset its lifetime on process restart. Convert to a fixed
        // expiry anchored to the immutable producer timestamp, and discard Max-Age.
        NSMutableDictionary *normalized = [p mutableCopy];
        id age = p[NSHTTPCookieMaximumAge];
        if (age) {
            if (![age respondsToSelector:@selector(doubleValue)]) return nil;
            double seconds = [age doubleValue];
            if (!isfinite(seconds)) return nil;
            NSDate *expiry = [NSDate dateWithTimeIntervalSince1970:[d[@"created"] doubleValue] + MAX(0,seconds)];
            normalized[NSHTTPCookieExpires] = expiry;
            [normalized removeObjectForKey:NSHTTPCookieMaximumAge];
        }
        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:normalized];
        if (!cookie || !cookie.domain.length || !cookie.path.length) return nil;
        [cookies addObject:normalized];
    }
    NSMutableDictionary *r = [d mutableCopy]; r[@"cookies"] = cookies;
    return r;
}

@interface PVXImageJob : NSObject
@property NSMutableDictionary *state;
@property NSDictionary *request;
@property NSURLSessionDownloadTask *task;
@property NSString *mediaName;
@property NSString *uti;
@property NSString *failure;
@property NSUInteger redirects;
@property NSTimeInterval lastUpdate;
@property BOOL ready;
@end
@implementation PVXImageJob
@end

@interface PVXPhotoWorker : NSObject <NSURLSessionDownloadDelegate>
@property NSString *root;
@property int rootFD, inboxFD, tasksFD, mediaFD, photosFD, controlFD, lockFD;
@property NSMutableDictionary<NSString *,PVXImageJob *> *jobs;
@property NSMutableDictionary<NSNumber *,PVXImageJob *> *active;
@property NSURLSession *session;
@property dispatch_source_t timer, term, interrupt;
@property int notifyToken;
@property BOOL saving, stopping, diskFailed;
- (BOOL)start;
- (void)scan;
- (void)pump;
@end

@implementation PVXPhotoWorker
- (instancetype)init {
    if ((self = [super init])) { _rootFD = _inboxFD = _tasksFD = _mediaFD = _photosFD = _controlFD = _lockFD = -1; _notifyToken = -1;
        _jobs = [NSMutableDictionary dictionary]; _active = [NSMutableDictionary dictionary]; }
    return self;
}
- (BOOL)persist:(PVXImageJob *)j {
    j.state[@"updated"] = @(NSDate.date.timeIntervalSince1970);
    if (!PVXWrite(self.tasksFD,PVXFile(j.state[@"id"]),j.state)) {
        self.diskFailed = YES;
        // Stop scheduling when a durable task transition cannot be written.
        fprintf(stderr,"PyVideoPhotoWorker: task persistence failed\n");
        return NO;
    }
    notify_post(PVXChanged);
    return YES;
}
- (void)fail:(PVXImageJob *)j reason:(NSString *)reason {
    if ([@[@"deleting",@"deleted"] containsObject:j.state[@"state"]]) return;
    j.ready = NO; j.state[@"state"] = @"failed"; j.state[@"error"] = reason;
    [self persist:j];
}
- (NSArray<NSString *> *)names:(NSString *)subdir {
    return [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[self.root stringByAppendingPathComponent:subdir] error:nil] ?: @[];
}
- (BOOL)validSnapshot:(NSDictionary *)s uuid:(NSString *)uuid {
    if (!PVXKeys(s,@[@"id",@"url",@"title",@"page",@"created",@"updated",@"state",@"received",@"total",@"error",@"assetID",@"savedAt",@"uti",@"extension",@"manualPhotos"]) ||
        ![s[@"id"] isEqual:uuid] || !PVXString(s[@"state"],20) ||
        ![@[@"queued",@"downloading",@"ready",@"saving",@"saved",@"failed",@"uncertain",@"deleting",@"deleted"] containsObject:s[@"state"]] ||
        !PVXString(s[@"title"],1024) || !PVXString(s[@"url"],16384) || !PVXString(s[@"page"],16384) ||
        !PVXNumber(s[@"created"]) || !PVXNumber(s[@"updated"]) || !PVXNumber(s[@"received"]) || !PVXNumber(s[@"total"]) ||
        [s[@"received"] doubleValue] < 0 || [s[@"received"] doubleValue] > PVXMaxBytes || [s[@"total"] doubleValue] < -1 ||
        (s[@"error"] && !PVXString(s[@"error"],1024)) || (s[@"assetID"] && !PVXString(s[@"assetID"],1024)) ||
        (s[@"savedAt"] && !PVXNumber(s[@"savedAt"])) ||
        (s[@"uti"] && (!PVXString(s[@"uti"],256) || ![s[@"uti"] length])) ||
        (s[@"extension"] && (!PVXString(s[@"extension"],32) || ![s[@"extension"] length] ||
            [s[@"extension"] rangeOfCharacterFromSet:NSCharacterSet.alphanumericCharacterSet.invertedSet].location != NSNotFound)) ||
        (s[@"manualPhotos"] && (![s[@"manualPhotos"] isKindOfClass:NSNumber.class] ||
            CFGetTypeID((__bridge CFTypeRef)s[@"manualPhotos"]) != CFBooleanGetTypeID()))) return NO;
    return YES;
}
- (BOOL)start {
    if (geteuid() == 0) { fprintf(stderr,"PyVideoPhotoWorker: must run as mobile, not root\n"); return NO; }
    NSError *err = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:self.root withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&err]) return NO;
    if (!PVXDirectory(self.root,&_rootFD)) return NO;
    if (!PVXDirectory([self.root stringByAppendingPathComponent:@"image-inbox"],&_inboxFD) ||
        !PVXDirectory([self.root stringByAppendingPathComponent:@"image-tasks"],&_tasksFD) ||
        !PVXDirectory([self.root stringByAppendingPathComponent:@"image-media"],&_mediaFD) ||
        !PVXDirectory([self.root stringByAppendingPathComponent:@"plus-image-photos"],&_photosFD) ||
        !PVXDirectory([self.root stringByAppendingPathComponent:@"plus-image-control"],&_controlFD)) return NO;
    self.lockFD = openat(self.mediaFD,".worker.lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0600);
    struct stat lockStat;
    if (self.lockFD < 0 || fstat(self.lockFD,&lockStat) || !S_ISREG(lockStat.st_mode) || lockStat.st_uid != geteuid() || lockStat.st_nlink != 1 || fchmod(self.lockFD,0600) || flock(self.lockFD,LOCK_EX|LOCK_NB)) return NO;
    // A task file is a permanent UUID tombstone. Never reinterpret corrupt task
    // state as a new inbox item: it could be an already-committed Photos save.
    for (NSString *name in [self names:@"image-tasks"]) {
        NSString *uuid = name.stringByDeletingPathExtension;
        if (![name.pathExtension isEqual:@"plist"] || !PVXID(uuid)) continue;
        NSDictionary *s = PVXRead(self.tasksFD,name);
        PVXImageJob *j = [PVXImageJob new];
        if (![self validSnapshot:s uuid:uuid]) {
            j.state = [@{@"id":uuid,@"url":@"",@"title":@"",@"page":@"",@"created":@0,@"updated":@0,
                @"received":@0,@"total":@(-1),@"state":@"uncertain",@"error":@"任务记录损坏，请手动核对相册"} mutableCopy];
            self.jobs[uuid] = j;
            [self persist:j]; continue;
        }
        j.state = [s mutableCopy]; self.jobs[uuid] = j;
        NSString *state = s[@"state"];
        if ([state isEqual:@"deleting"] || [state isEqual:@"deleted"]) {
            [self finishDeletion:j];
        } else if ([state isEqual:@"saving"]) {
            j.state[@"state"] = @"uncertain";
            j.state[@"error"] = @"保存相册时中断，请先核对相册，避免重复保存";
            [self persist:j];
        } else if ([state isEqual:@"saved"]) {
            // Also finish cleanup after a crash between saved fsync and unlink.
            [self cleanup:j retainOriginal:YES];
        } else if ([state isEqual:@"ready"]) {
            // Credentials are optional once verified original bytes are durable.
            j.request = PVXRequest(PVXRead(self.inboxFD,name),uuid);
            if ([self restoreOriginal:j]) {
                j.ready = YES;
                if ([self persist:j]) [self cleanup:j retainOriginal:YES];
            } else [self fail:j reason:@"保留的图片不存在或已损坏"];
        } else if ([state isEqual:@"queued"] || [state isEqual:@"downloading"]) {
            j.request = PVXRequest(PVXRead(self.inboxFD,name),uuid);
            if (!j.request) [self fail:j reason:@"恢复下载凭据缺失或无效"];
            else { j.state[@"state"] = @"queued"; j.state[@"received"] = @0; j.state[@"total"] = @(-1); [self persist:j]; }
        }
    }
    // Atomic writer leftovers are never requests. Remove stale credential
    // temporaries as well as public snapshot temporaries after acquiring lock.
    for (NSString *name in [self names:@"image-tasks"])
        if ([name hasPrefix:@".write-"] && PVXID([name substringFromIndex:7])) PVXRemove(self.tasksFD,name);
    for (NSString *name in [self names:@"image-inbox"])
        if ([name hasPrefix:@".write-"] && PVXID([name substringFromIndex:7])) PVXRemove(self.inboxFD,name);
    NSURLSessionConfiguration *c = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    c.HTTPCookieStorage = nil; c.HTTPShouldSetCookies = NO;
    c.URLCache = nil; c.URLCredentialStorage = nil;
    c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    c.HTTPMaximumConnectionsPerHost = 2;
    c.timeoutIntervalForRequest = 60; c.timeoutIntervalForResource = 600;
    self.session = [NSURLSession sessionWithConfiguration:c delegate:self delegateQueue:NSOperationQueue.mainQueue];
    __weak typeof(self) weak = self;
    if (notify_register_dispatch("com.crctdd.pyvideo.plus.images.queue",&_notifyToken,dispatch_get_main_queue(),^(int t) { [weak scan]; }) != NOTIFY_STATUS_OK)
        fprintf(stderr,"PyVideoPhotoWorker: using queue polling\n");
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
    dispatch_source_set_timer(self.timer,dispatch_time(DISPATCH_TIME_NOW,0),2*NSEC_PER_SEC,200*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(self.timer,^{ [weak scan]; }); dispatch_resume(self.timer);
    signal(SIGTERM,SIG_IGN); signal(SIGINT,SIG_IGN);
    self.term = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGTERM,0,dispatch_get_main_queue());
    self.interrupt = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGINT,0,dispatch_get_main_queue());
    dispatch_source_set_event_handler(self.term,^{ [weak shutdown]; });
    dispatch_source_set_event_handler(self.interrupt,^{ [weak shutdown]; });
    dispatch_resume(self.term); dispatch_resume(self.interrupt);
    return YES;
}
- (void)scan {
    if (self.stopping || self.diskFailed) return;
    [self scanControls];
    for (PVXImageJob *j in self.jobs.allValues)
        if ([j.state[@"state"] isEqual:@"deleting"]) [self finishDeletion:j];
    for (NSString *name in [self names:@"image-inbox"]) {
        NSString *uuid = name.stringByDeletingPathExtension;
        if (![name.pathExtension isEqual:@"plist"] || !PVXID(uuid) || self.jobs[uuid]) continue;
        // Existing on-disk task also blocks re-import if directory contents were
        // modified while running. No use of producer-controlled relative paths.
        struct stat st;
        if (!fstatat(self.tasksFD,name.fileSystemRepresentation,&st,AT_SYMLINK_NOFOLLOW)) continue;
        NSDictionary *r = PVXRequest(PVXRead(self.inboxFD,name),uuid);
        // Claim by replacing the producer file with a normalized, fsynced private
        // request before publishing queued. The inbox doubles as credential store.
        if (r && !PVXWrite(self.inboxFD,name,r)) { self.diskFailed = YES; break; }
        PVXImageJob *j = [PVXImageJob new]; j.request = r;
        j.state = [@{@"id":uuid,@"url":r[@"url"] ?: @"",@"title":r[@"title"] ?: @"",@"page":r[@"page"] ?: @"",
            @"created":r[@"created"] ?: @(NSDate.date.timeIntervalSince1970),@"updated":@0,@"state":r ? @"queued" : @"failed",
            @"received":@0,@"total":@(-1)} mutableCopy];
        if (!r) j.state[@"error"] = @"图片下载请求无效";
        self.jobs[uuid] = j;
        if (![self persist:j]) break;
    }
    [self scanManualPhotos];
    [self pump];
}
- (void)cleanup:(PVXImageJob *)j retainOriginal:(BOOL)retain {
    NSString *uuid = j.state[@"id"];
    BOOL ok = PVXRemove(self.inboxFD,PVXFile(uuid));
    if (!retain) ok = PVXRemove(self.mediaFD,[uuid stringByAppendingString:@".original"]) && ok;
    j.request = nil;
    // Ready/saved snapshots no longer need signed source/page credentials.
    if (([j.state[@"state"] isEqual:@"saved"] || [j.state[@"state"] isEqual:@"ready"]) &&
        ([j.state[@"url"] length] || [j.state[@"page"] length])) {
        j.state[@"url"] = @""; j.state[@"page"] = @"";
        [self persist:j];
    }
    if (!ok) fprintf(stderr,"PyVideoPhotoWorker: saved-file cleanup incomplete\n");
}
// Beta3: preference files and legacy manual intent never authorize Photos.
- (BOOL)autoSavePhotos { return NO; }
- (BOOL)restoreOriginal:(PVXImageJob *)j {
    j.mediaName = [j.state[@"id"] stringByAppendingString:@".original"];
    int fd = openat(self.mediaFD,j.mediaName.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    struct stat st;
    BOOL valid = fd >= 0 && !fstat(fd,&st) && S_ISREG(st.st_mode) && st.st_uid == geteuid() &&
        st.st_nlink == 1 && st.st_size > 0 && (uint64_t)st.st_size <= PVXMaxBytes;
    if (fd >= 0) close(fd);
    NSURL *file = [NSURL fileURLWithPath:[[self.root stringByAppendingPathComponent:@"image-media"] stringByAppendingPathComponent:j.mediaName]];
    if (!valid || ![self verify:file job:j]) return NO;
    j.state[@"received"] = @(st.st_size); j.state[@"total"] = @(st.st_size);
    return YES;
}
- (void)scanManualPhotos {
    // Obsolete commands are consumed even if their task has not arrived yet.
    for (NSString *name in [self names:@"plus-image-photos"])
        if ([name.pathExtension isEqual:@"plist"] && PVXID(name.stringByDeletingPathExtension))
            PVXRemove(self.photosFD,name);
    for (PVXImageJob *j in self.jobs.allValues) {
        if (!j.state[@"manualPhotos"]) continue;
        [j.state removeObjectForKey:@"manualPhotos"];
        if (![self persist:j]) return;
    }
}
- (void)finishDeletion:(PVXImageJob *)j {
    // All callers and URLSession delegates run on main. Detach BEFORE cancel so
    // late progress/completion callbacks cannot find or mutate this task.
    NSURLSessionDownloadTask *task = j.task;
    if (task) [self.active removeObjectForKey:@(task.taskIdentifier)];
    j.task = nil; j.ready = NO; j.request = nil;
    [task cancel];
    NSString *uuid = j.state[@"id"];
    BOOL inbox = PVXRemove(self.inboxFD,PVXFile(uuid));
    BOOL media = PVXRemove(self.mediaFD,[uuid stringByAppendingString:@".original"]);
    BOOL manual = PVXRemove(self.photosFD,PVXFile(uuid));
    j.state[@"url"] = @""; j.state[@"page"] = @"";
    [j.state removeObjectForKey:@"manualPhotos"];
    j.state[@"state"] = inbox && media && manual ? @"deleted" : @"deleting";
    if (inbox && media && manual) [j.state removeObjectForKey:@"error"];
    else j.state[@"error"] = @"图片删除未完成，将重试清理";
    [self persist:j];
}
- (void)scanControls {
    for (NSString *name in [self names:@"plus-image-control"]) {
        NSString *requestID = name.stringByDeletingPathExtension;
        if (![name.pathExtension isEqual:@"plist"] || !PVXID(requestID)) continue;
        NSDictionary *c = PVXRead(self.controlFD,name);
        if (!PVXKeys(c,@[@"id",@"target",@"action",@"created"]) ||
            !PVXID(c[@"id"]) || ![c[@"id"] isEqual:requestID] || !PVXID(c[@"target"]) ||
            ![c[@"action"] isEqual:@"delete"] || !PVXNumber(c[@"created"]) || [c[@"created"] doubleValue] < 0) continue;
        NSString *uuid = c[@"target"];
        PVXImageJob *j = self.jobs[uuid];
        if (!j) {
            // Pending inbox deletion also gets a permanent UUID tombstone.
            j = [PVXImageJob new];
            j.state = [@{@"id":uuid,@"url":@"",@"title":@"",@"page":@"",@"created":c[@"created"],
                @"updated":@0,@"received":@0,@"total":@(-1)} mutableCopy];
            self.jobs[uuid] = j;
        }
        j.state[@"state"] = @"deleting";
        j.state[@"url"] = @""; j.state[@"page"] = @"";
        [j.state removeObjectForKey:@"manualPhotos"];
        if (![self persist:j]) return; // Never remove bytes before durable intent.
        [self finishDeletion:j];
        if (self.diskFailed) return;
        PVXRemove(self.controlFD,name); // deleting snapshot owns cleanup retries.
    }
}
- (NSMutableURLRequest *)requestFor:(PVXImageJob *)j target:(NSURL *)url {
    if (!PVXURL(url.absoluteString)) return nil;
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60];
    r.HTTPMethod = @"GET"; r.HTTPShouldHandleCookies = NO;
    [r setValue:@"image/*,application/octet-stream;q=0.5" forHTTPHeaderField:@"Accept"];
    NSString *ua = j.request[@"headers"][@"User-Agent"];
    if (ua.length) [r setValue:ua forHTTPHeaderField:@"User-Agent"];
    NSURL *ref = PVXURL(j.request[@"headers"][@"Referer"] ?: j.request[@"page"]);
    if (ref && !([ref.scheme.lowercaseString isEqual:@"https"] && [url.scheme.lowercaseString isEqual:@"http"])) {
        NSURLComponents *rc = [NSURLComponents componentsWithURL:ref resolvingAgainstBaseURL:NO];
        BOOL same = [ref.scheme.lowercaseString isEqual:url.scheme.lowercaseString] &&
            [ref.host.lowercaseString isEqual:url.host.lowercaseString] &&
            (ref.port.integerValue ?: ([ref.scheme.lowercaseString isEqual:@"https"] ? 443 : 80)) ==
            (url.port.integerValue ?: ([url.scheme.lowercaseString isEqual:@"https"] ? 443 : 80));
        rc.fragment = nil;
        if (!same) { rc.path = @"/"; rc.query = nil; }
        [r setValue:rc.URL.absoluteString forHTTPHeaderField:@"Referer"];
    }
    NSString *host = url.host.lowercaseString;
    NSString *targetPath = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].percentEncodedPath;
    if (!targetPath.length) targetPath = @"/";
    NSMutableArray<NSHTTPCookie *> *matches = [NSMutableArray array];
    for (NSDictionary *properties in j.request[@"cookies"]) {
        NSHTTPCookie *c = [NSHTTPCookie cookieWithProperties:properties];
        if (!c || (c.secure && ![url.scheme.lowercaseString isEqual:@"https"]) ||
            (c.expiresDate && [c.expiresDate timeIntervalSinceNow] <= 0)) continue;
        NSString *domain = [properties[NSHTTPCookieDomain] lowercaseString];
        BOOL subdomains = [domain hasPrefix:@"."];
        if (subdomains) domain = [domain substringFromIndex:1];
        if (!domain.length || [domain hasPrefix:@"."] ||
            !([host isEqual:domain] || (subdomains && [host hasSuffix:[@"." stringByAppendingString:domain]]))) continue;
        NSString *path = c.path;
        if (![targetPath hasPrefix:path] ||
            (targetPath.length > path.length && ![path hasSuffix:@"/"] && [targetPath characterAtIndex:path.length] != '/')) continue;
        if (c.portList.count && ![c.portList containsObject:url.port ?: @([url.scheme.lowercaseString isEqual:@"https"] ? 443 : 80)]) continue;
        [matches addObject:c];
    }
    [matches sortUsingComparator:^NSComparisonResult(NSHTTPCookie *a,NSHTTPCookie *b) {
        return a.path.length > b.path.length ? NSOrderedAscending : a.path.length < b.path.length ? NSOrderedDescending : NSOrderedSame;
    }];
    NSString *cookie = [NSHTTPCookie requestHeaderFieldsWithCookies:matches][@"Cookie"];
    if (cookie.length > 65536) return nil;
    if (cookie.length) [r setValue:cookie forHTTPHeaderField:@"Cookie"];
    return r;
}
- (NSArray<PVXImageJob *> *)orderedJobs {
    return [self.jobs.allValues sortedArrayUsingComparator:^NSComparisonResult(PVXImageJob *a, PVXImageJob *b) {
        NSComparisonResult v = [a.state[@"created"] compare:b.state[@"created"]];
        return v == NSOrderedSame ? [a.state[@"id"] compare:b.state[@"id"]] : v;
    }];
}
- (void)pump {
    if (self.stopping || self.diskFailed) return;
    NSArray *ordered = [self orderedJobs];
    // Ready originals remain exportable; no background Photos scheduling.
    for (PVXImageJob *j in ordered) {
        if (self.active.count >= 2 || self.diskFailed) break;
        if (![j.state[@"state"] isEqual:@"queued"] || !j.request) continue;
        NSMutableURLRequest *request = [self requestFor:j target:PVXURL(j.request[@"url"])];
        if (!request) { [self fail:j reason:@"无法构建安全的图片请求"]; continue; }
        j.mediaName = [j.state[@"id"] stringByAppendingString:@".original"];
        if (!PVXRemove(self.mediaFD,j.mediaName)) { [self fail:j reason:@"无法清理中断的下载"]; continue; }
        j.state[@"state"] = @"downloading"; j.state[@"received"] = @0; j.state[@"total"] = @(-1);
        [j.state removeObjectForKey:@"error"];
        if (![self persist:j]) break;
        j.task = [self.session downloadTaskWithRequest:request];
        self.active[@(j.task.taskIdentifier)] = j;
        [j.task resume];
    }
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)proposed completionHandler:(void (^)(NSURLRequest *))completionHandler {
    PVXImageJob *j = self.active[@(task.taskIdentifier)];
    NSURL *target = PVXURL(proposed.URL.absoluteString);
    NSURL *source = response.URL;
    if (!j || self.stopping || !target || ++j.redirects > 10 ||
        ([source.scheme.lowercaseString isEqual:@"https"] && ![target.scheme.lowercaseString isEqual:@"https"])) {
        if (j) j.failure = @"图片重定向不安全或次数过多";
        completionHandler(nil); [task cancel]; return;
    }
    // Never forward the framework's proposed Cookie/Authorization/Referer.
    NSMutableURLRequest *fresh = [self requestFor:j target:target];
    if (!fresh) { j.failure = @"图片重定向请求无效"; completionHandler(nil); [task cancel]; return; }
    completionHandler(fresh);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition,NSURLCredential *))completionHandler {
    // System TLS trust only; no credential stores, user prompts or permissive TLS.
    completionHandler([challenge.protectionSpace.authenticationMethod isEqual:NSURLAuthenticationMethodServerTrust] ? NSURLSessionAuthChallengePerformDefaultHandling : NSURLSessionAuthChallengeCancelAuthenticationChallenge,nil);
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)written totalBytesExpectedToWrite:(int64_t)expected {
    PVXImageJob *j = self.active[@(task.taskIdentifier)];
    if (!j || [@[@"deleting",@"deleted"] containsObject:j.state[@"state"]]) { [task cancel]; return; }
    if (written < 0 || (uint64_t)written > PVXMaxBytes || (expected > 0 && (uint64_t)expected > PVXMaxBytes)) {
        j.failure = @"图片超过 100 MiB 限制"; [task cancel]; return;
    }
    NSHTTPURLResponse *response = (id)task.response;
    if ([response isKindOfClass:NSHTTPURLResponse.class] && (response.statusCode < 200 || response.statusCode >= 300)) {
        j.failure = [NSString stringWithFormat:@"服务器返回 HTTP %ld",(long)response.statusCode]; [task cancel]; return;
    }
    j.state[@"received"] = @(written); j.state[@"total"] = @(expected < 0 ? -1 : expected);
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now - j.lastUpdate >= 0.5) { j.lastUpdate = now; if (![self persist:j]) [task cancel]; }
}
- (BOOL)verify:(NSURL *)url job:(PVXImageJob *)j {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url,(__bridge CFDictionaryRef)@{(id)kCGImageSourceShouldCache:@NO});
    if (!source) return NO;
    CFStringRef type = CGImageSourceGetType(source);
    UTType *uti = type ? [UTType typeWithIdentifier:(__bridge NSString *)type] : nil;
    size_t count = CGImageSourceGetCount(source);
    BOOL ok = uti && [uti conformsToType:UTTypeImage] && count > 0 && count <= 10000 && CGImageSourceGetStatus(source) == kCGImageStatusComplete;
    uint64_t allPixels = 0;
    for (size_t i = 0; ok && i < count; i++) {
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,i,(__bridge CFDictionaryRef)@{(id)kCGImageSourceShouldCache:@NO}));
        id width = properties[(id)kCGImagePropertyPixelWidth], height = properties[(id)kCGImagePropertyPixelHeight];
        if (!PVXNumber(width) || !PVXNumber(height)) { ok = NO; break; }
        double w = [width doubleValue], h = [height doubleValue];
        if (w < 1 || h < 1 || w > 32768 || h > 32768 || floor(w) != w || floor(h) != h || w*h > 268435456) { ok = NO; break; }
        allPixels += (uint64_t)w * (uint64_t)h;
        if (allPixels > 2000000000ULL) ok = NO;
    }
    if (ok) {
        j.uti = uti.identifier;
        j.state[@"uti"] = j.uti;
        j.state[@"extension"] = uti.preferredFilenameExtension ?: @"img";
    }
    CFRelease(source);
    return ok;
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
    PVXImageJob *j = self.active[@(task.taskIdentifier)];
    if (!j || self.stopping || j.failure || self.diskFailed ||
        [@[@"deleting",@"deleted"] containsObject:j.state[@"state"]]) return;
    NSHTTPURLResponse *r = (id)task.response;
    if (![r isKindOfClass:NSHTTPURLResponse.class] || r.statusCode < 200 || r.statusCode >= 300) { j.failure = @"图片服务器返回失败"; return; }
    NSString *mime = r.MIMEType.lowercaseString;
    if (mime.length && ![mime hasPrefix:@"image/"] && ![mime isEqual:@"application/octet-stream"] && ![mime isEqual:@"binary/octet-stream"]) {
        j.failure = @"服务器返回的内容不是图片"; return;
    }
    int fd = open(location.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    struct stat st;
    if (fd < 0) { j.failure = @"无法打开下载的图片"; return; }
    BOOL valid = !fstat(fd,&st) && S_ISREG(st.st_mode) && st.st_size > 0 && (uint64_t)st.st_size <= PVXMaxBytes;
    if (!valid || fchmod(fd,0600) || fsync(fd)) { close(fd); j.failure = @"图片为空、过大或无法访问"; return; }
    close(fd);
    if (![self verify:location job:j]) { j.failure = @"图片类型、元数据或尺寸验证失败"; return; }
    if (renameat(AT_FDCWD,location.fileSystemRepresentation,self.mediaFD,j.mediaName.fileSystemRepresentation) || fsync(self.mediaFD)) {
        j.failure = @"无法保留图片原文件"; return;
    }
    j.state[@"received"] = @(st.st_size); j.state[@"total"] = @(st.st_size);
    j.state[@"state"] = @"ready";
    // Release credentials immediately; ready queues hold records, not image data.
    j.state[@"url"] = @""; j.state[@"page"] = @"";
    j.ready = [self persist:j];
    if (j.ready) [self cleanup:j retainOriginal:YES];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    PVXImageJob *j = self.active[@(task.taskIdentifier)];
    if (!j) return;
    [self.active removeObjectForKey:@(task.taskIdentifier)]; j.task = nil;
    if ([@[@"deleting",@"deleted"] containsObject:j.state[@"state"]]) { [self pump]; return; }
    if (!j.ready) {
        if (self.stopping) { j.state[@"state"] = @"queued"; [self persist:j]; }
        else [self fail:j reason:j.failure ?: (error ? [NSString stringWithFormat:@"图片下载网络错误（%ld）",(long)error.code] : @"下载未生成有效图片")];
    }
    [self pump];
    if (self.stopping && !self.active.count && !self.saving) exit(0);
}
// Kept as an inert compatibility selector. Foreground sharing owns all exports.
- (void)save:(PVXImageJob *)j { (void)j; }
- (void)shutdown {
    if (self.stopping) return;
    self.stopping = YES;
    if (self.timer) dispatch_source_cancel(self.timer);
    if (self.notifyToken >= 0) { notify_cancel(self.notifyToken); self.notifyToken = -1; }
    for (PVXImageJob *j in self.active.allValues) [j.task cancel];
    // Never relabel an in-flight Photos commit as queued, even during SIGTERM.
    // SIGKILL at any point after the marker is recovered as uncertain.
    if (!self.active.count && !self.saving) exit(0);
}
@end

static NSString *PVXStateRoot(NSString *override) {
    if (override) {
        if (![override isAbsolutePath] || !PVXString(override,4096)) return nil;
        return override.stringByStandardizingPath;
    }
    NSString *canonical = @"/var/mobile/Library/Application Support/com.crctdd.pyvideo";
    // Mach-O imports spell this __Z6jbrootP8NSString; dlsym strips only the
    // Mach-O prefix underscore, NOT the C++ mangling underscore. PVRoot is a
    // tail-call to NSString *jbroot(NSString *), not char *jbroot(const char *).
    typedef NSString *(*PVXRootMapper)(NSString *);
    PVXRootMapper map = (PVXRootMapper)dlsym(RTLD_DEFAULT,"_Z6jbrootP8NSString");
    if (!map) {
        NSString *exe = NSProcessInfo.processInfo.arguments.firstObject;
        if (!exe.isAbsolutePath) exe = [[NSFileManager defaultManager].currentDirectoryPath stringByAppendingPathComponent:exe];
        NSString *lib = [[exe stringByDeletingLastPathComponent] stringByAppendingPathComponent:@".jbroot/usr/lib/libroothide.dylib"];
        void *handle = dlopen(lib.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
        if (handle) map = (PVXRootMapper)dlsym(handle,"_Z6jbrootP8NSString");
        // Handle intentionally retained for lifetime of function pointer.
    }
    if (!map) return nil; // Do not accidentally write a second, unmapped root.
    NSString *mapped = map(canonical);
    return [mapped isKindOfClass:NSString.class] && mapped.isAbsolutePath && mapped.length ? mapped : nil;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *root = nil;
        BOOL worker = NO;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i],"--worker")) worker = YES;
            else if (!strcmp(argv[i],"--root") && i+1 < argc && !root) root = [NSString stringWithUTF8String:argv[++i]];
            else { fprintf(stderr,"usage: PyVideoPhotoWorker --worker [--root /absolute/path]\n"); return 64; }
        }
        if (!worker) { fprintf(stderr,"PyVideoPhotoWorker: --worker required\n"); return 64; }
        PVXPhotoWorker *agent = [PVXPhotoWorker new]; agent.root = PVXStateRoot(root);
        if (!agent.root || ![agent start]) { fprintf(stderr,"PyVideoPhotoWorker: root mapping, ownership, lock or startup failed\n"); return 78; }
        // A main runloop is required by Foundation, Photos, dispatch and delegates.
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}

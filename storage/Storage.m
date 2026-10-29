// Standalone PyVideoAgent 0.0.3 add-on. ARC, iOS 15+, Foundation only.
// The portable disk primitive is also compiled by tests/storage-beta2/io.c.
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <limits.h>

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
#import <AVFoundation/AVFoundation.h>
#import "PVXHLSManifest.h"
#import "PVXNativeRemux.h"
#import "PVXHLSLocalizer.h"
#import "PVXLibavInput.h"
#import "PVXMediaValidator.h"
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
static BOOL (*OldStart)(id, SEL);
static void (*OldExport)(id, SEL);
static void (*OldFinish)(id, SEL, id, BOOL, id, id);
static BOOL (*OldRemove)(id, SEL, id, NSError **);
static void (*OldDelete)(id, SEL, id);
static void (*OldPump)(id, SEL);
static BOOL (*Persist)(id, SEL, id);
static NSMutableSet *RecoveryAttempted;
static NSMutableDictionary *RecoveryExports;
static void PVXBootLog(NSString *message){fprintf(stderr,"PyVideoStorage: %s\\n",message.UTF8String?:"(null)");fflush(stderr);}
static __weak id Worker;
static dispatch_source_t Timer;
static int NotificationToken;
static _Thread_local void *ProtectedPaths;
static NSString *const Signal = @"com.crctdd.pyvideo.plus.storage";

static BOOL ValidID(id value) {
    return [value isKindOfClass:NSString.class] && [value length] == 36 &&
        [[NSUUID alloc] initWithUUIDString:value] != nil;
}
static NSString *PVXFallbackRoot(void){NSString *home=NSHomeDirectory();return [home stringByAppendingPathComponent:@"Library/Application Support/com.crctdd.pyvideo"];}
static NSString *Path(NSString *leaf){NSString *root=Root?Root():nil;if(!root.length)root=PVXFallbackRoot();return [root stringByAppendingPathComponent:leaf];}
static BOOL SafeDirectory(NSString *path){struct stat s;if(lstat(path.fileSystemRepresentation,&s)){if(errno!=ENOENT||mkdir(path.fileSystemRepresentation,0700))return NO;if(lstat(path.fileSystemRepresentation,&s))return NO;}return S_ISDIR(s.st_mode)&&!S_ISLNK(s.st_mode)&&s.st_uid==geteuid();}
// One bounded serial writer owns rotation, sequence numbers and heartbeat dedup.
// Only immutable allowlisted scalar snapshots cross from the Agent's main queue.
static dispatch_queue_t PVXLogQueue;
static int PVXLogPending;
static void PVXLogSetup(void) {
    static dispatch_once_t once;dispatch_once(&once,^{
        PVXLogQueue=dispatch_queue_create("com.crctdd.pyvideo.live-log",DISPATCH_QUEUE_SERIAL);
    });
}
static NSDictionary *PVXLogFields(NSDictionary *source) {
    NSMutableDictionary *safe=[NSMutableDictionary dictionary];
    for(NSString *key in @[@"received",@"total",@"mediaBytes",@"segmentsDone",@"segmentsTotal",@"conversionProgress",@"concatAttempted",@"concatBytes",@"primaryNativeReturn",@"concatSegmentsDone",@"concatSegmentsTotal",@"nativeReturn",@"nativeResult",@"errorCode",@"nativeCalled",@"underlyingErrorCode",@"exportStatus",@"success",@"sharedLockVerified",@"videoWidth",@"videoHeight",@"videoDuration",@"duration",@"expectedDuration",@"requireAudio",@"hasAudio",@"videoFramesDecoded",@"audioSampleDecoded",@"audioDecodeSkipped",@"fileBytes",@"valid",@"fullDecode",@"avfoundationFallbackAttempted",@"avfoundationFallbackSuccess",@"taskPersisted",@"pvxRecoveryActive"]) {
        id value=source[key];if([value isKindOfClass:NSNumber.class]&&isfinite([value doubleValue]))safe[key]=value;
    }
    if(ValidID(source[@"id"]))safe[@"id"]=source[@"id"];
    NSCharacterSet *bad=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."].invertedSet;
    for(NSString *key in @[@"state",@"stage",@"event",@"reason",@"inputMode",@"primaryInputMode",@"validationScope",@"pvxRecoveryStage",@"pvxRecoveryVersion"]) {
        id value=source[key];if([value isKindOfClass:NSString.class]&&[value length]<=64&&[value rangeOfCharacterFromSet:bad].location==NSNotFound)safe[key]=value;
    }
    return safe;
}
static void PVXLogEvent(NSDictionary *snapshot,BOOL observe) {
    NSDictionary *safe=PVXLogFields(snapshot);PVXLogSetup();
    // Backpressure is bounded even if storage is slow/full. Next Tick retries.
    if(__sync_add_and_fetch(&PVXLogPending,1)>128){__sync_sub_and_fetch(&PVXLogPending,1);return;}
    dispatch_async(PVXLogQueue,^{@autoreleasepool {
        @try {
            static unsigned long long sequence;static NSMutableDictionary *seen,*beats;
            if(!seen){seen=[NSMutableDictionary dictionary];beats=[NSMutableDictionary dictionary];}
            NSString *uuid=safe[@"id"];NSTimeInterval now=NSDate.date.timeIntervalSince1970;
            BOOL changed=!uuid||![seen[uuid] isEqual:safe];
            BOOL active=[@[@"queued",@"downloading",@"hls",@"checking",@"preparing",@"remuxing",@"fallback",@"validating",@"waiting",@"converting",@"saving"] containsObject:safe[@"state"]]||[safe[@"pvxRecoveryActive"] boolValue];
            if(observe&&!changed&&(!active||now-[beats[uuid] doubleValue]<10))return;
            if(uuid){if(seen.count>=512&&!seen[uuid]){[seen removeAllObjects];[beats removeAllObjects];}seen[uuid]=safe;beats[uuid]=@(now);}
            NSMutableDictionary *row=[safe mutableCopy];row[@"timestamp"]=@(now);row[@"sequence"]=@(++sequence);row[@"pid"]=@(getpid());row[@"version"]=@"3.1.0";
            for(NSString *key in @[@"received",@"total",@"segmentsDone",@"segmentsTotal"])if(!row[key])row[key]=@0;
            row[@"heartbeat"]=@(!changed);if(!row[@"stage"])row[@"stage"]=row[@"pvxRecoveryStage"]?:row[@"state"]?:@"startup";
            NSData *json=[NSJSONSerialization dataWithJSONObject:row options:0 error:NULL];if(!json||json.length>8192)return;
            NSString *dir=Path(@"plus-diagnostics");if(!SafeDirectory(dir))return;
            NSString *path=[dir stringByAppendingPathComponent:@"events.jsonl"];
            struct stat st;if(!lstat(path.fileSystemRepresentation,&st)){
                if(!S_ISREG(st.st_mode)||st.st_uid!=geteuid())return;
                if(st.st_size+(off_t)json.length+1>512*1024){
                    NSString *old=[path stringByAppendingString:@".1"];
                    if(rename(path.fileSystemRepresentation,old.fileSystemRepresentation))return;
                }
            }
            int fd=open(path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC,0600);
            if(fd<0)return;
            if(!fstat(fd,&st)&&S_ISREG(st.st_mode)&&st.st_uid==geteuid()){
                fchmod(fd,0600);NSMutableData *line=[json mutableCopy];[line appendBytes:"\n" length:1];
                size_t done=0;while(done<line.length){ssize_t n=write(fd,(const char *)line.bytes+done,line.length-done);if(n<0&&errno==EINTR)continue;if(n<=0)break;done+=(size_t)n;}
                // Never leave a partial JSON record after ENOSPC/short write.
                if(done!=line.length)ftruncate(fd,st.st_size);
                fsync(fd);
            }close(fd);
        } @finally {__sync_sub_and_fetch(&PVXLogPending,1);}
    }});
}
static void PVXObserveTasks(id agent) {
    NSUInteger count=0;for(NSDictionary *task in [[agent tasks].allValues copy]){
        if(count++>=512)break;if([task isKindOfClass:NSDictionary.class])PVXLogEvent(task,YES);
    }
}
static void PVXBootMark(NSString *stage,NSDictionary *fields){
    PVXLogEvent(@{@"event":@"storage-bootstrap",@"stage":stage?:@"startup"},NO);
    PVXLogSetup();NSDictionary *copy=[fields copy];dispatch_async(PVXLogQueue,^{
        NSString *dir=Path(@"plus-diagnostics");if(!SafeDirectory(dir))return;
        NSMutableDictionary *payload=[PVXLogFields(copy) mutableCopy];payload[@"stage"]=stage;payload[@"updated"]=@(NSDate.date.timeIntervalSince1970);
        [payload writeToFile:[dir stringByAppendingPathComponent:@"storage-bootstrap.plist"] atomically:YES];
        [payload writeToFile:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"storage-%@.plist",stage]] atomically:YES];
    });
}
static void PVXDiagnostic(NSString *name,NSDictionary *value){
    if(!name.length)return;PVXLogEvent(value,NO);PVXLogSetup();NSDictionary *safe=PVXLogFields(value);
    dispatch_async(PVXLogQueue,^{NSString *dir=Path(@"plus-diagnostics");if(!SafeDirectory(dir))return;
        NSMutableDictionary *payload=[safe mutableCopy];payload[@"updated"]=@(NSDate.date.timeIntervalSince1970);
        NSString *file=[dir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"plist"]];
        if(Write)Write(payload,file,NULL);else[payload writeToFile:file atomically:YES];
    });
}
#include "PVXRecovery.inc"
static id PVXCurrentAgent(void){if(Worker)return Worker;Class app=NSClassFromString(@"UIApplication");SEL shared=NSSelectorFromString(@"sharedApplication");id application=app&&[app respondsToSelector:shared]?((id(*)(id,SEL))objc_msgSend)(app,shared):nil;id delegate=application&&[application respondsToSelector:@selector(delegate)]?((id(*)(id,SEL))objc_msgSend)(application,@selector(delegate)):nil;Class agentClass=NSClassFromString(@"PVAgent");if(delegate&&agentClass&&[delegate isKindOfClass:agentClass])Worker=delegate;return Worker;}
static void Tick(void) {
    id agent=PVXCurrentAgent();
    if(!agent)return;
    PVXObserveTasks(agent);
    for(NSString *uuid in [RecoveryExports.allKeys copy]) {
        PVXRecoveryJob *job=RecoveryExports[uuid];
        if(!PVXRecoveryCurrent(agent,job)) {
            job.cancelled=YES;[job.cancellation cancel];
            [RecoveryExports removeObjectForKey:uuid];
        }
    }
    if([agent respondsToSelector:@selector(exportReady)]&&[agent workerMode])[agent exportReady];
    PVXScanFailedHLS(agent);
}
static BOOL Start(id self, SEL cmd){Worker=self;BOOL result=OldStart?OldStart(self,cmd):NO;Worker=self;PVXBootMark(@"worker-started",@{@"result":@(result)});PVXObserveTasks(self);return result;}

// Beta3: foreground system sharing is the sole export entrypoint. Drain old
// requests without inspecting preferences or ever calling the original exporter.
static void DropLegacyPhotos(void) {
    NSString *dir = Path(@"plus-manual-photos");
    if (!SafeDirectory(dir)) return;
    int fd = open(dir.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return;
    DIR *d = fdopendir(fd);
    if (!d) { close(fd); return; }
    unsigned scanned = 0;
    struct dirent *entry;
    while (scanned++ < 256 && (entry = readdir(d))) {
        NSString *name = [[NSString alloc] initWithUTF8String:entry->d_name];
        NSString *leaf = [name hasSuffix:@".claimed"] ? name.stringByDeletingPathExtension : name;
        if ([leaf.pathExtension isEqual:@"plist"] && ValidID(leaf.stringByDeletingPathExtension))
            unlinkat(fd,name.fileSystemRepresentation,0);
    }
    fsync(fd);
    closedir(d);
}
static void Export(id self, SEL cmd) {
    (void)cmd;
    if (!NSThread.isMainThread || ![self workerMode]) return;
    Worker = self;
    DropLegacyPhotos();
    // OldExport is intentionally NEVER entered. Already active Beta2 saves are
    // still finalized by Finish, preserving original/compatible retention hooks.
}

static BOOL Remove(id self, SEL cmd, NSString *path, NSError **error) {
    NSSet *protected = (__bridge id)ProtectedPaths;
    if (protected && [protected containsObject:path]) return YES;
    return OldRemove(self, cmd, path, error);
}
static void Finish(id self, SEL cmd, id uuid, BOOL success, id error, id assetID) {
    NSDictionary *task = ValidID(uuid) ? [self tasks][uuid] : nil;
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
    NSDictionary *task = ValidID(uuid) ? [self tasks][uuid] : nil;
    if ([task[@"state"] isEqual:@"deleted"]) {
        NSString *p = Path([NSString stringWithFormat:@"retained/%@.mp4", uuid]);
        unlink(p.fileSystemRepresentation);
        unlink([p stringByAppendingString:@".plist"].fileSystemRepresentation);
    }
}

static NSInteger PVXConfiguredParallel(void){NSDictionary *v=[NSDictionary dictionaryWithContentsOfFile:Path(@"plus-preferences.plist")];NSInteger n=[v[@"parallelDownloads"] integerValue];return n>=1&&n<=15?n:15;}
static void PVXPumpWithConfiguredLimit(id self, SEL cmd){
    OldPump(self,cmd);
    if(![self workerMode]||![self reconciled]||![self memoryReady])return;
    NSMutableDictionary *tasks=[self tasks],*jobs=[self valueForKey:@"jobs"],*checks=[self valueForKey:@"checks"];if(!tasks||!jobs||!checks)return;
    NSInteger limit=PVXConfiguredParallel(),active=(NSInteger)jobs.count+(NSInteger)checks.count;if(active>=limit)return;
    for(NSDictionary *task in [tasks.allValues copy]){
        if(active>=limit||![task isKindOfClass:NSDictionary.class]||![task[@"state"] isEqual:@"queued"]||!ValidID(task[@"id"])||jobs[task[@"id"]]||checks[task[@"id"]])continue;
        NSString *hls=[task[@"hlsSourceURL"] isKindOfClass:NSString.class]?task[@"hlsSourceURL"]:nil;
        ((void(*)(id,SEL,id,id))objc_msgSend)(self,NSSelectorFromString(@"startTask:hlsURL:"),task,hls);active++;
    }
}
static void (*OldClear)(id, SEL);
static void Clear(id self, SEL cmd) {
    BOOL wasClearing = [self clearingRequest] != nil;
    OldClear(self, cmd);
    if (!wasClearing || [self clearingRequest] || [[self tasks] count]) return;
    NSString *dir = Path(@"retained");
    if (!SafeDirectory(dir)) return;
    DIR *d = opendir(dir.fileSystemRepresentation);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        NSString *name = [[NSString alloc] initWithUTF8String:e->d_name];
        NSString *uuid = [name hasSuffix:@".mp4.plist"] ? [name substringToIndex:name.length - 10] : name.stringByDeletingPathExtension;
        if (ValidID(uuid) && ([name hasSuffix:@".mp4"] || [name hasSuffix:@".mp4.plist"])) unlink([dir stringByAppendingPathComponent:name].fileSystemRepresentation);
    }
    closedir(d);
}

static BOOL PVXReplaceMethod(Class cls,SEL sel,IMP replacement,IMP *original){Method m=class_getInstanceMethod(cls,sel);if(!m)return NO;IMP old=method_getImplementation(m);if(original)*original=old;method_setImplementation(m,replacement);return YES;}
#ifndef PVX_STORAGE_MOCK
__attribute__((constructor))
static void Install(void) {
    @autoreleasepool {
        NSString *process=NSProcessInfo.processInfo.arguments.firstObject.lastPathComponent?:@"";
        PVXBootLog(@"constructor-enter");
        PVXBootMark(@"constructor",@{ @"process":process, @"pid":@(getpid()) });
        if (![process isEqualToString:@"PyVideoAgent"]) { PVXBootMark(@"process-rejected",@{ @"process":process }); return; }
        Class c=NSClassFromString(@"PVAgent");
        if(!c){PVXBootMark(@"agent-class-missing",@{});return;}
        RecoveryAttempted=[NSMutableSet set];RecoveryExports=[NSMutableDictionary dictionary];
        Persist=(void *)class_getMethodImplementation(c,@selector(persist:));
        Root=(void *)dlsym(RTLD_DEFAULT,"PVStateDirectory");
        Media=(void *)dlsym(RTLD_DEFAULT,"PVMediaPath");
        Write=(void *)dlsym(RTLD_DEFAULT,"PVWrite");
        Notify=(void *)dlsym(RTLD_DEFAULT,"PVNotify");
        PVXBootMark(@"symbols",@{ @"root":@(Root!=NULL), @"media":@(Media!=NULL), @"write":@(Write!=NULL), @"notify":@(Notify!=NULL) });
        if(!Root||!Media||!Notify){PVXBootLog(@"symbol-lookup-failed");PVXBootMark(@"symbol-lookup-failed",@{});return;}
        BOOL installed=YES;
        PVXReplaceMethod(AVAssetExportSession.class,@selector(exportAsynchronouslyWithCompletionHandler:),(IMP)PVXObserveAVExport,(IMP *)&PVXOldAVExport);
        installed&=PVXReplaceMethod(c,@selector(pump),(IMP)PVXPumpWithConfiguredLimit,(IMP *)&OldPump);
        installed&=PVXReplaceMethod(c,NSSelectorFromString(@"startTask:hlsURL:"),(IMP)PVXStartTaskRecovery,(IMP *)&OldStartTask);
        installed&=PVXReplaceMethod(c,NSSelectorFromString(@"control:target:"),(IMP)PVXControlRecovery,(IMP *)&OldControl);
        installed&=PVXReplaceMethod(NSFileManager.class,@selector(removeItemAtPath:error:),(IMP)Remove,(IMP *)&OldRemove);
        installed&=PVXReplaceMethod(c,NSSelectorFromString(@"finishExport:success:error:assetID:"),(IMP)Finish,(IMP *)&OldFinish);
        installed&=PVXReplaceMethod(c,NSSelectorFromString(@"finishDeletion:"),(IMP)Delete,(IMP *)&OldDelete);
        installed&=PVXReplaceMethod(c,NSSelectorFromString(@"finishClearAll"),(IMP)Clear,(IMP *)&OldClear);
        installed&=PVXReplaceMethod(c,@selector(startWorker),(IMP)Start,(IMP *)&OldStart);
        installed&=PVXReplaceMethod(c,@selector(exportReady),(IMP)Export,(IMP *)&OldExport);
        PVXBootMark(installed?@"method-replace-ok":@"method-replace-failed",@{ @"agent":NSStringFromClass(c)?:@"" });
        if(!installed){PVXBootLog(@"method-replace-failed");return;}
        if(!SafeDirectory(Root())){PVXBootMark(@"root-directory-failed",@{ @"root":Root()?:@"" });return;}
        PVXBootMark(@"installed",@{ @"root":Root()?:@"" });
        dispatch_async(dispatch_get_main_queue(),^{
            notify_register_dispatch(Signal.UTF8String,&NotificationToken,dispatch_get_main_queue(),^(int token){(void)token;Tick();});
            Timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
            dispatch_source_set_timer(Timer,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),2*NSEC_PER_SEC,NSEC_PER_SEC/2);
            dispatch_source_set_event_handler(Timer,^{@autoreleasepool{Tick();}});
            dispatch_resume(Timer);
            Tick();
        });
    }
}
#endif // !PVX_STORAGE_MOCK
#endif // !PVX_STORAGE_IO_TEST

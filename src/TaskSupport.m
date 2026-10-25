#if defined(PVX_FOUNDATION_TEST)
#import <Foundation/Foundation.h>
extern NSString *PVXStateRoot(void);
extern void PVXAlert(NSString *, NSString *);
#else
#import "PVXCommon.h"
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <notify.h>
#endif
#import <dlfcn.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdlib.h>
#import <objc/runtime.h>
BOOL PVXAutoSavePhotos(void);
void PVXSetAutoSavePhotos(BOOL enabled);

static BOOL PVXUUID(id x) {
    return [x isKindOfClass:NSString.class] && [x length] == 36 &&
        [[NSUUID alloc] initWithUUIDString:x] != nil;
}
static NSString *PVXSafeText(id v, NSUInteger limit) {
    if (![v isKindOfClass:NSString.class]) return @"";
    NSString *s = [v substringToIndex:MIN([v length], limit)];
    return [[s componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@" "];
}
// Never accept a path taken from a worker snapshot or request.
static NSString *PVXRoot(void) {
#if defined(PVX_TEST)
    const char *fixture = getenv("PVX_TEST_ROOT");
    if (fixture && *fixture) return [[NSString stringWithUTF8String:fixture] stringByResolvingSymlinksInPath];
#endif
    // Resolve and validate once per process, never once per task/file.
    static NSLock *lock;static dispatch_once_t once;static NSString *cached;
    dispatch_once(&once, ^{lock=[NSLock new];});
    [lock lock];NSString *root=cached;[lock unlock];if(root)return root;
    NSString *configured=PVXStateRoot();
    if(!configured.isAbsolutePath||[configured isEqual:@"/"])return nil;
    NSString *candidate=configured.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    BOOL directory=NO;
    if(![NSFileManager.defaultManager fileExistsAtPath:candidate isDirectory:&directory]||!directory)return nil;
    [lock lock];if(!cached)cached=[candidate copy];root=cached;[lock unlock];return root;
}
static char PVXResolvedFileKey;
static BOOL PVXContained(NSString *path, NSString *root) {
    if (!root.length || !path.length) return NO;
    NSString *prefix = [root stringByAppendingString:@"/"];
    return [path.stringByStandardizingPath hasPrefix:prefix] &&
        [path.stringByResolvingSymlinksInPath hasPrefix:prefix];
}
static NSString *PVXPath(NSString *relative) {
    NSString *root = PVXRoot();
    NSString *p = root ? [root stringByAppendingPathComponent:relative] : nil;
    return PVXContained(p, root) ? p : nil;
}
#if defined(PVX_WATCHDOG_TEST)
static NSUInteger PVXTestMainDiskReads;
static NSUInteger PVXTestBackgroundScans;
#endif
static NSDictionary *PVXPlist(NSString *path) {
#if defined(PVX_WATCHDOG_TEST)
    if(NSThread.isMainThread)PVXTestMainDiskReads++;
#endif
    if (!path.length || !PVXContained(path, PVXRoot())) return nil;
    int fd = open(path.fileSystemRepresentation, O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size < 8 || st.st_size > 2*1024*1024) { close(fd); return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t n = read(fd, (char *)data.mutableBytes + offset, data.length-offset);
        if (n <= 0) break;
        offset += (NSUInteger)n;
    }
    close(fd);
    if (offset != data.length) return nil;
    id value = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
static BOOL PVXAtomic(NSDictionary *value, NSString *path, NSError **error) {
    if (!path.length || !PVXContained(path, PVXRoot())) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error] || !PVXContained(path, PVXRoot())) return NO;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
    chmod(path.fileSystemRepresentation, 0600);
    return YES;
}
static NSString *PVXMetadataPath(NSString *uuid) {
    return PVXUUID(uuid) ? PVXPath([NSString stringWithFormat:@"plus-metadata/%@.plist", uuid]) : nil;
}
static BOOL PVXFolder(NSString *folder) {
    return folder.length <= 80 && ![folder isEqual:@"."] && ![folder isEqual:@".."] &&
        [folder rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\:"]].location == NSNotFound &&
        [folder rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
static NSDictionary *PVXMetadata(NSString *uuid) {
    NSDictionary *m = PVXPlist(PVXMetadataPath(uuid));
    return [m[@"id"] isEqual:uuid] ? m : @{};
}
static NSString *PVXOrganized(NSString *uuid, NSDictionary *metadata) {
    NSString *relative = metadata[@"organized"];
    if (![relative isKindOfClass:NSString.class]) return nil;
    NSArray *parts = relative.pathComponents;
    if (parts.count != 3 || ![parts[0] isEqual:@"files"] || !PVXFolder(parts[1]) || ![parts[1] length]) return nil;
    NSString *name = parts[2], *ext = name.pathExtension;
    if (![name.stringByDeletingPathExtension isEqual:uuid] || !ext.length || ext.length > 10 ||
        [ext rangeOfCharacterFromSet:NSCharacterSet.alphanumericCharacterSet.invertedSet].location != NSNotFound) return nil;
    return PVXPath(relative);
}
static BOOL PVXRegular(NSString *path) {
    struct stat st;
    return path.length && PVXContained(path, PVXRoot()) &&
        !lstat(path.fileSystemRepresentation, &st) && S_ISREG(st.st_mode) && st.st_size > 0;
}
static BOOL PVXComplete(NSDictionary *task) {
    // fileComplete from an arbitrary caller is not authority to read an active writer.
    return [@[@"ready", @"saved", @"albumFailed", @"uncertain", @"completed"] containsObject:task[@"state"]];
}
NSString *PVXTaskLocalPath(NSDictionary *task) {
    id prepared=objc_getAssociatedObject(task,&PVXResolvedFileKey);
    if(prepared)return [prepared isKindOfClass:NSString.class]?prepared:nil;
    NSString *uuid = task[@"id"];
    if (!PVXUUID(uuid) || !PVXComplete(task)) return nil;
    NSString *organized = PVXOrganized(uuid, PVXMetadata(uuid));
    if (PVXRegular(organized)) return organized;
    NSArray *paths = [task[@"kind"] isEqual:@"image"] ?
        @[[NSString stringWithFormat:@"image-media/%@.original", uuid]] :
        @[[NSString stringWithFormat:@"retained/%@.mp4", uuid],
          [NSString stringWithFormat:@"media/%@.mp4.compatible.mp4", uuid],
          [NSString stringWithFormat:@"media/%@.mp4", uuid]];
    for (NSString *relative in paths) { NSString *p = PVXPath(relative); if (PVXRegular(p)) return p; }
    return nil;
}
BOOL PVXTaskHasLocalFile(NSDictionary *task) { id prepared=objc_getAssociatedObject(task,&PVXResolvedFileKey);if(prepared)return [prepared isKindOfClass:NSString.class];if([task[@"hasLocalFile"] isKindOfClass:NSNumber.class])return [task[@"hasLocalFile"] boolValue];return PVXTaskLocalPath(task)!=nil; }
#if defined(PVX_FOUNDATION_TEST)
BOOL PVXAutoSavePhotos(void) { return NO; }
void PVXSetAutoSavePhotos(BOOL enabled) { (void)enabled; }
#endif

#if !defined(PVX_FOUNDATION_TEST)
static long long PVXBytes(id v) { return [v isKindOfClass:NSNumber.class] ? MAX(0, [v longLongValue]) : 0; }
#endif

static NSMutableDictionary *PVXPublicRow(NSDictionary *raw, NSString *kind) {
    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"id", @"state", @"title", @"error", @"uti", @"extension"]) {
        NSString *v = PVXSafeText(raw[key], [key isEqual:@"title"] ? 180 : 160);
        if (v.length) row[key] = v;
    }
    // Worker errors can embed signed URLs or credentials. Use a safe status explanation.
    NSString *diagnostic=PVXSafeText(raw[@"error"],320);[row removeObjectForKey:@"error"];
    if(diagnostic.length&&[diagnostic rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location==NSNotFound)row[@"error"]=diagnostic;
    else if ([raw[@"state"] isEqual:@"failed"]) row[@"error"] = @"下载失败，请重试或检查服务";
    for (NSString *key in @[@"created", @"updated", @"received", @"total", @"segmentsDone", @"segmentsTotal", @"conversionProgress"]) {
        if ([raw[key] isKindOfClass:NSNumber.class]) row[key] = raw[key];
    }
    row[@"kind"] = kind;
    if (!row[@"created"]) row[@"created"] = @0;
    if (!row[@"title"]) row[@"title"] = [kind isEqual:@"image"] ? @"图片" : @"视频";
    return row;
}
static NSArray<NSDictionary *> *PVXScanVideoTasks(void) {
#if defined(PVX_WATCHDOG_TEST)
    if(!NSThread.isMainThread)PVXTestBackgroundScans++;
#endif
    if (!PVXRoot()) return @[];
    NSMutableDictionary *rows = [NSMutableDictionary dictionary];
    for (NSString *sub in @[@"tasks", @"image-tasks", @"inbox", @"image-inbox"]) {
        NSString *dir = PVXPath(sub);
        BOOL inbox = [sub containsString:@"inbox"];
        NSString *kind = [sub hasPrefix:@"image-"] ? @"image" : @"video";
        for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
            NSString *uuid = file.stringByDeletingPathExtension;
            if (![file.pathExtension isEqual:@"plist"] || !PVXUUID(uuid)) continue;
            NSDictionary *raw = PVXPlist([dir stringByAppendingPathComponent:file]);
            if (![raw[@"id"] isEqual:uuid]) continue;
            // Video inbox also contains control messages; they are not download tasks.
            if (inbox && (raw[@"action"] || raw[@"target"])) continue;
            NSString *key = [kind stringByAppendingString:uuid];
            if (inbox && rows[key]) continue; // Includes deleted tombstones.
            NSMutableDictionary *row = PVXPublicRow(raw, kind);
            if (inbox) {
                // mtime is trusted for the acknowledgement deadline, not producer timestamps.
                struct stat st;
                NSTimeInterval created = !lstat([dir stringByAppendingPathComponent:file].fileSystemRepresentation, &st) ? st.st_mtime : 0;
                BOOL timeout = NSDate.date.timeIntervalSince1970 - created > 15;
                row[@"state"] = timeout ? @"serviceUnavailable" : @"submitted";
                row[@"created"] = @(created);
                row[@"error"] = timeout ? @"下载服务超过15秒未接收请求" : @"请求已排队，等待下载服务接收";
            }
            rows[key] = row;
        }
    }
    NSMutableArray *result = [NSMutableArray array];
    for (NSMutableDictionary *row in rows.allValues) {
        if ([row[@"state"] isEqual:@"deleted"]) continue;
        NSDictionary *m = PVXMetadata(row[@"id"]);
        for (NSString *field in @[@"title", @"tags", @"folder"]) {
            if ([m[field] isKindOfClass:NSString.class]) row[field] = PVXSafeText(m[field], 180);
        }
        NSString *localPath=PVXTaskLocalPath(row);BOOL local=localPath!=nil;
        objc_setAssociatedObject(row,&PVXResolvedFileKey,localPath?:NSNull.null,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        row[@"hasLocalFile"] = @(local);
        if(localPath){struct stat st;if(!lstat(localPath.fileSystemRepresentation,&st))row[@"localBytes"]=@(MAX(0,st.st_size));}
        if (!local) row[@"exportUnavailableReason"] = PVXComplete(row) ? @"本地原文件已不存在，请重新下载" : @"下载完成后才能导出";
        [result addObject:row];
    }
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult r = [b[@"created"] compare:a[@"created"]];
        return r == NSOrderedSame ? [a[@"id"] compare:b[@"id"]] : r;
    }];
    return result;
}
// All UI refreshes share one non-main scanner. Concurrent requests coalesce.
static dispatch_queue_t PVXSnapshotQueue;
static NSLock *PVXSnapshotLock;
static NSMutableArray *PVXSnapshotCallbacks;
static NSArray *PVXSnapshotRows;
static NSDictionary *PVXSnapshotStorage;
static BOOL PVXSnapshotRunning;
static void PVXSnapshotSetup(void){static dispatch_once_t once;dispatch_once(&once,^{PVXSnapshotQueue=dispatch_queue_create("com.crctdd.pyvideo.plus.task-snapshot",DISPATCH_QUEUE_SERIAL);PVXSnapshotLock=[NSLock new];PVXSnapshotRows=@[];PVXSnapshotStorage=@{};PVXSnapshotCallbacks=[NSMutableArray array];});}
NSDictionary *PVXStorageSummary(void);
void PVXRequestTaskSnapshot(void(^completion)(NSArray<NSDictionary*>*,NSDictionary*)) {
 PVXSnapshotSetup();[PVXSnapshotLock lock];if(completion)[PVXSnapshotCallbacks addObject:[completion copy]];if(PVXSnapshotRunning){[PVXSnapshotLock unlock];return;}PVXSnapshotRunning=YES;[PVXSnapshotLock unlock];
 dispatch_async(PVXSnapshotQueue,^{@autoreleasepool{
  NSArray *rows=PVXScanVideoTasks();static NSTimeInterval lastStorage;NSTimeInterval now=NSDate.date.timeIntervalSince1970;NSDictionary *cached=PVXSnapshotStorage?:@{};BOOL refreshStorage=!cached.count||now-lastStorage>=15;
  [PVXSnapshotLock lock];PVXSnapshotRows=rows;NSArray *first=[PVXSnapshotCallbacks copy];[PVXSnapshotCallbacks removeAllObjects];[PVXSnapshotLock unlock];
  dispatch_async(dispatch_get_main_queue(),^{for(void(^block)(NSArray*,NSDictionary*) in first)block(rows,cached);});
  if(refreshStorage){NSDictionary *storage=PVXStorageSummary();lastStorage=NSDate.date.timeIntervalSince1970;[PVXSnapshotLock lock];PVXSnapshotStorage=storage;NSArray *second=[PVXSnapshotCallbacks copy];[PVXSnapshotCallbacks removeAllObjects];PVXSnapshotRunning=NO;[PVXSnapshotLock unlock];dispatch_async(dispatch_get_main_queue(),^{for(void(^block)(NSArray*,NSDictionary*) in second)block(rows,storage);});}
  else{[PVXSnapshotLock lock];PVXSnapshotRunning=NO;NSArray *late=[PVXSnapshotCallbacks copy];[PVXSnapshotCallbacks removeAllObjects];[PVXSnapshotLock unlock];dispatch_async(dispatch_get_main_queue(),^{for(void(^block)(NSArray*,NSDictionary*) in late)block(rows,cached);});}
 }});
}
NSArray<NSDictionary*> *PVXReadVideoTasks(void) {
#if defined(PVX_TEST)
    // Fixture assertions can request a synchronous read. The actual production
    // UIKit manager always calls the asynchronous coalescing API even in tests.
    return PVXScanVideoTasks();
#else
    if(!NSThread.isMainThread)return PVXScanVideoTasks();
    PVXSnapshotSetup();[PVXSnapshotLock lock];NSArray *rows=PVXSnapshotRows;[PVXSnapshotLock unlock];PVXRequestTaskSnapshot(nil);return rows;
#endif
}
static NSString *PVXExtension(NSDictionary *task, NSString *path) {
    if (![task[@"kind"] isEqual:@"image"]) return @"mp4";
#if !defined(PVX_FOUNDATION_TEST)
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    NSString *ext = nil;
    if (source) {
        CFStringRef type = CGImageSourceGetType(source);
        if (type) ext = [UTType typeWithIdentifier:(__bridge NSString *)type].preferredFilenameExtension;
        CFRelease(source);
    }
    return ext;
#else
    (void)path;
    return @"png";
#endif
}
void PVXUpdateTaskMetadata(NSArray<NSDictionary *> *tasks, NSString *field, NSString *value) {
    if (![@[@"title", @"tags", @"folder"] containsObject:field] || ![value isKindOfClass:NSString.class]) return;
    if (([field isEqual:@"folder"] && (!PVXFolder(value) || !value.length)) || value.length > 180) {
        PVXAlert(@"无法更新", @"分组名不能包含路径，文字长度不能超过180字"); return;
    }
    for (NSDictionary *task in tasks) {
        NSString *uuid = task[@"id"];
        if (!PVXUUID(uuid)) continue;
        NSMutableDictionary *metadata = [PVXMetadata(uuid) mutableCopy];
        NSString *previous = PVXOrganized(uuid, metadata);
        NSString *createdPath = nil;
        if ([field isEqual:@"folder"]) {
            NSString *source = PVXTaskLocalPath(task), *ext = source ? PVXExtension(task, source) : nil;
            if (!source || !ext.length) { PVXAlert(@"无法移动", @"需要已完成且格式可识别的本地文件"); continue; }
            NSString *relative = [NSString stringWithFormat:@"files/%@/%@.%@", value, uuid, ext];
            NSString *destination = PVXPath(relative);
            NSError *error = nil;
            BOOL ok = destination && [NSFileManager.defaultManager createDirectoryAtPath:destination.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error] && PVXContained(destination, PVXRoot());
            if (ok && ![source isEqual:destination]) {
                // Copies isolate worker ownership/link-count checks; source is retained until worker deletion.
                ok = [NSFileManager.defaultManager copyItemAtPath:source toPath:destination error:&error];
                if (ok) createdPath = destination;
            }
            if (!ok || !PVXRegular(destination)) { PVXAlert(@"移动失败", error.localizedDescription ?: @"无法建立分组文件"); continue; }
            metadata[@"organized"] = relative;
        }
        metadata[@"id"] = uuid;
        metadata[field] = PVXSafeText(value, 180);
        NSError *error = nil;
        if (!PVXAtomic(metadata, PVXMetadataPath(uuid), &error)) {
            if (createdPath) [NSFileManager.defaultManager removeItemAtPath:createdPath error:nil];
            PVXAlert(@"未保存修改", error.localizedDescription ?: @"无法保存元数据");
        } else if (createdPath && previous && ![previous isEqual:createdPath]) {
            [NSFileManager.defaultManager removeItemAtPath:previous error:nil];
        }
    }
}

static BOOL PVXQueueControl(NSDictionary *task, NSString *action, NSError **error) {
    if (!PVXUUID(task[@"id"]) || ![@[@"delete", @"pause", @"resume", @"retry"] containsObject:action]) return NO;
    if ([task[@"kind"] isEqual:@"image"]) {
        if (![action isEqual:@"delete"]) return NO;
        NSString *request = NSUUID.UUID.UUIDString;
        BOOL ok = PVXAtomic(@{@"id":request, @"target":task[@"id"], @"action":@"delete", @"created":@(NSDate.date.timeIntervalSince1970)}, PVXPath([NSString stringWithFormat:@"plus-image-control/%@.plist", request]), error);
#if !defined(PVX_FOUNDATION_TEST)
        if (ok) notify_post("com.crctdd.pyvideo.plus.images.queue");
#endif
        return ok;
    }
    typedef BOOL (*Control)(NSString *, NSString *, NSError **);
    static Control fn; static dispatch_once_t once;
    dispatch_once(&once, ^{ fn=(Control)dlsym(RTLD_DEFAULT, "PVEnqueueControl"); });
    return fn ? fn(task[@"id"], action, error) : NO;
}
void PVXDeleteTasks(NSArray<NSDictionary *> *tasks, void (^completion)(NSString *)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSMutableArray *waiting=[NSMutableArray array],*failures=[NSMutableArray array];
        for(NSDictionary *task in tasks){NSError *error=nil;if(PVXQueueControl(task,@"delete",&error))[waiting addObject:task];else[failures addObject:@"删除请求未入队，下载服务不可用或写入失败"];}
        NSTimeInterval deadline=NSDate.date.timeIntervalSince1970+12;
        while(waiting.count && NSDate.date.timeIntervalSince1970<deadline){
            for(NSDictionary *task in [waiting copy]){
                NSString *sub=[task[@"kind"] isEqual:@"image"]?@"image-tasks":@"tasks";
                NSDictionary *state=PVXPlist(PVXPath([NSString stringWithFormat:@"%@/%@.plist",sub,task[@"id"]]));
                if(![state[@"state"] isEqual:@"deleted"])continue;
                NSString *uuid=task[@"id"],*organized=PVXOrganized(uuid,PVXMetadata(uuid));NSError *err=nil;
                if(organized&&![NSFileManager.defaultManager removeItemAtPath:organized error:&err]&&err.code!=NSFileNoSuchFileError)[failures addObject:@"任务已删除，但分组副本清理失败"];
                NSString *metadata=PVXMetadataPath(uuid);if(metadata)[NSFileManager.defaultManager removeItemAtPath:metadata error:nil];[waiting removeObject:task];
            }
            if(waiting.count)usleep(200000);
        }
        if(waiting.count)[failures addObject:@"后台尚未确认删除；文件和分组信息保持不变，请检查任务状态"];
        NSString *message=failures.count?[failures componentsJoinedByString:@"\n"]:nil;
        dispatch_async(dispatch_get_main_queue(),^{if(completion)completion(message);});
    });
}
static NSDictionary *PVXFindLiveTask(NSString *uuid){for(NSDictionary *row in PVXReadVideoTasks())if([row[@"id"] isEqual:uuid])return row;return nil;}
static void PVXQueuePauseAtSegmentBoundary(NSDictionary *task){
    NSString *uuid=PVXSafeText(task[@"id"],64);NSNumber *initial=task[@"segmentsDone"];
    if(!initial){NSError *error=nil;if(!PVXQueueControl(task,@"pause",&error))dispatch_async(dispatch_get_main_queue(),^{PVXAlert(@"任务操作失败",@"暂停请求未入队");});return;}
    NSTimeInterval deadline=NSDate.date.timeIntervalSince1970+20;
    while(NSDate.date.timeIntervalSince1970<deadline){NSDictionary *live=PVXFindLiveTask(uuid);NSString *state=PVXSafeText(live[@"state"],32);NSNumber *done=live[@"segmentsDone"];if(!live||![@[@"queued",@"downloading",@"hls",@"remuxing",@"converting",@"checking"] containsObject:state]||[done longLongValue]>[initial longLongValue])break;usleep(100000);}
    NSError *error=nil;if(!PVXQueueControl(task,@"pause",&error))dispatch_async(dispatch_get_main_queue(),^{PVXAlert(@"任务操作失败",@"暂停请求未入队");});
}
void PVXTaskAction(NSDictionary *task, NSString *action) {
    if ([action isEqual:@"delete"]) {
        PVXDeleteTasks(@[task], ^(NSString *error) { if (error) PVXAlert(@"删除未完成", error); });
        return;
    }
    NSDictionary *copy=[task copy];NSString *requested=[action copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        if([requested isEqual:@"pause"]){PVXQueuePauseAtSegmentBoundary(copy);return;}
        NSError *error=nil;BOOL ok=PVXQueueControl(copy,requested,&error);if(!ok)dispatch_async(dispatch_get_main_queue(),^{PVXAlert(@"任务操作失败", @"下载服务接口不可用或操作不受支持");});
    });
}
void PVXTaskActionAll(NSArray<NSDictionary*> *tasks, NSString *action, void(^completion)(NSUInteger,NSString*)) {
    NSArray *copy=[tasks copy]?:@[];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSUInteger count=0; NSString *firstError=nil;
        for(NSDictionary *task in copy){ NSError *error=nil; if(PVXQueueControl(task,action,&error)) count++; else if(!firstError.length) firstError=error.localizedDescription?:@"部分任务操作未入队"; }
        dispatch_async(dispatch_get_main_queue(),^{if(completion)completion(count,firstError);});
    });
}
NSDictionary *PVXStorageSummary(void) {
    NSString *root = PVXRoot();
    unsigned long long used = 0;
    if (root) {
        NSMutableSet *seen = [NSMutableSet set];
        for (NSString *sub in @[@"media", @"retained", @"image-media", @"files"]) {
            NSString *dir = PVXPath(sub);
            NSDirectoryEnumerator *enumerator = dir ? [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:dir] includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil] : nil;
            for (NSURL *url in enumerator) {
                struct stat st;
                if (!PVXContained(url.path, root) || lstat(url.fileSystemRepresentation, &st)) continue;
                if (S_ISLNK(st.st_mode)) { [enumerator skipDescendants]; continue; }
                if (!S_ISREG(st.st_mode)) continue;
                NSString *inode = [NSString stringWithFormat:@"%llu:%llu", (unsigned long long)st.st_dev, (unsigned long long)st.st_ino];
                if (![seen containsObject:inode]) { [seen addObject:inode]; used += (unsigned long long)MAX(0, st.st_size); }
            }
        }
    }
    NSNumber *available = nil;
    if (root) [[NSURL fileURLWithPath:root] getResourceValue:&available forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil];
    NSString *text = root ? [@"下载文件占用: " stringByAppendingString:[NSByteCountFormatter stringFromByteCount:(long long)used countStyle:NSByteCountFormatterCountStyleDecimal]] : @"下载目录不可用";
    if ([available isKindOfClass:NSNumber.class] && available.longLongValue >= 0) text = [text stringByAppendingFormat:@" · 当前目录所在卷可用: %@", [NSByteCountFormatter stringFromByteCount:available.longLongValue countStyle:NSByteCountFormatterCountStyleDecimal]];
    return @{@"text":text, @"used":@(used), @"total":@0, @"valid":@(root != nil), @"available":available ?: @(-1), @"source":@"process-visible download files; important-usage capacity of current root volume"};
}

#if !defined(PVX_FOUNDATION_TEST)
// Item source supplies a typed URL to Files and a decoded UIImage to Save Image.
@interface PVXShareItem : NSObject <UIActivityItemSource>
@property(nonatomic,strong) NSURL *url;
@property(nonatomic,strong) UIImage *image;
@property(nonatomic,copy) NSString *uti;
@end
@implementation PVXShareItem
- (id)activityViewControllerPlaceholderItem:(UIActivityViewController *)controller { (void)controller; return self.image ?: self.url; }
- (id)activityViewController:(UIActivityViewController *)controller itemForActivityType:(UIActivityType)type {
    (void)controller;
    return self.image && [type isEqual:UIActivityTypeSaveToCameraRoll] ? self.image : self.url;
}
- (NSString *)activityViewController:(UIActivityViewController *)controller dataTypeIdentifierForActivityType:(UIActivityType)type { (void)controller; (void)type; return self.uti; }
@end
@interface PVXShareSession : NSObject <UIAdaptivePresentationControllerDelegate>
@property(nonatomic,copy) NSString *directory;
@property(nonatomic,strong) UIActivityViewController *controller;
- (void)finish;
@end
static NSMutableSet *PVXShareSessions;
@implementation PVXShareSession
- (void)finish {
    if (!self.directory) return;
    [NSFileManager.defaultManager removeItemAtPath:self.directory error:nil];
    self.directory = nil;
    self.controller.completionWithItemsHandler = nil;
    self.controller = nil;
    [PVXShareSessions removeObject:self];
}
- (void)presentationControllerDidDismiss:(UIPresentationController *)controller { (void)controller; [self finish]; }
@end
void PVXExportTasks(NSArray<NSDictionary *> *tasks, UIView *anchor) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ PVXExportTasks(tasks, anchor); }); return; }
    if (!tasks.count) { PVXAlert(@"无法导出", @"请选择已下载的文件"); return; }
    NSArray *selection = [tasks copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"PyVideoExport-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSError *error = nil;
        BOOL ok = [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error];
        NSMutableArray *items = [NSMutableArray array];
        NSUInteger index = 0;
        for (NSDictionary *task in selection) {
            NSString *source = PVXTaskLocalPath(task);
            NSString *ext = source ? PVXExtension(task, source) : nil;
            if (!ok || !source || !ext.length) { ok = NO; break; }
            NSMutableCharacterSet *invalid = [NSCharacterSet.controlCharacterSet mutableCopy];
            [invalid addCharactersInString:@"/\\:?%*|\"<>"];
            NSString *title = [[PVXSafeText(task[@"title"], 100) componentsSeparatedByCharactersInSet:invalid] componentsJoinedByString:@"_"];
            if (!title.length || [title isEqual:@"."] || [title isEqual:@".."]) title = @"PyVideo";
            if ([title.pathExtension.lowercaseString isEqual:ext.lowercaseString]) title = title.stringByDeletingPathExtension;
            NSString *name = [[NSString stringWithFormat:@"%@-%lu", title, (unsigned long)++index] stringByAppendingPathExtension:ext];
            NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name]];
            // Copy instead of hardlink: share consumers cannot mutate worker media.
            ok = [fm copyItemAtPath:source toPath:url.path error:&error];
            if (!ok) break;
            chmod(url.fileSystemRepresentation, 0400);
            PVXShareItem *item = [PVXShareItem new]; item.url = url;
            if ([task[@"kind"] isEqual:@"image"]) {
                item.image = [UIImage imageWithContentsOfFile:url.path];
                item.uti = [UTType typeWithFilenameExtension:ext].identifier;
                if (!item.image || !item.uti.length) { ok = NO; break; }
            } else {
                item.uti = UTTypeMPEG4Movie.identifier;
                AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
                if (![asset tracksWithMediaType:AVMediaTypeVideo].count) { ok = NO; break; }
            }
            [items addObject:item];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *presenter = PVXPresenter();
            if (!ok || !items.count || !presenter.view.window || presenter.isBeingDismissed || presenter.presentedViewController) {
                [fm removeItemAtPath:dir error:nil];
                PVXAlert(@"无法导出", ok ? @"当前没有可用的分享窗口，请返回下载列表重试" : @"本地文件不存在、格式无效或无法建立导出副本，请重新下载或重试");
                return;
            }
            PVXShareSession *session = [PVXShareSession new]; session.directory = dir;
            UIActivityViewController *controller = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
            session.controller = controller;
            if (!PVXShareSessions) PVXShareSessions = [NSMutableSet set];
            [PVXShareSessions addObject:session];
            controller.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *returned, NSError *failure) {
                (void)type; (void)completed; (void)returned;
                [session finish];
                if (failure) PVXAlert(@"分享未完成", @"系统分享操作失败，请重试");
            };
            UIPopoverPresentationController *popover = controller.popoverPresentationController;
            if (popover) {
                UIView *sourceView = anchor.window == presenter.view.window ? anchor : presenter.view;
                popover.sourceView = sourceView;
                popover.sourceRect = CGRectMake(CGRectGetMidX(sourceView.bounds), CGRectGetMidY(sourceView.bounds), 1, 1);
                popover.permittedArrowDirections = 0;
            }
            controller.presentationController.delegate = session;
            [presenter presentViewController:controller animated:YES completion:^{ controller.presentationController.delegate = session; }];
        });
    });
}
void PVXExportTaskToFiles(NSDictionary *task) { PVXExportTasks(@[task], nil); }
static NSString *PVXCloudDownloadsPath(void){
    NSString *home=NSHomeDirectory();
    NSArray *roots=@[[home stringByAppendingPathComponent:@"Library/Mobile Documents/com~apple~CloudDocs/Downloads"],[home stringByAppendingPathComponent:@"Library/Mobile Documents/com~apple~CloudDocs/下载项目"]];
    for(NSString *root in roots) if([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]) return root;
    return nil;
}
void PVXSaveTaskToFiles(NSDictionary *task) {
    NSString *source=PVXTaskLocalPath(task); if(!source.length){PVXAlert(@"保存失败",@"本地文件尚未准备完成。");return;}
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSString *dir=PVXCloudDownloadsPath(); NSError *error=nil; NSString *title=PVXSafeText(task[@"title"],80); if(!title.length)title=task[@"id"]?:@"下载文件"; title=[title stringByReplacingOccurrencesOfString:@"/" withString:@"_"]; NSString *ext=task[@"kind"]&&[task[@"kind"] isEqual:@"image"]?source.pathExtension:@"mp4"; NSString *dest=dir?[dir stringByAppendingPathComponent:[title stringByAppendingPathExtension:ext]]:nil; BOOL ok=dest&&[NSFileManager.defaultManager copyItemAtPath:source toPath:dest error:&error]; dispatch_async(dispatch_get_main_queue(),^{if(ok)PVXAlert(@"已保存到文件",@"文件已写入 iCloud 云碟下载项目。 ");else PVXExportTasks(@[task],nil);});
    });
}
void PVXSaveTaskToPhotos(NSDictionary *task) {
    NSString *path=PVXTaskLocalPath(task); if(!path.length){PVXAlert(@"保存失败",@"本地文件尚未准备完成。");return;}
    void(^save)(void)=^{[[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{if([task[@"kind"] isEqual:@"image"]){UIImage *image=[UIImage imageWithContentsOfFile:path];if(image)[PHAssetChangeRequest creationRequestForAssetFromImage:image];}else [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:[NSURL fileURLWithPath:path]];} completionHandler:^(BOOL ok,NSError *error){if(!ok)PVXAlert(@"保存到相册失败",error.localizedDescription?:@"系统未完成保存。");}];};
    if(@available(iOS 14.0,*))[PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status){if(status==PHAuthorizationStatusAuthorized||status==PHAuthorizationStatusLimited)dispatch_async(dispatch_get_main_queue(),save);else PVXAlert(@"无法保存到相册",@"没有照片添加权限。");}];else [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status){if(status==PHAuthorizationStatusAuthorized)dispatch_async(dispatch_get_main_queue(),save);}];
}
BOOL PVXAutoSavePhotos(void){return [NSUserDefaults.standardUserDefaults boolForKey:@"com.crctdd.pyvideo.plus.autoPhotos"];}
void PVXSetAutoSavePhotos(BOOL enabled){[NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"com.crctdd.pyvideo.plus.autoPhotos"];}
void PVXApplyAutoSavePreferences(NSArray<NSDictionary*> *tasks){
    BOOL photos=[NSUserDefaults.standardUserDefaults boolForKey:@"com.crctdd.pyvideo.plus.autoPhotos"],files=[NSUserDefaults.standardUserDefaults boolForKey:@"com.crctdd.pyvideo.plus.autoFiles"];if(!photos&&!files)return;
    NSArray *copy=[tasks copy];dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{for(NSDictionary *task in copy){if(!PVXComplete(task)||!PVXTaskLocalPath(task)||!PVXUUID(task[@"id"]))continue;NSMutableDictionary*m=[PVXMetadata(task[@"id"]) mutableCopy];m[@"id"]=task[@"id"];if(photos&&! [m[@"autoPhotos"] boolValue]){m[@"autoPhotos"]=@YES;PVXAtomic(m,PVXMetadataPath(task[@"id"]),NULL);PVXSaveTaskToPhotos(task);}if(files&&! [m[@"autoFiles"] boolValue]){m[@"autoFiles"]=@YES;PVXAtomic(m,PVXMetadataPath(task[@"id"]),NULL);PVXSaveTaskToFiles(task);}}});
}
NSInteger PVXParallelLimit(void){NSInteger n=[NSUserDefaults.standardUserDefaults integerForKey:@"com.crctdd.pyvideo.plus.parallelDownloads"];return n>=1&&n<=15?n:15;}
void PVXSetParallelLimit(NSInteger limit){NSInteger n=MIN(15,MAX(1,limit));[NSUserDefaults.standardUserDefaults setInteger:n forKey:@"com.crctdd.pyvideo.plus.parallelDownloads"];NSDictionary *value=@{@"parallelDownloads":@(n)};PVXAtomic(value,PVXPath(@"plus-preferences.plist"),NULL);}
void PVXCreateDownloadFolder(NSString *name,void(^completion)(BOOL,NSString*)){NSString *safe=PVXSafeText(name,80);BOOL valid=safe.length&&[safe rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\:"]].location==NSNotFound;dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSString *root=PVXRoot();NSError *error=nil;BOOL ok=valid&&root&&[NSFileManager.defaultManager createDirectoryAtPath:[root stringByAppendingPathComponent:[NSString stringWithFormat:@"files/%@",safe]] withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error];dispatch_async(dispatch_get_main_queue(),^{if(completion)completion(ok,error.localizedDescription);});});}
NSDictionary *PVXTaskPresentation(NSDictionary *task) {
    NSString *state = PVXSafeText(task[@"state"], 40);
    BOOL local = PVXTaskHasLocalFile(task), complete = PVXComplete(task);
    NSDictionary *names = @{@"submitted":@"请求已排队 · 等待服务接收", @"serviceUnavailable":@"下载服务未响应（超过15秒）", @"queued":@"等待下载", @"downloading":@"下载中", @"hls":@"下载中", @"remuxing":@"正在封装", @"checking":@"校验中", @"converting":@"转换中", @"ready":@"下载完成", @"saved":@"下载完成", @"completed":@"下载完成", @"albumFailed":@"下载完成", @"uncertain":@"下载完成", @"failed":@"下载失败", @"pausing":@"正在暂停", @"paused":@"已暂停", @"deleting":@"正在删除", @"saving":@"正在处理"};
    NSString *status = complete && !local ? @"本地原文件缺失 · 需重新下载" : names[state] ?: @"等待处理";if([state isEqual:@"failed"]&&PVXSafeText(task[@"error"],240).length)status=[NSString stringWithFormat:@"下载失败：%@",PVXSafeText(task[@"error"],240)];
    BOOL success = complete && local;
    BOOL fail = [@[@"failed", @"serviceUnavailable"] containsObject:state] || (complete && !local);
    long long received = PVXBytes(task[@"received"]), total = PVXBytes(task[@"total"]);
    if (local && [task[@"localBytes"] isKindOfClass:NSNumber.class]) received=PVXBytes(task[@"localBytes"]);
    double progress = total > 0 ? MIN(1., (double)received/total) : 0;
    NSString *size = [NSByteCountFormatter stringFromByteCount:received countStyle:NSByteCountFormatterCountStyleDecimal];
    if (total > 0 && !complete) size = [size stringByAppendingFormat:@" / %@ (%.1f%%)", [NSByteCountFormatter stringFromByteCount:total countStyle:NSByteCountFormatterCountStyleDecimal], progress*100];
    long long segments = PVXBytes(task[@"segmentsDone"]), count = PVXBytes(task[@"segmentsTotal"]);
    if (count > 0 && !complete) { progress = MIN(1., (double)segments/count); size = [size stringByAppendingFormat:@" · %lld/%lld 片", segments, count]; }
    if ([state isEqual:@"converting"] && [task[@"conversionProgress"] isKindOfClass:NSNumber.class]) progress = MIN(1., MAX(0., [task[@"conversionProgress"] doubleValue]));
    NSString *format = [task[@"kind"] isEqual:@"image"] ? (PVXSafeText(task[@"extension"],16).length?task[@"extension"]:@"图片") : @"mp4";
    return @{@"status":status, @"symbol":success ? @"checkmark.circle.fill" : fail ? @"exclamationmark.circle.fill" : @"arrow.down.circle.fill", @"tint":success ? UIColor.systemGreenColor : fail ? UIColor.systemRedColor : UIColor.systemBlueColor, @"size":size, @"format":format ?: @"图片", @"progress":@(success ? 1 : progress), @"exportEnabled":@(local), @"exportUnavailableReason":local ? @"" : complete ? @"本地原文件已不存在，请重新下载" : @"下载完成后才能导出"};
}
@interface PVXThumbnail : NSObject
- (instancetype)initWithURL:(NSURL*)url cookies:(NSArray*)cookies referer:(NSString*)referer ua:(NSString*)ua done:(void(^)(UIImage*))done;
@end
static NSCache *PVXCoverCache;
static NSMutableDictionary *PVXCoverWaiters;
static NSMutableSet *PVXCoverJobs;
static UIImage *PVXLocalThumb(NSString *file){CGImageSourceRef src=CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:file],NULL);if(!src)return nil;NSDictionary *opt=@{(__bridge NSString*)kCGImageSourceCreateThumbnailFromImageAlways:@YES,(__bridge NSString*)kCGImageSourceCreateThumbnailWithTransform:@YES,(__bridge NSString*)kCGImageSourceThumbnailMaxPixelSize:@320};CGImageRef cg=CGImageSourceCreateThumbnailAtIndex(src,0,(__bridge CFDictionaryRef)opt);UIImage *v=cg?[UIImage imageWithCGImage:cg]:nil;if(cg)CGImageRelease(cg);CFRelease(src);return v;}
void PVXFetchTaskThumbnail(NSDictionary *task,void(^completion)(UIImage*)){if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{PVXFetchTaskThumbnail(task,completion);});return;}if(!PVXCoverCache){PVXCoverCache=[NSCache new];PVXCoverCache.countLimit=100;PVXCoverWaiters=[NSMutableDictionary dictionary];PVXCoverJobs=[NSMutableSet set];}NSString *key=PVXSafeText(task[@"id"],128);if(!key.length)key=PVXSafeText(task[@"key"],512);if(!key.length)key=PVXSafeText(task[@"poster"],16384);if(!key.length){completion(nil);return;}UIImage *cached=[PVXCoverCache objectForKey:key];if(cached){completion(cached);return;}NSMutableArray *wait=PVXCoverWaiters[key];if(wait){[wait addObject:[completion copy]];return;}if(PVXCoverJobs.count>=3){completion(nil);return;}PVXCoverWaiters[key]=[NSMutableArray arrayWithObject:[completion copy]];[PVXCoverJobs addObject:key];void(^finish)(UIImage*)=^(UIImage *image){dispatch_async(dispatch_get_main_queue(),^{if(image)[PVXCoverCache setObject:image forKey:key];NSArray *callbacks=PVXCoverWaiters[key];[PVXCoverWaiters removeObjectForKey:key];[PVXCoverJobs removeObject:key];for(void(^callback)(UIImage*) in callbacks)callback(image);});};NSString *local=PVXTaskLocalPath(task);if(local){dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{if([task[@"kind"] isEqual:@"image"]){finish(PVXLocalThumb(local));return;}AVAssetImageGenerator *generator=[[AVAssetImageGenerator alloc] initWithAsset:[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:local] options:nil]];generator.appliesPreferredTrackTransform=YES;generator.maximumSize=CGSizeMake(320,320);CGImageRef cg=[generator copyCGImageAtTime:CMTimeMake(0,1) actualTime:NULL error:nil];UIImage *image=cg?[UIImage imageWithCGImage:cg]:nil;if(cg)CGImageRelease(cg);finish(image);});return;}NSString *thumbnail=PVXSafeText(task[@"thumbnail"],200000);if([thumbnail hasPrefix:@"data:image/"]){dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSRange comma=[thumbnail rangeOfString:@","];NSData *data=comma.location==NSNotFound?nil:[[NSData alloc] initWithBase64EncodedString:[thumbnail substringFromIndex:comma.location+1] options:0];finish(data?[UIImage imageWithData:data]:nil);});return;}NSString *poster=PVXSafeText([task[@"kind"] isEqual:@"image"]?task[@"url"]:task[@"poster"],16384);NSURL *url=[NSURL URLWithString:poster];if(!url.host.length||![@[@"http",@"https"] containsObject:url.scheme.lowercaseString]){finish(nil);return;}WKWebView *web=PVXCollectionWebView()?:PVXCurrentWebView();if(!web){finish(nil);return;}[web.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray *cookies){[web evaluateJavaScript:@"navigator.userAgent" completionHandler:^(id v,NSError *e){NSString *ua=[v isKindOfClass:NSString.class]?v:@"";__block PVXThumbnail *job;job=[[PVXThumbnail alloc] initWithURL:url cookies:cookies referer:PVXSafeText(task[@"page"],16384) ua:ua done:^(UIImage *image){finish(image);job=nil;}];}];}];}

#endif

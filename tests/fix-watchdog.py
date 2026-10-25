from pathlib import Path
P=Path(__file__).resolve().parents[1]
p=P/'src/TaskSupport.m';s=p.read_text()
s=s.replace('#import <stdlib.h>','#import <stdlib.h>\n#import <objc/runtime.h>',1)
a=s.index('static NSString *PVXRoot(void) {');b=s.index('static BOOL PVXContained',a)
s=s[:a]+'''static NSString *PVXRoot(void) {
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
''' +s[b:]
a='NSString *PVXTaskLocalPath(NSDictionary *task) {\n    NSString *uuid = task[@"id"];'
b='NSString *PVXTaskLocalPath(NSDictionary *task) {\n    id prepared=objc_getAssociatedObject(task,&PVXResolvedFileKey);\n    if(prepared)return [prepared isKindOfClass:NSString.class]?prepared:nil;\n    NSString *uuid = task[@"id"];'
assert a in s;s=s.replace(a,b,1)
a='BOOL PVXTaskHasLocalFile(NSDictionary *task) { return PVXTaskLocalPath(task) != nil; }'
b='BOOL PVXTaskHasLocalFile(NSDictionary *task) { id prepared=objc_getAssociatedObject(task,&PVXResolvedFileKey);if(prepared)return [prepared isKindOfClass:NSString.class];if([task[@"hasLocalFile"] isKindOfClass:NSNumber.class])return [task[@"hasLocalFile"] boolValue];return PVXTaskLocalPath(task)!=nil; }'
assert a in s;s=s.replace(a,b,1)
a='NSArray<NSDictionary *> *PVXReadVideoTasks(void) {'
assert a in s;s=s.replace(a,'static NSArray<NSDictionary *> *PVXScanVideoTasks(void) {',1)
a='BOOL local = PVXTaskHasLocalFile(row);\n        row[@"hasLocalFile"] = @(local);'
b='''NSString *localPath=PVXTaskLocalPath(row);BOOL local=localPath!=nil;
        objc_setAssociatedObject(row,&PVXResolvedFileKey,localPath?:NSNull.null,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        row[@"hasLocalFile"] = @(local);
        if(localPath){struct stat st;if(!lstat(localPath.fileSystemRepresentation,&st))row[@"localBytes"]=@(MAX(0,st.st_size));}'''
assert a in s;s=s.replace(a,b,1)
a='static NSString *PVXExtension(NSDictionary *task, NSString *path) {'
idx=s.index(a)
extra='''// All UI refreshes share one non-main scanner. Concurrent requests coalesce.
static dispatch_queue_t PVXSnapshotQueue;
static NSLock *PVXSnapshotLock;
static NSMutableArray *PVXSnapshotCallbacks;
static NSArray *PVXSnapshotRows;
static NSDictionary *PVXSnapshotStorage;
static BOOL PVXSnapshotRunning;
static void PVXSnapshotSetup(void){static dispatch_once_t once;dispatch_once(&once,^{PVXSnapshotQueue=dispatch_queue_create("com.crctdd.pyvideo.plus.task-snapshot",DISPATCH_QUEUE_SERIAL);PVXSnapshotLock=[NSLock new];PVXSnapshotRows=@[];PVXSnapshotStorage=@{};PVXSnapshotCallbacks=[NSMutableArray array];});}
NSDictionary *PVXStorageSummary(void);
void PVXRequestTaskSnapshot(void(^completion)(NSArray<NSDictionary*>*,NSDictionary*)) {
    PVXSnapshotSetup();[PVXSnapshotLock lock];
    if(completion)[PVXSnapshotCallbacks addObject:[completion copy]];
    if(PVXSnapshotRunning){[PVXSnapshotLock unlock];return;}
    PVXSnapshotRunning=YES;[PVXSnapshotLock unlock];
    dispatch_async(PVXSnapshotQueue,^{@autoreleasepool{
        NSArray *rows=PVXScanVideoTasks();static NSTimeInterval lastStorage;
        NSTimeInterval now=NSDate.date.timeIntervalSince1970;
        NSDictionary *storage=PVXSnapshotStorage;
        if(!storage.count||now-lastStorage>=15){storage=PVXStorageSummary();lastStorage=now;}
        [PVXSnapshotLock lock];PVXSnapshotRows=rows;PVXSnapshotStorage=storage;
        NSArray *callbacks=[PVXSnapshotCallbacks copy];[PVXSnapshotCallbacks removeAllObjects];PVXSnapshotRunning=NO;[PVXSnapshotLock unlock];
        dispatch_async(dispatch_get_main_queue(),^{for(void(^block)(NSArray*,NSDictionary*) in callbacks)block(rows,storage);});
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
'''
s=s[:idx]+extra+s[idx:]
a='if (local) { struct stat st; if (!lstat(PVXTaskLocalPath(task).fileSystemRepresentation, &st)) received = st.st_size; }'
b='if (local && [task[@"localBytes"] isKindOfClass:NSNumber.class]) received=PVXBytes(task[@"localBytes"]);'
assert a in s;s=s.replace(a,b,1)
a='NSString *format = [task[@"kind"] isEqual:@"image"] ? (local ? PVXExtension(task, PVXTaskLocalPath(task)) : @"图片") : @"mp4";'
b='NSString *format = [task[@"kind"] isEqual:@"image"] ? (PVXSafeText(task[@"extension"],16).length?task[@"extension"]:@"图片") : @"mp4";'
assert a in s;s=s.replace(a,b,1)
p.write_text(s)
# Cache the native resolver/mapped path in Main, eliminating repeated RTLD_DEFAULT walks.
p=P/'src/Main.m';s=p.read_text();a=s.index('NSString *PVXStateRoot(void){');b=s.index('NSString *PVXResourcePath',a)
s=s[:a]+'''NSString *PVXStateRoot(void){
    typedef id(*RootFn)(void);typedef id(*JB)(id);
    static RootFn native;static JB mapper;static dispatch_once_t once;static NSString *cached;
    static NSLock *lock;dispatch_once(&once,^{lock=[NSLock new];native=(RootFn)dlsym(RTLD_DEFAULT,"PVStateDirectory");if(!native)mapper=(JB)dlsym(RTLD_DEFAULT,"_Z6jbrootP8NSString");});
    [lock lock];NSString *path=cached;[lock unlock];if(path)return path;
    id resolved=native?native():(mapper?mapper(@"/var/mobile/Library/Application Support/com.crctdd.pyvideo"):nil);
    if(![resolved isKindOfClass:NSString.class]||![resolved isAbsolutePath])return @"";
    [lock lock];if(!cached)cached=[resolved copy];path=cached;[lock unlock];return path;
}
''' +s[b:];p.write_text(s)

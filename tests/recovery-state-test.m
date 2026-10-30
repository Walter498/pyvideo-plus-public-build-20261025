// fake-remux integration: real production recovery/localizer/validator, NOT iOS libav proof.
#define PVX_STORAGE_MOCK 1
#import "../storage/Storage.m"
#import <pthread.h>
#import <stdatomic.h>
#import <time.h>

@interface FakeAgent : NSObject
@property(nonatomic,strong) NSMutableDictionary *tasks;
@property(nonatomic,strong) NSMutableSet *exports;
@property(nonatomic,strong) NSDictionary *clearingRequest;
@property(nonatomic) BOOL workerMode, reconciled;
@end
@implementation FakeAgent
@end

static NSString *TestRoot, *Fixtures, *KnownFixturePath, *CurrentID;
static FakeAgent *Agent;
static NSMutableSet *NeverReady;
static NSUInteger PersistCalls, RawDownloadCalls, Cases;
static atomic_int NativeMode, NativeEntered, CancelObserved, NativeCalls;
static pthread_mutex_t SharedMutex = PTHREAD_MUTEX_INITIALIZER;
static BOOL SawValidating;
static NSData *PreviousOutput;
static void Cleanup(void) {
    if (TestRoot) [NSFileManager.defaultManager removeItemAtPath:TestRoot error:NULL];
}
static void Fail(const char *expression, int line) {
    fprintf(stderr,"FAIL fake-remux case %lu line %d: %s\n",(unsigned long)Cases,line,expression);
    exit(1);
}
#define CHECK(x) do { if (!(x)) Fail(#x,__LINE__); } while (0)
static NSString *MockRoot(void) { return TestRoot; }
static NSString *Destination(void) { return Path([NSString stringWithFormat:@"media/%@.mp4",CurrentID]); }
static NSString *Cache(void) { return Path([NSString stringWithFormat:@"media/%@.hls",CurrentID]); }
static NSString *Diagnostic(NSString *suffix) {
    return Path([NSString stringWithFormat:@"plus-diagnostics/hls-%@-%@.plist",CurrentID,suffix]);
}
static void FlushDiagnostics(void){PVXLogSetup();dispatch_sync(PVXLogQueue,^{});}
static NSDictionary *ReadDiagnostic(NSString *suffix) {
    FlushDiagnostics();
    return [NSDictionary dictionaryWithContentsOfFile:Diagnostic(suffix)];
}
static BOOL MockWrite(id value, NSString *path, NSError **error) {
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:value
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}
static void MockNotify(NSString *signal) { CHECK([signal isEqual:Signal]); }
static BOOL MockPersist(id agent, SEL selector, id task) {
    (void)agent; (void)selector;
    PersistCalls++;
    NSString *uuid=task[@"id"];
    CHECK(!([NeverReady containsObject:uuid] && [task[@"state"] isEqual:@"ready"]));
    if ([uuid isEqual:CurrentID] && [task[@"pvxRecoveryStage"] isEqual:@"validating"]) {
        SawValidating=YES;
        // Validation must precede publication; old output stays intact meanwhile.
        NSData *existing=[NSData dataWithContentsOfFile:Destination()];
        CHECK(PreviousOutput ? [existing isEqual:PreviousOutput] : existing==nil);
    }
    return MockWrite(task,Path([uuid stringByAppendingPathExtension:@"plist"]),NULL);
}
static BOOL MockControl(id agent, SEL selector, id action, id uuid) {
    (void)selector;
    NSMutableDictionary *task=[[agent tasks][uuid] mutableCopy];
    if ([action isEqual:@"pause"] || [action isEqual:@"delete"]) {
        task[@"state"]=[action isEqual:@"pause"]?@"paused":@"deleted";
        task[@"fileComplete"]=@NO;
        [agent tasks][uuid]=task;
        return YES;
    }
    if ([action isEqual:@"retry"] || [action isEqual:@"resume"]) RawDownloadCalls++;
    return YES;
}

// Exported from the main executable: production dlsym + image-owner checks remain active.
pthread_mutex_t *PVXNativeRemuxTestSharedMutex(void) { return &SharedMutex; }
__attribute__((visibility("default")))
int PVRemuxHLSWithCancel(const char *input, const char *output, char *error,
                        size_t capacity, int (*cancel)(void *), void *opaque) {
    @autoreleasepool {
        CHECK(input && output && error && capacity && cancel);
        NSString *playlist=[NSString stringWithContentsOfFile:
            [NSString stringWithUTF8String:input] encoding:NSUTF8StringEncoding error:NULL];
        CHECK([playlist containsString:@"#EXT-X-ENDLIST"]);
        CHECK([playlist containsString:@"pvx-input-"]);
        CHECK(![playlist containsString:@"file:"]&&! [playlist containsString:@"%20"]);
        atomic_fetch_add(&NativeCalls,1);
        atomic_store(&NativeEntered,1);
        int mode=atomic_load(&NativeMode);
        if (mode==1) {
            snprintf(error,capacity,"fake-remux injected nativeReturn=-1");
            return -1;
        }
        if (mode==2) {
            // Poll the actual adapter cancellation callback, not a test-owned flag.
            for (int i=0;i<2000;i++) {
                if (cancel(opaque)) {
                    atomic_store(&CancelObserved,1);
                    snprintf(error,capacity,"fake-remux cancelled");
                    return -1414092869;
                }
                struct timespec tick={0,10000000}; nanosleep(&tick,NULL);
            }
            snprintf(error,capacity,"fake-remux cancellation deadline"); return -1;
        }
        // Always copy an actual generated MP4; never pass garbage off as valid media.
        NSError *copyError=nil;
        BOOL copied=[NSFileManager.defaultManager copyItemAtPath:KnownFixturePath
            toPath:[NSString stringWithUTF8String:output] error:&copyError];
        if (!copied) snprintf(error,capacity,"fake-remux copy: %s",copyError.description.UTF8String);
        return copied?0:-1;
    }
}

// All predicates execute on the main queue, never blocking it while the worker runs.
static void Await(NSString *label, double deadline, BOOL (^predicate)(void), void (^next)(void)) {
    if (predicate()) { next(); return; }
    if (NSDate.date.timeIntervalSince1970>deadline) {
        fprintf(stderr,"Timeout awaiting %s; task=%s\n",label.UTF8String,
            [Agent.tasks[CurrentID] description].UTF8String); Fail("state wait deadline",__LINE__);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        Await(label,deadline,predicate,next);
    });
}
static void Wait(NSString *label, BOOL (^predicate)(void), void (^next)(void)) {
    Await(label,NSDate.date.timeIntervalSince1970+45,predicate,next);
}
static void DrainWorker(void (^next)(void)) {
    // FIFO barrier after the recovery block: its main-queue finish has already been enqueued.
    dispatch_async(PVXRecoveryQueue,^{ dispatch_async(dispatch_get_main_queue(),next); });
}
static void CheckSourcesAndStaging(void) {
    for (NSString *file in @[@"local-0.m3u8",@"segment-0.ts",@"segment-1.ts"])
        CHECK([NSFileManager.defaultManager fileExistsAtPath:[Cache() stringByAppendingPathComponent:file]]);
    for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:Path(@"media") error:NULL])
        CHECK(![file hasSuffix:@".recovery.mp4"]);
    CHECK(!RecoveryExports[CurrentID]);
}
static void Prepare(int mode, NSString *fixture, BOOL existing) {
    CurrentID=NSUUID.UUID.UUIDString;
    Cases++; SawValidating=NO;
    atomic_store(&NativeMode,mode); atomic_store(&NativeEntered,0); atomic_store(&CancelObserved,0);
    KnownFixturePath=[Fixtures stringByAppendingPathComponent:fixture];
    PreviousOutput=existing?[NSData dataWithContentsOfFile:[Fixtures stringByAppendingPathComponent:@"valid.mp4"]]:nil;
    CHECK(SafeDirectory(Cache()));
    for (NSString *name in @[@"segment-0.ts",@"segment-1.ts"]) {
        // Closure semantics only: these 188-byte fragments contain NO decodable media.
        CHECK([[NSMutableData dataWithLength:188] writeToFile:[Cache() stringByAppendingPathComponent:name] atomically:YES]);
    }
    NSString *playlist=@"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:2,\nsegment-0.ts\n#EXTINF:2,\nsegment-1.ts\n#EXT-X-ENDLIST\n";
    CHECK([playlist writeToFile:[Cache() stringByAppendingPathComponent:@"local-0.m3u8"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    if (PreviousOutput) CHECK([PreviousOutput writeToFile:Destination() atomically:YES]);
    Agent.tasks[CurrentID]=[@{@"id":CurrentID,@"state":@"failed",@"fileComplete":@NO,
        @"segmentsDone":@2,@"segmentsTotal":@2,@"hlsSourceURL":@"https://invalid.example/test.m3u8"} mutableCopy];
}
static void NextCase(void);
static void CheckReady(void) {
    NSDictionary *task=Agent.tasks[CurrentID], *result=ReadDiagnostic(@"result");
    CHECK([task[@"state"] isEqual:@"ready"] && [task[@"fileComplete"] boolValue]);
    CHECK(SawValidating && [result[@"valid"] boolValue]);
    CHECK([result[@"videoFramesDecoded"] integerValue]==3);
    CHECK([result[@"audioSampleDecoded"] boolValue]);
    CHECK(fabs([ReadDiagnostic(@"playlist")[@"expectedDuration"] doubleValue]-4)<0.01);
    CHECK([[NSData dataWithContentsOfFile:Destination()] isEqual:[NSData dataWithContentsOfFile:KnownFixturePath]]);
    CheckSourcesAndStaging();
}
static void RunReady(BOOL retry) {
    Prepare(0,@"valid.mp4",NO);
    NSUInteger before=RawDownloadCalls;
    if (retry) CHECK(PVXControlRecovery(Agent,NULL,@"retry",CurrentID));
    else { Tick(); CHECK([RecoveryAttempted containsObject:CurrentID]); }
    CHECK([Agent.tasks[CurrentID][@"state"] isEqual:@"checking"]&&[Agent.tasks[CurrentID][@"pvxRecoveryActive"] boolValue]);
    CHECK(RawDownloadCalls==before);
    Wait(@"ready after real validator",^{return [Agent.tasks[CurrentID][@"state"] isEqual:@"ready"];},^{
        CheckReady(); CHECK(RawDownloadCalls==before); NextCase();
    });
}
static void RunFailure(BOOL validation) {
    Prepare(validation?0:1,validation?@"audio-only.mp4":@"valid.mp4",YES);
    [NeverReady addObject:CurrentID];
    PVXRecoverFailedHLS(Agent,Agent.tasks[CurrentID]);
    Wait(@"failed",^{return [Agent.tasks[CurrentID][@"state"] isEqual:@"failed"];},^{
        CHECK(![Agent.tasks[CurrentID][@"fileComplete"] boolValue]);
        CHECK([[NSData dataWithContentsOfFile:Destination()] isEqual:PreviousOutput]);
        CHECK([Agent.tasks[CurrentID][@"pvxRecoveryStage"] isEqual:@"failed"]);
        if (validation) { CHECK(SawValidating); CHECK([ReadDiagnostic(@"result")[@"reason"] isEqual:@"missing_video"]); }
        else CHECK([ReadDiagnostic(@"remux")[@"nativeReturn"] intValue]==-1);
        CheckSourcesAndStaging(); NextCase();
    });
}
static void RunCancel(BOOL deletion) {
    Prepare(2,@"valid.mp4",NO); [NeverReady addObject:CurrentID];
    PVXRecoverFailedHLS(Agent,Agent.tasks[CurrentID]);
    Wait(@"native work entered",^{return (BOOL)(atomic_load(&NativeEntered)!=0);},^{
        CHECK([Agent.tasks[CurrentID][@"state"] isEqual:@"checking"]&&[Agent.tasks[CurrentID][@"pvxRecoveryActive"] boolValue]);
        CHECK(PVXControlRecovery(Agent,NULL,deletion?@"delete":@"pause",CurrentID));
        NSString *state=deletion?@"deleted":@"paused";
        Wait(@"actual native cancellation",^{return (BOOL)(atomic_load(&CancelObserved)!=0);},^{
            DrainWorker(^{
                CHECK([Agent.tasks[CurrentID][@"state"] isEqual:state]);
                CHECK(![Agent.tasks[CurrentID][@"fileComplete"] boolValue]);
                CHECK(![NSFileManager.defaultManager fileExistsAtPath:Destination()]);
                CHECK([ReadDiagnostic(@"remux")[@"stage"] isEqual:@"cancel"]);
                CheckSourcesAndStaging(); NextCase();
            });
        });
    });
}
static void RunRequeued(void) {
    Prepare(0,@"valid.mp4",NO);
    Agent.tasks[CurrentID][@"state"]=@"queued";
    PVXStartTaskRecovery(Agent,NULL,Agent.tasks[CurrentID],nil);
    CHECK([Agent.tasks[CurrentID][@"state"] isEqual:@"checking"]&&[Agent.tasks[CurrentID][@"pvxRecoveryActive"] boolValue]);
    Wait(@"requeued completed HLS stays offline",^{return [Agent.tasks[CurrentID][@"state"] isEqual:@"ready"];},^{
        CheckReady();CHECK(RawDownloadCalls==0);NextCase();
    });
}
static void NextCase(void) {
    switch(Cases) {
        case 0: RunReady(NO); break;
        case 1: RunFailure(NO); break;
        case 2: RunCancel(NO); break;
        case 3: RunCancel(YES); break;
        case 4: RunReady(YES); break;
        case 5: RunFailure(YES); break;
        case 6: RunRequeued(); break;
        default:
            CHECK(atomic_load(&NativeCalls)==7 && PersistCalls>7 && RawDownloadCalls==0);
            printf("PASS fake-remux: 7 production recovery lifecycle cases; real AVFoundation 3-frame + audio decode, cancellation, retry routing, atomic publication and failed-validation preservation. NOT proof of original iOS libav success.\n");
            exit(0);
    }
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if(argc!=2) { fprintf(stderr,"usage: recovery-state-test FIXTURE_DIRECTORY\n"); return 2; }
        Fixtures=[NSString stringWithUTF8String:argv[1]];
        TestRoot=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        atexit(Cleanup);
        Root=MockRoot; Write=MockWrite; Notify=MockNotify; Persist=MockPersist; OldControl=MockControl;
        CHECK(SafeDirectory(TestRoot)); CHECK(SafeDirectory(Path(@"media")));
        RecoveryExports=[NSMutableDictionary dictionary]; RecoveryAttempted=[NSMutableSet set];
        NeverReady=[NSMutableSet set]; Agent=[FakeAgent new]; Agent.tasks=[NSMutableDictionary dictionary];
        Agent.exports=[NSMutableSet set]; Agent.workerMode=YES; Agent.reconciled=YES; Worker=Agent;
        dispatch_async(dispatch_get_main_queue(),^{ NextCase(); });
    }
    CFRunLoopRun();
    return 0;
}

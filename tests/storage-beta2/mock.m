#define PVX_STORAGE_MOCK 1
#define PVXNativeRemuxHLS PVXMockNativeRemux
#import "../../storage/Storage.m"
#include <assert.h>
@interface MockAgent : NSObject
@property BOOL workerMode, reconciled, memoryReady;
@property(strong) NSMutableDictionary *tasks;
@property(strong) NSMutableSet *exports;
@property(strong) NSDictionary *clearingRequest;
@end
static BOOL PVXMockNativeRemux(NSString *inputPath,NSString *outputPath,NSString **errorText){(void)inputPath;(void)outputPath;if(errorText)*errorText=@"mock";return NO;}
@implementation MockAgent
- (void)exportReady { Export(self, _cmd); }
@end
static NSString *TestRoot;
static NSUInteger ExportCalls, RemoveCalls, FinishCalls;
static BOOL SimulatedSuccess;
static NSString *LastID;
static NSString *MockRoot(void) { return TestRoot; }
static NSString *MockMedia(NSString *uuid) { return Path([NSString stringWithFormat:@"media/%@.mp4", uuid]); }
static id MockTasks(id self, SEL cmd) { (void)cmd; return [self tasks]; }
static BOOL MockWrite(id value, NSString *path, NSError **error) {
    NSData *d = [NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    return [d writeToFile:path options:NSDataWritingAtomic error:error];
}
static void MockNotify(NSString *name) { (void)name; }
static BOOL MockRemove(id self, SEL cmd, id p, NSError **error) {
    (void)self; (void)cmd; RemoveCalls++;
    return [NSFileManager.defaultManager removeItemAtPath:p error:error];
}
static void MockExport(id self, SEL cmd) {
    (void)self; (void)cmd; ExportCalls++;
    // Production Export is intentionally a no-op; this helper is retained
    // only for the old mock's counter and is never installed.
}
static void MockFinish(id self, SEL cmd, id uuid, BOOL success, id error, id assetID) {
    (void)cmd; (void)error; FinishCalls++;
    NSMutableDictionary *task = [self tasks][uuid];
    [[self exports] removeObject:uuid];
    if (success) {
        task[@"state"] = @"saved"; task[@"savedAt"] = @123; task[@"assetID"] = assetID;
        Remove(nil, @selector(removeItemAtPath:error:), Media(uuid), NULL);
        Remove(nil, @selector(removeItemAtPath:error:), [Media(uuid) stringByAppendingString:@".compatible.mp4"], NULL);
    } else { task[@"state"] = @"albumFailed"; }
    SimulatedSuccess = success;
}
static NSMutableDictionary *Task(NSString *uuid) { return [@{@"id":uuid, @"state":@"ready"} mutableCopy]; }
static void Request(NSString *uuid) {
    MockWrite(@{@"id":uuid,@"created":@(NSDate.date.timeIntervalSince1970)}, Path([NSString stringWithFormat:@"plus-manual-photos/%@.plist", uuid]), NULL);
}
int main(void) {
    @autoreleasepool {
        TestRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        Root=MockRoot;
        assert(SafeDirectory(TestRoot)); assert(SafeDirectory(Path(@"media")));
        assert(SafeDirectory(Path(@"plus-manual-photos")));
        Root=MockRoot; Media=MockMedia; Write=MockWrite; Notify=MockNotify;
        OldFinish=MockFinish; OldRemove=MockRemove;
        MockAgent *a = [MockAgent new]; a.workerMode=YES; a.reconciled=YES; a.memoryReady=YES;
        NSString *u=@"550E8400-E29B-41D4-A716-446655440000", *v=@"550E8400-E29B-41D4-A716-446655440001";
        a.tasks=[@{u:Task(u),v:Task(v)} mutableCopy]; a.exports=[NSMutableSet set];
        Export(a,@selector(exportReady)); assert(ExportCalls==0);
        MockWrite(@{@"autoSavePhotos":@NO}, Path(@"plus-preferences.plist"), NULL);
        Export(a,@selector(exportReady)); assert(ExportCalls==0); assert(a.exports.count==0);
        Request(v); Export(a,@selector(exportReady));
        assert(ExportCalls==0 && !LastID); assert([a.tasks[u][@"state"] isEqual:@"ready"]);
        assert([a.tasks[v][@"state"] isEqual:@"ready"]);
        assert(![NSFileManager.defaultManager fileExistsAtPath:Path([NSString stringWithFormat:@"plus-manual-photos/%@.plist",v])]);
        // A Beta2 transaction was already active before the new hook took over.
        a.tasks[v][@"state"]=@"saving"; [a.exports addObject:v];
        [@"original video" writeToFile:Media(v) atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        Finish(a,NULL,v,YES,nil,@"asset-123");
        assert(SimulatedSuccess && [a.tasks[v][@"assetID"] isEqual:@"asset-123"]);
        assert([a.tasks[v][@"savedAt"] isEqual:@123]);
        assert([NSFileManager.defaultManager fileExistsAtPath:Path([NSString stringWithFormat:@"retained/%@.mp4",v])]);
        assert(![NSFileManager.defaultManager fileExistsAtPath:Media(v)]);
        Request(v); Export(a,@selector(exportReady)); assert(ExportCalls==0); // saved duplicate denied
        a.tasks[v][@"state"]=@"uncertain"; Request(v); Export(a,@selector(exportReady)); assert(ExportCalls==0);
        Request(u); Export(a,@selector(exportReady)); assert(ExportCalls==0);
        assert([a.tasks[u][@"state"] isEqual:@"ready"]);
        a.tasks[u][@"state"]=@"saving"; [a.exports addObject:u];
        [@"second original" writeToFile:Media(u) atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        // Retained destination collision exercises narrow fallback in actual hook.
        [@"collision" writeToFile:Path([NSString stringWithFormat:@"retained/%@.mp4",u]) atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSUInteger before=RemoveCalls;
        Finish(a,NULL,u,YES,nil,@"asset-456"); assert(RemoveCalls==before);
        assert([NSFileManager.defaultManager fileExistsAtPath:Media(u)]); assert(!ProtectedPaths);
        Remove(nil,NULL,Media(u),NULL); assert(RemoveCalls==before+1); // scope restored
        a.tasks[u][@"state"]=@"saving"; [a.exports addObject:u];
        Finish(a,NULL,u,NO,nil,nil); assert(!SimulatedSuccess && FinishCalls==3);
        [@"invalid" writeToFile:Path(@"plus-preferences.plist") atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        Export(a,@selector(exportReady)); assert(ExportCalls==0);
        for (id value in @[@YES,@NO,@1,@"YES"]) {
            MockWrite(@{@"autoSavePhotos":value}, Path(@"plus-preferences.plist"), NULL);
            a.tasks[u][@"state"]=@"ready";
            Request(u); Export(a,@selector(exportReady));
            assert(ExportCalls==0 && [a.tasks[u][@"state"] isEqual:@"ready"]);
            assert(![NSFileManager.defaultManager fileExistsAtPath:Path([NSString stringWithFormat:@"plus-manual-photos/%@.plist",u])]);
        }
        Tick(); assert(ExportCalls==0);
        [NSFileManager.defaultManager removeItemAtPath:TestRoot error:NULL];
        puts("PASS production hooks: direct runtime install, no automatic Photos export, retention and failure passthrough");
    }
}

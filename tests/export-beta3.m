// Compile on macOS Foundation. Includes production task/metadata/control/storage sections.
#define PVX_TEST 1
#define PVX_FOUNDATION_TEST 1
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <utime.h>
static BOOL allowControl = NO;
static NSUInteger alerts = 0;
NSString *PVXStateRoot(void) { return @"/path/that/must/not/be/used"; }
void PVXAlert(NSString *title, NSString *message) { (void)title; (void)message; alerts++; }
__attribute__((visibility("default"))) BOOL PVEnqueueControl(NSString *task, NSString *action, NSError **error) {
    (void)error;
    NSCAssert([[NSUUID alloc] initWithUUIDString:task] && [action isEqual:@"delete"], @"exact protocol");
    return allowControl;
}
#import "../src/TaskSupport.m"
static void writeFixture(NSString *relative, NSDictionary *value) {
    NSError *error = nil;
    NSCAssert(PVXAtomic(value, PVXPath(relative), &error), @"fixture write");
}
static NSDictionary *findRow(NSString *uuid) {
    for (NSDictionary *r in PVXReadVideoTasks()) if ([r[@"id"] isEqual:uuid]) return r;
    return nil;
}
int main(void) { @autoreleasepool {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("PVX_TEST_ROOT", root.fileSystemRepresentation, 1);
    NSString *a = @"11111111-1111-4111-8111-111111111111";
    NSString *b = @"22222222-2222-4222-8222-222222222222";
    NSString *c = @"33333333-3333-4333-8333-333333333333";
    NSDictionary *video = @{@"id":a, @"kind":@"video", @"title":@"clip", @"state":@"ready", @"created":@1,
        @"headers":@{@"Authorization":@"secret"}, @"url":@"https://host/?token=secret", @"page":@"secret", @"request":@{@"cookie":@"secret"}};
    writeFixture([NSString stringWithFormat:@"tasks/%@.plist", a], video);
    writeFixture([NSString stringWithFormat:@"inbox/%@.plist", b], @{@"id":b, @"title":@"waiting", @"cookies":@[@"secret"]});
    writeFixture([NSString stringWithFormat:@"inbox/%@.plist", c], @{@"id":c, @"action":@"delete", @"target":a});
    NSCAssert(PVXReadVideoTasks().count == 2, @"pending merged; controls excluded");
    NSCAssert([findRow(b)[@"state"] isEqual:@"submitted"], @"queued not success");
    NSCAssert(![findRow(a).description containsString:@"secret"], @"allowlist strips private nested fields");
    NSCAssert(!PVXTaskLocalPath(video), @"missing original not exportable");
    NSString *inbox = PVXPath([NSString stringWithFormat:@"inbox/%@.plist", b]);
    struct utimbuf old = { .actime = time(NULL)-20, .modtime = time(NULL)-20 };
    utime(inbox.fileSystemRepresentation, &old);
    NSCAssert([findRow(b)[@"state"] isEqual:@"serviceUnavailable"], @"15 second worker deadline");
    NSString *source = PVXPath([NSString stringWithFormat:@"media/%@.mp4", a]);
    [NSFileManager.defaultManager createDirectoryAtPath:source.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [@"immutable-fixture" writeToFile:source atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSCAssert([PVXTaskLocalPath(video) isEqual:source], @"actual file found");
    NSMutableDictionary *active = [video mutableCopy]; active[@"state"] = @"downloading"; active[@"fileComplete"] = @YES;
    NSCAssert(!PVXTaskLocalPath(active), @"active writers cannot export");
    PVXUpdateTaskMetadata(@[video], @"title", @"renamed");
    PVXUpdateTaskMetadata(@[video], @"tags", @"one,two");
    PVXUpdateTaskMetadata(@[video], @"folder", @"旅行");
    NSString *organized = PVXTaskLocalPath(video);
    NSCAssert([organized containsString:@"/files/旅行/"] && PVXRegular(organized) && PVXRegular(source), @"real organization preserves worker source");
    NSCAssert([findRow(a)[@"title"] isEqual:@"renamed"] && [findRow(a)[@"tags"] isEqual:@"one,two"], @"metadata read after persist");
    NSCAssert([PVXPlist(PVXPath([NSString stringWithFormat:@"tasks/%@.plist", a]))[@"title"] isEqual:@"clip"], @"worker snapshot unchanged");
    PVXUpdateTaskMetadata(@[video], @"folder", @"../escape");
    NSCAssert(alerts == 1, @"traversal rejected");
    NSDictionary *summary = PVXStorageSummary();
    NSCAssert([summary[@"used"] unsignedLongLongValue] == 2 * [@"immutable-fixture" lengthOfBytesUsingEncoding:NSUTF8StringEncoding], @"actual file byte sum");
    __block NSString *failure = nil; __block BOOL done=NO;
    PVXDeleteTasks(@[video], ^(NSString *error) { failure = error; done=YES; });
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:14];
    while(!done&&deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    NSCAssert(done&&failure && PVXRegular(organized) && PVXMetadata(a).count, @"failed queue preserves organizer");
    allowControl = YES; done=NO;
    writeFixture([NSString stringWithFormat:@"tasks/%@.plist",a],@{@"id":a,@"state":@"deleted"});
    PVXDeleteTasks(@[video], ^(NSString *error) { failure = error; done=YES; });
    deadline=[NSDate dateWithTimeIntervalSinceNow:14];
    while(!done&&deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    NSCAssert(done&&!failure && !PVXRegular(organized) && !PVXMetadata(a).count && PVXRegular(source), @"confirmed worker deletion cleans organizer");
    NSDictionary *image = @{@"id":b, @"kind":@"image"}; done=NO;
    writeFixture([NSString stringWithFormat:@"image-tasks/%@.plist",b],@{@"id":b,@"state":@"deleted"});
    PVXDeleteTasks(@[image], ^(NSString *error) { failure = error; done=YES; });
    deadline=[NSDate dateWithTimeIntervalSinceNow:14];
    while(!done&&deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    NSCAssert(done&&!failure, @"image control queue");
    NSArray *commands = [NSFileManager.defaultManager contentsOfDirectoryAtPath:PVXPath(@"plus-image-control") error:nil];
    NSDictionary *command = PVXPlist([PVXPath(@"plus-image-control") stringByAppendingPathComponent:commands.firstObject]);
    NSCAssert([command[@"target"] isEqual:b] && [command[@"action"] isEqual:@"delete"] && PVXUUID(command[@"id"]), @"worker image protocol");
    writeFixture([NSString stringWithFormat:@"plus-metadata/%@.plist", a], @{@"id":a, @"organized":@"files/../outside.mp4"});
    NSCAssert([PVXTaskLocalPath(video) isEqual:source], @"hostile metadata ignored");
    NSCAssert(!PVXAutoSavePhotos(), @"auto Photos hard disabled");
    PVXSetAutoSavePhotos(YES);
    NSCAssert(!PVXAutoSavePhotos() && ![NSFileManager.defaultManager fileExistsAtPath:PVXPath(@"plus-preferences.plist")], @"legacy setter cannot enable Photos");
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    puts("PASS export-beta3: pending, timeout, sanitization, real files, metadata/move, queue failure/success, image control, traversal, storage, no Photos");
} return 0; }

#define PVX_TEST 1
#import "../src/TaskSupport.m"
#import "../src/Collection.m"
static WKWebView *TestWeb;
@interface PVXFixtureWeb : WKWebView
@end
@implementation PVXFixtureWeb
- (NSURL *)URL { return [NSURL URLWithString:@"https://fixture.invalid/page"]; }
@end
id PVXBrowser(void) { return nil; }
NSArray<NSDictionary *> *PVXImageCollected(WKWebView *web) { (void)web; return @[]; }
NSArray<NSDictionary *> *PVXVideoCollected(WKWebView *web) { (void)web; return @[]; }
void PVXRefreshImages(WKWebView *web) { (void)web; }
void PVXValidateCollected(WKWebView *web, NSDictionary *row, void (^done)(BOOL, NSString *)) {
    (void)web; (void)row; done(YES, @"PVX-Integration");
}
static UIViewController *Host;
static NSString *FixtureRoot;
static NSUInteger AlertCount;
NSString *PVXStateRoot(void) { return FixtureRoot; }
UIViewController *PVXPresenter(void) { return Host; }
WKWebView *PVXCurrentWebView(void) { return nil; }
void PVXAlert(NSString *title, NSString *message) { (void)title; (void)message; AlertCount++; }
@implementation PVXThumbnail
- (instancetype)initWithURL:(NSURL *)url cookies:(NSArray *)cookies referer:(NSString *)referer ua:(NSString *)ua done:(void (^)(UIImage *))done {
    (void)url; (void)cookies; (void)referer; (void)ua;
    if ((self = [super init])) done(nil);
    return self;
}
@end
@interface PVXExportTestApp : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation PVXExportTestApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    FixtureRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:FixtureRoot withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("PVX_TEST_ROOT", FixtureRoot.fileSystemRepresentation, 1);
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    Host = [UIViewController new]; Host.view.backgroundColor = UIColor.whiteColor;
    self.window.rootViewController = Host; [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self runTest]; });
    return YES;
}
- (void)runTest {
    TestWeb = [[PVXFixtureWeb alloc] initWithFrame:CGRectMake(0,0,32,32)];
    [Host.view addSubview:TestWeb];
    PVXSetCollectionWebView(TestWeb);
    NSDictionary *candidate = @{@"kind":@"image", @"url":@"https://fixture.invalid/photo.png?secret=private", @"page":@"https://fixture.invalid/page", @"title":@"真实图片"};
    PVXSubmitMedia(candidate, ^(NSDictionary *receipt, NSString *error) {
        NSCAssert(receipt && !error, @"production Collection writes binary inbox");
        NSArray *pending = PVXReadVideoTasks();
        NSCAssert(pending.count == 1 && [pending[0][@"state"] isEqual:@"submitted"], @"production reader sees inbox pending");
        NSCAssert(![pending.description containsString:@"private"], @"no request secrets in task rows");
        [self prepareReady:receipt[@"id"]];
    });
}
- (void)prepareReady:(NSString *)uuid {
    NSString *path = PVXPath([NSString stringWithFormat:@"image-media/%@.original", uuid]);
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(32,32), YES, 1);
    [UIColor.redColor setFill]; UIRectFill(CGRectMake(0,0,32,32));
    NSData *png = UIImagePNGRepresentation(UIGraphicsGetImageFromCurrentImageContext());
    UIGraphicsEndImageContext(); [png writeToFile:path atomically:YES];
    NSDictionary *task = @{@"id":uuid, @"state":@"ready", @"title":@"真实图片", @"kind":@"image"};
    NSCAssert(PVXAtomic(task, PVXPath([NSString stringWithFormat:@"image-tasks/%@.plist", uuid]), nil), @"snapshot");
    NSCAssert(PVXReadVideoTasks().count == 1 && [PVXReadVideoTasks()[0][@"state"] isEqual:@"ready"], @"snapshot supersedes pending");
    PVXUpdateTaskMetadata(@[task], @"title", @"改名图片");
    PVXUpdateTaskMetadata(@[task], @"tags", @"旅行,测试");
    PVXUpdateTaskMetadata(@[task], @"folder", @"旅行");
    NSDictionary *merged = PVXReadVideoTasks()[0];
    NSCAssert([merged[@"title"] isEqual:@"改名图片"] && [merged[@"tags"] isEqual:@"旅行,测试"] && [merged[@"folder"] isEqual:@"旅行"], @"persistent metadata merged");
    NSCAssert([PVXTaskLocalPath(merged) containsString:@"/files/旅行/"] && PVXRegular(path), @"real organized copy retains source");
    PVXExportTasks(@[merged], Host.view);
    [self awaitShare:0 source:PVXTaskLocalPath(merged) task:merged];
}
- (void)awaitShare:(NSUInteger)attempt source:(NSString *)source task:(NSDictionary *)task {
    if (!PVXShareSessions.count) {
        NSCAssert(attempt < 50 && !AlertCount, @"share must present, not fail silently");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC/10), dispatch_get_main_queue(), ^{ [self awaitShare:attempt+1 source:source task:task]; });
        return;
    }
    PVXShareSession *session = PVXShareSessions.anyObject;
    UIActivityViewController *controller = session.controller;
    NSCAssert([Host.presentedViewController isEqual:controller], @"native system activity sheet presented");
    NSCAssert([NSFileManager.defaultManager fileExistsAtPath:session.directory], @"staging retained while sheet active");
    NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:session.directory error:nil];
    NSString *staged = [session.directory stringByAppendingPathComponent:files.firstObject];
    NSCAssert([staged.pathExtension isEqual:@"png"], @"ImageIO actual extension");
    NSCAssert([[NSData dataWithContentsOfFile:source] isEqual:[NSData dataWithContentsOfFile:staged]], @"real staged bytes");
    struct stat originalStat, stagedStat;
    stat(source.fileSystemRepresentation, &originalStat); stat(staged.fileSystemRepresentation, &stagedStat);
    NSCAssert(originalStat.st_ino != stagedStat.st_ino && !(stagedStat.st_mode & 0222), @"independent read-only snapshot");
    PVXShareItem *item = [PVXShareItem new]; item.url = [NSURL fileURLWithPath:staged]; item.image = [UIImage imageWithContentsOfFile:staged]; item.uti = UTTypePNG.identifier;
    NSCAssert([[item activityViewController:controller itemForActivityType:UIActivityTypeSaveToCameraRoll] isKindOfClass:UIImage.class], @"Photos receives UIImage");
    NSCAssert([[item activityViewController:controller itemForActivityType:@"com.apple.CloudDocsUI.AddToiCloudDrive"] isKindOfClass:NSURL.class], @"Files receives typed real URL");
    if (controller.popoverPresentationController) NSCAssert(controller.popoverPresentationController.sourceView != nil, @"safe iPad anchor");
    NSString *directory = session.directory;
    controller.completionWithItemsHandler(nil, NO, nil, nil);
    NSCAssert(![NSFileManager.defaultManager fileExistsAtPath:directory] && !PVXShareSessions.count, @"cancel completion cleans staging");
    [Host dismissViewControllerAnimated:NO completion:^{
        PVXDeleteTasks(@[task], ^(NSString *error) { NSCAssert(!error, @"image delete queued"); });
        NSCAssert(!PVXRegular(source) && !PVXMetadata(task[@"id"]).count, @"organizer cleaned only after queue");
        NSString *original = PVXPath([NSString stringWithFormat:@"image-media/%@.original", task[@"id"]]);
        NSCAssert(PVXRegular(original), @"worker source retained until worker handles command");
        NSArray *commands = [NSFileManager.defaultManager contentsOfDirectoryAtPath:PVXPath(@"plus-image-control") error:nil];
        NSDictionary *command = PVXPlist([PVXPath(@"plus-image-control") stringByAppendingPathComponent:commands.firstObject]);
        NSCAssert([command[@"target"] isEqual:task[@"id"]], @"exact image command target");
        [NSFileManager.defaultManager removeItemAtPath:original error:nil];
        NSDictionary *tombstone = @{@"id":task[@"id"], @"state":@"deleted"};
        PVXAtomic(tombstone, PVXPath([NSString stringWithFormat:@"image-tasks/%@.plist", task[@"id"]]), nil);
        NSCAssert(!PVXReadVideoTasks().count, @"deleted tombstone suppresses still-present inbox");
        PVXExportTasks(@[task], Host.view);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSCAssert(AlertCount == 1 && !PVXShareSessions.count, @"missing original visibly fails");
            NSString *result = @"PASS UIKit activity presentation, ImageIO PNG, real isolated staging, Photos UIImage, Files URL, iPad anchor, cancellation cleanup, missing-file alert\n";
            [result writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/export-beta3-ui-result.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSLog(@"%@", result);
        });
    }];
}
@end
int main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(PVXExportTestApp.class)); } }

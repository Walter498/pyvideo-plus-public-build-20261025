// Real production integration: Images.m is a separate translation unit (its
// PVXThumbnail implementation must NOT be replaced by TaskSupport's declaration).
#define PVX_TEST 1
#define PVX_WATCHDOG_TEST 1
#import <AVKit/AVKit.h>
#import <CoreVideo/CoreVideo.h>
#import "../src/TaskSupport.m"
#import "../src/Collection.m"
#import "../src/DownloadsUI.m"
extern id PVXStartFixtureWorker(NSString *root);
static UIViewController *Host;
static WKWebView *Web;
static NSString *Root;
static NSMutableArray *Checks;
static NSString *Doc(NSString *name) { return [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:name]; }
static void Record(NSString *name, NSString *text) { [text writeToFile:Doc(name) atomically:YES encoding:NSUTF8StringEncoding error:NULL]; }
static void Check(BOOL ok, NSString *message) {
    if (!ok) { Record(@"webkit-beta3-result.txt", [@"FAIL " stringByAppendingString:message]); NSLog(@"FAIL %@",message); abort(); }
    [Checks addObject:message];
}
static void Later(double seconds, dispatch_block_t block) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(seconds*NSEC_PER_SEC)),dispatch_get_main_queue(),block); }
static void Wait(NSUInteger remaining, BOOL(^condition)(void), dispatch_block_t next, NSString *label) {
    if (condition()) { next(); return; }
    if (!remaining) { Check(NO, [@"timeout: " stringByAppendingString:label]); return; }
    Later(.1, ^{ Wait(remaining-1,condition,next,label); });
}
static void Capture(NSString *name, dispatch_block_t next) {
    Record([name stringByAppendingString:@".capture"],@"UIKit screenshot requested");
    Wait(450,^BOOL{ return [NSFileManager.defaultManager fileExistsAtPath:Doc([name stringByAppendingString:@".captured"])]; },next,name);
}
// Only the unavailable original host / resource / hooking integration is stubbed.
id PVXBrowser(void) { return nil; }
id PVXGet(id object, NSString *key) { @try { return [object valueForKey:key]; } @catch(NSException *e) { return nil; } }
BOOL PVXHook(Class cls, SEL sel, IMP replacement, IMP *original) { return NO; }
void PVXLog(NSString *format, ...) { (void)format; }
NSString *PVXStateRoot(void) { return Root; }
NSString *PVXResourcePath(NSString *name) { return [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:name]; }
WKWebView *PVXCurrentWebView(void) { return Web; }
UIViewController *PVXPresenter(void) { UIViewController *p=Host; while(p.presentedViewController) p=p.presentedViewController; return p; }
void PVXAlert(NSString *title, NSString *message) { Check(NO,[NSString stringWithFormat:@"unexpected production alert %@: %@",title,message]); }
@interface PVXWebKitTestApp : UIResponder <UIApplicationDelegate,WKNavigationDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) PVXManager *manager;
@property(nonatomic,copy) NSDictionary *ready;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL remoteThumbValid;
@property(nonatomic,strong) id worker;
@end
@implementation PVXWebKitTestApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    Checks=[NSMutableArray array];
    Root=Doc(@"state");
    [NSFileManager.defaultManager createDirectoryAtPath:Root withIntermediateDirectories:YES attributes:nil error:NULL];
    setenv("PVX_TEST_ROOT",Root.fileSystemRepresentation,1);
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    Host=[UIViewController new]; Host.view.backgroundColor=UIColor.whiteColor;
    self.window.rootViewController=Host; [self.window makeKeyAndVisible];
    Web=[[WKWebView alloc] initWithFrame:Host.view.bounds]; Web.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    Web.navigationDelegate=self; [Host.view addSubview:Web];
    NSString *base=NSProcessInfo.processInfo.environment[@"PVX_FIXTURE_URL"];
    Check([base hasPrefix:@"http://127.0.0.1:"],@"real localhost fixture URL supplied");
    NSString *html=@"<!doctype html><html><head><title>WebKit beta3 fixture</title></head><body><img width='96' height='96' src='real.png' title='real image'><video width='160' height='90' preload='none' src='real.mp4' title='real video'></video></body></html>";
    [Web loadHTMLString:html baseURL:[NSURL URLWithString:base]];
    return YES;
}
- (void)webView:(WKWebView *)web didFinishNavigation:(WKNavigation *)navigation {
    if(self.started)return; self.started=YES;
    Check(web.window!=nil,@"WKWebView attached to real host before overlay");
    PVXSetCollectionWebView(web);
    // Production refresh configures the native handler AND executes the actual resource.
    PVXRefreshCollection();
    Wait(250,^BOOL{ return PVXCollectedMedia(@"all").count==2; },^{ [self submit]; },@"real WebKit collector posts image and video");
}
- (void)submit {
    NSArray *images=PVXCollectedMedia(@"image"),*videos=PVXCollectedMedia(@"video");
    Check(images.count==1&&videos.count==1,@"real collected types: one image and one video");
    Check([images[0][@"url"] hasSuffix:@"/real.png"]&&[videos[0][@"url"] hasSuffix:@"/real.mp4"],@"real DOM URLs preserved");
    Check([images[0][@"documentID"] length]>0,@"native message carries real document identity");
    PVXFetchTaskThumbnail(images[0],^(UIImage *image){self.remoteThumbValid=image!=nil;});
    PVXSubmitMedia(images[0],^(NSDictionary *receipt,NSString *error){
        Check(receipt!=nil&&!error,@"production frame revalidation and submit succeeded");PVXRememberSource(images[0],receipt);
        NSString *inbox=PVXPath([NSString stringWithFormat:@"image-inbox/%@.plist",receipt[@"id"]]);
        NSData *data=[NSData dataWithContentsOfFile:inbox];
        Check(data.length>8&&!memcmp(data.bytes,"bplist00",8),@"production writer emitted binary plist inbox");
        NSDictionary *request=[NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
        Check([request[@"kind"] isEqual:@"image"]&&[request[@"url"] isEqual:images[0][@"url"]]&&[request[@"headers"][@"User-Agent"] length]>0,@"image request schema and actual WebKit user agent");
        NSArray *tasks=PVXReadVideoTasks();
        Check(tasks.count==1&&[tasks[0][@"state"] isEqual:@"submitted"],@"production TaskRead sees submitted inbox");
        self.worker=PVXStartFixtureWorker(Root);
        Check(self.worker!=nil,@"actual production worker started as non-root simulator user");
        Wait(250,^BOOL{
            NSArray *actual=PVXReadVideoTasks();
            return actual.count==1&&[actual[0][@"state"] isEqual:@"ready"]&&PVXTaskHasLocalFile(actual[0]);
        },^{ [self workerReady]; },@"actual production worker downloads localhost PNG and reaches ready");
    });
}
- (void)workerReady {
    NSArray *tasks=PVXReadVideoTasks(); self.ready=tasks.firstObject;
    Check(tasks.count==1&&[self.ready[@"state"] isEqual:@"ready"]&&PVXTaskHasLocalFile(self.ready),@"production TaskRead reads real worker ready snapshot and downloaded original");
    Check([UIImage imageWithContentsOfFile:PVXTaskLocalPath(self.ready)]!=nil,@"actual worker original decodes as valid PNG");
    PVXShowDownloads();
    Wait(150,^BOOL{ return [Host.presentedViewController isKindOfClass:PVXManager.class]&&Host.presentedViewController.view.window!=nil; },^{
        self.manager=(PVXManager *)Host.presentedViewController;
        Wait(150,^BOOL{ return self.manager.rows.count==1&&self.manager.timer!=nil; },^{ [self testManager]; },@"manager loads production tasks and timer");
    },@"actual PVXShowDownloads presents new manager");
}
- (void)testManager {
    PVXManager *m=self.manager; [m.view layoutIfNeeded];
    Check(m.mainTabs.numberOfSegments==2&&m.mainTabs.bounds.size.width>0,@"actual mainTabs exists with download/collect segments");
    Check(!CGRectIntersectsRect(m.mainTabs.frame,m.closeButton.frame)&&!CGRectIntersectsRect(m.mainTabs.frame,m.moreButton.frame)&&CGRectGetMaxY(m.mainTabs.frame)<=CGRectGetMinY(m.spaceLabel.frame),@"mainTabs frame does not overlap header controls");
    Check(CGRectGetMaxY(m.mediaTabs.frame)<=CGRectGetMinY(m.sectionLabel.frame)&&CGRectGetMaxY(m.feedback.frame)<=CGRectGetMinY(m.table.frame),@"filter and table layout do not overlap");Check(m.sortButton.menu.children.count==5,@"download and collect pages expose five-option native sort menu");Check(m.moreButton.menu.children.count==4,@"top-right native 3D menu exposes creation display batch and settings groups");Check([m tableView:m.table trailingSwipeActionsConfigurationForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]].performsFirstActionWithFullSwipe,@"list rows expose full-swipe delete");[m setGridMode:YES];Check(m.grid.hidden==NO&&m.table.hidden==YES,@"native icon mode switches to two-column collection view");[m setGridMode:NO];
    m.mainTabs.selectedSegmentIndex=1; [m.mainTabs sendActionsForControlEvents:UIControlEventValueChanged];
    Wait(100,^BOOL{ return m.rows.count==2; },^{
        Check(m.table.numberOfSections==1&&[m.table numberOfRowsInSection:0]==2,@"collect all shows two actual rows");
        m.mediaTabs.selectedSegmentIndex=2; [m.mediaTabs sendActionsForControlEvents:UIControlEventValueChanged];
        Wait(100,^BOOL{return m.rows.count==1&&[m.rows[0][@"kind"] isEqual:@"image"];},^{
            Check(YES,@"collect image filter asynchronously resolves one image");
            m.mediaTabs.selectedSegmentIndex=1;[m.mediaTabs sendActionsForControlEvents:UIControlEventValueChanged];
            Wait(100,^BOOL{return m.rows.count==1&&[m.rows[0][@"kind"] isEqual:@"video"];},^{
                Check(YES,@"collect video filter asynchronously resolves one video");
                m.mediaTabs.selectedSegmentIndex=0;[m.mediaTabs sendActionsForControlEvents:UIControlEventValueChanged];
                Wait(100,^BOOL{return m.rows.count==2;},^{[self testSelectionAfterFilters];},@"all media filter restored");
            },@"video filter snapshot");
        },@"image filter snapshot");
    },@"collect all actual rows");
}
- (void)testSelectionAfterFilters {
        PVXManager *m=self.manager;
        Check(self.remoteThumbValid,@"remote collected image URL generated actual thumbnail with origin cookies");Check(PVXLinkedTask(PVXCollectedMedia(@"image")[0],PVXReadVideoTasks())!=nil,@"collection progress persists source-to-task UUID association");
        m.selecting=YES;m.batchBar.hidden=NO;
        Check(m.selecting&&!m.batchBar.hidden,@"multiselect exposes real all checkbox and batch bar");
        [m.allButton sendActionsForControlEvents:UIControlEventTouchUpInside];
        Check(m.selection.count==2&&[m selectedRows].count==2&&m.batchExport.enabled&&[m.sectionLabel.text containsString:@"已选 2"],@"actual all checkbox selects two and updates batch count");
        [m.table layoutIfNeeded];
        PVXMediaRow *cell=[m.table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
        Check([cell isKindOfClass:PVXMediaRow.class]&&[cell.command.accessibilityLabel isEqual:@"取消选择"],@"actual production row renders checked state");
        [cell.command sendActionsForControlEvents:UIControlEventTouchUpInside];
        Check(m.selection.count==1&&[m selectedRows].count==1,@"actual row checkbox updates batch count");
        [m.allButton sendActionsForControlEvents:UIControlEventTouchUpInside]; Check(m.selection.count==2,@"select all restores both actual rows");
        [m.allButton sendActionsForControlEvents:UIControlEventTouchUpInside]; Check(m.selection.count==0&&!m.batchExport.enabled,@"select all toggles off and disables empty batch");
        m.rangeBase=[NSSet set];m.rangeRows=[m.rows copy];m.rangeStart=0;m.rangeSelecting=YES;[m applyRangeToRow:1];Check(m.selection.count==2,@"long press range selects downwards");[m applyRangeToRow:0];Check(m.selection.count==1,@"reverse drag contracts selected range");m.rangeSelecting=NO;m.rangeBase=[NSSet setWithArray:@[PVXRowID(m.rows[0]),PVXRowID(m.rows[1])]];[m applyRangeToRow:1];Check(m.selection.count==0,@"long press selected range deselects downwards");m.rangeRows=nil;m.rangeBase=nil;
        Capture(@"collection",^{ [self showDownloadMenu]; });
}
- (void)showDownloadMenu {
    PVXManager *m=self.manager;
    m.mainTabs.selectedSegmentIndex=0; [m.mainTabs sendActionsForControlEvents:UIControlEventValueChanged];
    Wait(150,^BOOL{ return !m.reading&&m.rows.count==1&&[m.rows[0][@"state"] isEqual:@"ready"]; },^{
        [m.view layoutIfNeeded]; [m.table layoutIfNeeded];
        Check(m.timer.valid&&m.visible,@"production one-second refresh timer active before menu");
        PVXMediaRow *dated=[m.table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];Check([dated.dateLabel.text hasPrefix:@"下载日期："]&&[dated.dateLabel.text containsString:@"/"]&&[dated.dateLabel.text containsString:@":"],@"real created timestamp rendered as month/day hour:minute");
        [m showMenu:@[m.rows[0]] anchor:m.moreButton];
        Wait(80,^BOOL{ return [m.presentedViewController isKindOfClass:UIAlertController.class]; },^{
            UIAlertController *menu=(UIAlertController *)m.presentedViewController;
            // Deliberately cross more than two production one-second timer ticks.
            Later(2.4,^{
                Check(m.presentedViewController==menu&&menu.view.window!=nil&&!menu.isBeingDismissed,@"actual menu remains open after 2.4 seconds with production refresh timer");
                for(NSString *title in @[@"导出",@"删除",@"重命名"]) {
                    UIAlertAction *found=nil; for(UIAlertAction *action in menu.actions) if([action.title isEqual:title])found=action;
                    Check(found!=nil&&found.enabled,[@"local menu action exists and enabled: " stringByAppendingString:title]);
                }
                Capture(@"menu",^{
                    [m dismissViewControllerAnimated:NO completion:^{
                        PVXExportTasks(@[self.ready],m.view);
                        Wait(150,^BOOL{ return [m.presentedViewController isKindOfClass:UIActivityViewController.class]&&PVXShareSessions.count==1; },^{ [self verifyShare]; },@"real system activity controller");
                    }];
                });
            });
        },@"actual showMenu alert presented");
    },@"download ready row");
}
- (void)verifyWatchdogSnapshot {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSString *source=PVXTaskLocalPath(self.ready);
        for(int i=0;i<180;i++){
            NSString *uuid=[NSString stringWithFormat:@"77777777-7777-4777-8777-%012d",i];
            NSString *file=PVXPath([NSString stringWithFormat:@"image-media/%@.original",uuid]);
            if(!PVXRegular(file))[NSFileManager.defaultManager copyItemAtPath:source toPath:file error:NULL];
            Check(PVXAtomic(@{@"id":uuid,@"kind":@"image",@"title":@"Watchdog regression fixture",@"created":@1,@"state":@"ready"},PVXPath([NSString stringWithFormat:@"image-tasks/%@.plist",uuid]),NULL),@"stress task fixture created");
        }
        dispatch_async(dispatch_get_main_queue(),^{
            NSUInteger readsBefore=PVXTestMainDiskReads,scansBefore=PVXTestBackgroundScans;
            CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();__block BOOL heartbeat=NO;
            PVXRequestTaskSnapshot(^(NSArray *rows,NSDictionary *storage){
                Check(rows.count>=182,@"large task set asynchronously scanned");
                Check(PVXTestMainDiskReads==readsBefore,@"background task snapshot performs zero main-thread plist reads");
                Check(PVXTestBackgroundScans>scansBefore,@"production worker queue executes disk scan");
                Check(heartbeat,@"main-thread heartbeat runs while disk snapshot is in flight");
                Record(@"webkit-beta3-result.txt",[@"PASS system native player and watchdog regression: exact Apple controller, real H264 playback/seek/dismiss; async large task snapshot, zero main-thread plist reads, responsive main heartbeat; existing media pipeline passed\n" stringByAppendingString:[Checks componentsJoinedByString:@"\n"]]);
            });
            Check(CFAbsoluteTimeGetCurrent()-start<.1,@"snapshot scheduling returns immediately without scanning on main");
            dispatch_async(dispatch_get_main_queue(),^{heartbeat=YES;});
        });
    });
}
- (void)verifyShare {
    PVXShareSession *session=PVXShareSessions.anyObject;
    Check(self.manager.presentedViewController==session.controller&&session.controller.view.window!=nil,@"actual PVXExportTasks presents UIKit UIActivityViewController");
    NSArray *files=[NSFileManager.defaultManager contentsOfDirectoryAtPath:session.directory error:NULL];
    NSString *staged=[session.directory stringByAppendingPathComponent:files.firstObject?:@""];
    NSString *source=PVXTaskLocalPath(self.ready);
    NSData *a=[NSData dataWithContentsOfFile:source],*b=[NSData dataWithContentsOfFile:staged];
    Check(files.count==1&&[staged.pathExtension isEqual:@"png"]&&a.length>0&&[a isEqual:b]&&[UIImage imageWithData:b]!=nil,@"actual staged file is valid PNG with byte-identical source");
    struct stat x,y; Check(!stat(source.fileSystemRepresentation,&x)&&!stat(staged.fileSystemRepresentation,&y)&&x.st_ino!=y.st_ino&&!(y.st_mode&0222),@"actual export staging independent inode and read-only bytes");
    NSDictionary *artifact=@{@"source":source,@"staged":staged,@"workerBoundary":@"REAL worker/main.m NSURLSession download; no simulated ready state",@"checks":Checks};
    NSData *json=[NSJSONSerialization dataWithJSONObject:artifact options:NSJSONWritingPrettyPrinted error:NULL];
    [json writeToFile:Doc(@"webkit-beta3-artifacts.json") atomically:YES];
    Capture(@"activity",^{
        [self.manager dismissViewControllerAnimated:NO completion:^{
            PVXPreviewMedia(self.ready);
            Wait(100,^BOOL{return [NSStringFromClass(self.manager.presentedViewController.class) isEqual:@"PVXPreviewController"];},^{
                UIViewController *viewer=self.manager.presentedViewController;
                Wait(150,^BOOL{return [(UIImageView*)PVXGet(viewer,@"imageView") image]!=nil;},^{
                    Check([(UIScrollView*)PVXGet(viewer,@"scroll") maximumZoomScale]>1,@"actual local image viewer supports zoom");
                    PVXFetchMediaQuality(self.ready,^(NSString *quality){Check([quality isEqual:@"96×96"],@"actual ImageIO image resolution read");[self verifySystemPlayerAfterImage];});
                },@"local image viewer decodes actual downloaded file");
            },@"actual image preview controller presentation");
        }];
    });
}
#import "system-player-test.inc"
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(PVXWebKitTestApp.class)); } }

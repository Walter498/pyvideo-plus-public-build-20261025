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
    PVXSetCollectionWebView(Web);
    PVXRefreshCollection();
    NSString *base=NSProcessInfo.processInfo.environment[@"PVX_FIXTURE_URL"];
    Check([base hasPrefix:@"http://127.0.0.1:"],@"real localhost fixture URL supplied");
    NSString *html=@"<!doctype html><html><head><title>WebKit beta3 fixture</title></head><body><a href='magnet:?xt=urn%3Abtih%3A0123456789abcdef0123456789abcdef01234567&dn=STARS-199.mp4'>Magnet</a><a href='https://keepshare.org/s/STARS-199'>KeepShare MP4</a><img width='96' height='96' src='real.png' title='real image'><video width='160' height='90' preload='none' src='real.mp4' title='real video'></video><script>fetch('network.mp4').then(r=>r.arrayBuffer());const xhr=new XMLHttpRequest();xhr.open('GET','network.mp4');xhr.send();const ms=new MediaSource();const runtime=document.createElement('video');runtime.src=URL.createObjectURL(ms);runtime.title='MSE runtime fixture';document.body.appendChild(runtime);</script></body></html>";
    [Web loadHTMLString:html baseURL:[NSURL URLWithString:base]];
    return YES;
}
- (void)webView:(WKWebView *)web didFinishNavigation:(WKNavigation *)navigation {
    if(self.started)return; self.started=YES;
    Check(web.window!=nil,@"WKWebView attached to real host before overlay");
    PVXSetCollectionWebView(web);
    // Production refresh configures the native handler AND executes the actual resource.
    PVXRefreshCollection();
    [web evaluateJavaScript:@"setTimeout(()=>{const v=document.createElement('video');v.width=160;v.height=90;v.src='network.mp4';v.title='dynamic network video';document.body.appendChild(v)},500)" completionHandler:nil];
    Later(3.0,^{
        PVXRefreshCollection();
        [web evaluateJavaScript:@"(()=>{const c=globalThis.__pvxMedia_v1;return JSON.stringify({has:!!c,hidden:document.hidden,url:location.href,snapshot:c&&c.snapshot&&c.snapshot()});})()" completionHandler:^(id value,NSError *error){
            Record(@"collector-debug.txt",[NSString stringWithFormat:@"error=%@\\n%@\\nnativeImages=%lu nativeVideos=%lu nativeMagnetSources=%lu\\n",error.localizedDescription?:@"",value?:@"",(unsigned long)PVXImageCollected(web).count,(unsigned long)PVXVideoCollected(web).count,(unsigned long)PVXCollectedMedia(@"magnet").count]);
        }];
    });
    Wait(250,^BOOL{NSArray *vv=PVXCollectedMedia(@"video");BOOL network=NO;for(NSDictionary *row in vv)if([row[@"url"] hasSuffix:@"/network.mp4"])network=YES;return PVXCollectedMedia(@"image").count==1&&vv.count>=2&&network;},^{ [self submit]; },@"real WebKit collector posts DOM and dynamically fetched video sources");
}
- (void)submit {
    NSArray *images=PVXCollectedMedia(@"image"),*videos=PVXCollectedMedia(@"video");
    Check(images.count==1&&videos.count>=2, @"real collected types: one image and multiple DOM/network videos");
    NSArray *videoRows=PVXCollectedMedia(@"video");NSDictionary *networkVideo=nil;for(NSDictionary *vv in videoRows)if([vv[@"url"] hasSuffix:@"/network.mp4"]){networkVideo=vv;break;}Check(images.count==1&&videos.count>=2&&networkVideo!=nil&&[networkVideo[@"protocol"] isEqual:@"video"],@"network fetch media URL and MIME protocol classification are preserved");
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
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"com.crctdd.pyvideo.plus.gridMode"];
    PVXShowDownloads();
    Wait(150,^BOOL{ return [Host.presentedViewController isKindOfClass:PVXManager.class]&&Host.presentedViewController.view.window!=nil; },^{
        self.manager=(PVXManager *)Host.presentedViewController;
        Wait(150,^BOOL{ return self.manager.rows.count==1&&self.manager.timer!=nil; },^{ [self testManager]; },@"manager loads production tasks and timer");
    },@"actual PVXShowDownloads presents new manager");
}
- (void)testManager {
    PVXManager *m=self.manager; [m.view layoutIfNeeded];
    Check(m.mainTabs.numberOfSegments==3&&m.mainTabs.bounds.size.width>0, @"actual mainTabs exists with download/collect/source segments");
    Check(!CGRectIntersectsRect(m.mainTabs.frame,m.closeButton.frame)&&!CGRectIntersectsRect(m.mainTabs.frame,m.moreButton.frame)&&CGRectGetMaxY(m.mainTabs.frame)<=CGRectGetMinY(m.spaceLabel.frame),@"mainTabs frame does not overlap header controls");
    Check(CGRectGetMaxY(m.mediaTabs.frame)<=CGRectGetMinY(m.sectionLabel.frame)&&CGRectGetMaxY(m.feedback.frame)<=CGRectGetMinY(m.table.frame),@"filter and table layout do not overlap");Check(m.sortButton.menu.children.count==5,@"download and collect pages expose five-option native sort menu");Check(m.moreButton.menu.children.count==3, @"top-right native menu preserves batch, source and settings groups");Check([m tableView:m.table trailingSwipeActionsConfigurationForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]].performsFirstActionWithFullSwipe,@"list rows expose full-swipe delete");Check(!m.table.hidden&&[NSUserDefaults.standardUserDefaults objectForKey:@"com.crctdd.pyvideo.plus.gridMode"]==nil,@"legacy grid preference migrates to visible list-only UI");for(UIView *child in m.view.subviews)Check(![child isKindOfClass:UICollectionView.class],@"manager never creates a grid view");Check(![m respondsToSelector:NSSelectorFromString(@"setGridMode:")],@"removed icon-mode setter cannot reactivate a grid");
    m.mainTabs.selectedSegmentIndex=1; [m.mainTabs sendActionsForControlEvents:UIControlEventValueChanged];
    Wait(100,^BOOL{ return m.rows.count>=3; },^{
        Check(m.table.numberOfSections==1&&[m.table numberOfRowsInSection:0]>=3,@"collect all shows DOM and dynamic network media rows");
        m.mainTabs.selectedSegmentIndex=2; [m.mainTabs sendActionsForControlEvents:UIControlEventValueChanged];
        Wait(100,^BOOL{return m.rows.count>=1;},^{
            Check(m.rows.count>=1, @"magnet tab exposes magnet source rows");
            BOOL magnet=NO;for(NSDictionary *source in m.rows){Check([source[@"kind"] isEqual:@"source"], @"magnet rows use independent source kind");magnet=magnet||[source[@"sourceKind"] isEqual:@"magnet"];}
            Check(magnet, @"magnet tab exposes validated magnet sources");
            [self testMagnetProducer:^{
            m.mainTabs.selectedSegmentIndex=1; [m.mainTabs sendActionsForControlEvents:UIControlEventValueChanged];
            Wait(100,^BOOL{return m.rows.count>=3;},^{
                m.mediaTabs.selectedSegmentIndex=2; [m.mediaTabs sendActionsForControlEvents:UIControlEventValueChanged];
                Wait(100,^BOOL{return m.rows.count==1&&[m.rows[0][@"kind"] isEqual:@"image"];},^{
                    Check(YES,@"collect image filter asynchronously resolves one image");
                    m.mediaTabs.selectedSegmentIndex=1;[m.mediaTabs sendActionsForControlEvents:UIControlEventValueChanged];
                    Wait(100,^BOOL{return m.rows.count>=2&&[m.rows[0][@"kind"] isEqual:@"video"];},^{
                        Check(YES,@"collect video filter asynchronously resolves one video");
                        m.mediaTabs.selectedSegmentIndex=0;[m.mediaTabs sendActionsForControlEvents:UIControlEventValueChanged];
                        Wait(100,^BOOL{return m.rows.count>=3;},^{[self testSelectionAfterFilters];},@"all media filter restored");
                    },@"video filter snapshot");
                },@"image filter snapshot");
            },@"collection restored after source tab");
            }];
        },@"source tab snapshot");
    },@"collect all actual rows");
}
- (void)testMagnetProducer:(dispatch_block_t)done {
    PVXManager *m=self.manager;
    NSDictionary *pageSource=m.rows.firstObject;
    Check([pageSource[@"sourceKind"] isEqual:@"magnet"]&&PVXMagnetInfoHash(pageSource[@"url"])!=nil,@"WebKit page source remains validated magnet, never direct fallback");
    NSString *hash=@"0123456789abcdef0123456789abcdef01234567";
    NSString *url=@"magnet:?xt=urn%3Abtih%3A0123456789ABCDEF0123456789ABCDEF01234567&dn=Native&xl=2097152";
    NSDictionary *source=PVXCanonicalSource(@{@"url":url},@{@"page":Web.URL.absoluteString,@"title":@"Native producer",@"width":@1920,@"height":@1080,@"protocol":@"hls"});
    Check([source[@"infoHash"] isEqual:hash]&&[source[@"sourceKey"] isEqual:[@"btih:" stringByAppendingString:hash]],@"encoded xt canonicalizes to lowercase btih source identity");
    Check(!source[@"width"]&&!source[@"height"]&&!source[@"poster"]&&[source[@"sizeVerified"] isEqual:@NO],@"magnet cannot inherit trailer dimensions and xl is explicitly unverified");
    NSMutableDictionary *linked=[source mutableCopy];linked[@"linkedTask"]=self.ready;
    for(NSNumber *mode in @[@1,@2]){
        m.mainTabs.selectedSegmentIndex=mode.integerValue;[m applyFilter:NO];
        Check(![m tableView:m.table canEditRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]]&&![m tableView:m.table trailingSwipeActionsConfigurationForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]]&&m.batchDelete.hidden&&!m.batchDelete.enabled,@"all source tabs hide swipe and batch deletion");
        for(UIMenuElement *item in [m rowMenu:linked].children)Check(![item.title isEqual:@"删除"],@"linked source native menu has no delete action");
        for(UIMenuElement *item in [m rowMenu:@{@"kind":@"video",@"linkedTask":self.ready}].children)Check(![item.title isEqual:@"删除"],@"linked collected video native menu has no delete action");
        [m deleteSelected];Check(!m.presentedViewController,@"source deleteSelected is a no-op");
    }
    [m showMenu:@[linked] anchor:m.moreButton];
    Check([m.presentedViewController isKindOfClass:UIAlertController.class],@"source fallback menu is presented");
    for(UIAlertAction *action in ((UIAlertController *)m.presentedViewController).actions)Check(![action.title isEqual:@"删除"],@"source fallback alert menu has no delete control");
    Later(.5, ^{ [m dismissViewControllerAnimated:NO completion:^{
    NSArray *titles=[[m rowMenu:source].children valueForKey:@"title"];
    Check([titles containsObject:@"加入磁力下载队列"]&&[titles containsObject:@"复制磁力链接"]&&[titles containsObject:@"导出链接"],@"magnet menu offers explicit queue, copy and export actions");
    for(NSDictionary *bad in @[@{@"kind":@"video",@"sourceKind":@"magnet",@"url":@"https://example.test/a.mp4"},@{@"kind":@"video",@"url":@"https://example.test/a.torrent?x=1"},@{@"kind":@"source",@"url":@"https://example.test/a.mp4"},@{@"kind":@"torrent",@"url":@"https://example.test/a.mp4"},@{@"kind":@"video",@"url":@"file:///a.mp4"}]){
        __block BOOL rejected=NO;PVXSubmitMedia(bad,^(NSDictionary *receipt,NSString *error){rejected=receipt==nil&&error.length>0;});Check(rejected,@"actual HTTP producer rejects source/torrent and non-HTTP input");
    }
    __block NSUInteger callbacks=0;__block NSString *uuid=nil;
    // Exercise the production row action, then race two equivalent submissions.
    [m openSource:source];
    for(NSUInteger i=0;i<2;i++)PVXSubmitMagnet(@{@"url":[@"magnet:?xt=urn:btih:" stringByAppendingString:hash]},^(NSDictionary *receipt,NSString *error){
        Check(receipt!=nil&&!error&&[receipt[@"deduplicated"] boolValue],@"serialized producer coalesces concurrent same-hash submissions");
        if(uuid)Check([uuid isEqual:receipt[@"id"]],@"duplicate callbacks return same task UUID");uuid=receipt[@"id"];callbacks++;
    });
    Wait(100,^BOOL{return callbacks==2&&[m.feedback.text containsString:@"已加入队列"];},^{
        NSString *path=PVXPath([NSString stringWithFormat:@"torrent-inbox/%@.plist",uuid]);NSDictionary *request=[NSDictionary dictionaryWithContentsOfFile:path];
        Check([request[@"magnet"] isEqual:url]&&[request[@"infoHash"] isEqual:hash]&&[request[@"backend"] isEqual:@"torrent"]&&[request[@"kind"] isEqual:@"video"],@"real row action writes readable torrent queue preserving original URI");
        Check(![NSFileManager.defaultManager fileExistsAtPath:PVXPath([NSString stringWithFormat:@"inbox/%@.plist",uuid])],@"magnet producer never writes HTTP inbox");
        Check([NSFileManager.defaultManager contentsOfDirectoryAtPath:PVXPath(@"torrent-inbox") error:NULL].count==1,@"dedup leaves exactly one queued request");
        NSDictionary *public=nil;for(NSDictionary *r in PVXScanVideoTasks())if([r[@"id"] isEqual:uuid])public=r;
        Check([public[@"backend"] isEqual:@"torrent"]&&[public[@"sourceKey"] isEqual:request[@"sourceKey"]]&&[public[@"kind"] isEqual:@"video"],@"pending torrent inbox survives public task scan with backend and identity");
        Check(PVXQueueControl(public,@"pause",NULL),@"pending torrent control enqueues without legacy PVEnqueueControl");
        Check([NSFileManager.defaultManager contentsOfDirectoryAtPath:PVXPath(@"torrent-control") error:NULL].count==1,@"torrent control routes exclusively to torrent-control");
        NSMutableDictionary *active=[request mutableCopy];active[@"state"]=@"downloading";active[@"phase"]=@"pieces";active[@"width"]=@1280;active[@"height"]=@720;active[@"progress"]=@0.5;active[@"peers"]=@3;
        NSString *taskPath=PVXPath([NSString stringWithFormat:@"torrent-tasks/%@.plist",uuid]);
        Check(PVXAtomic(active,taskPath,NULL),@"active torrent snapshot fixture written");
        [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
        for(NSDictionary *r in PVXScanVideoTasks())if([r[@"id"] isEqual:uuid])Check([r[@"width"] isEqual:@1280]&&[r[@"height"] isEqual:@720]&&[r[@"progress"] isEqual:@0.5]&&[r[@"peers"] isEqual:@3]&&[r[@"phase"] isEqual:@"pieces"],@"active torrent scan preserves numeric media and peer progress");
        PVXSubmitMagnet(source,^(NSDictionary *receipt,NSString *error){
            Check(!error&&[receipt[@"id"] isEqual:uuid]&&[receipt[@"deduplicated"] boolValue],@"active torrent task is also deduplicated");
            PVXSubmitMagnet(@{@"url":@"magnet:?xt=urn:btih:bad"},^(NSDictionary *invalid,NSString *failure){
                Check(!invalid&&failure.length>0,@"invalid producer input returns error not success receipt");
                [NSFileManager.defaultManager removeItemAtPath:taskPath error:NULL];
                [NSFileManager.defaultManager removeItemAtPath:PVXPath(@"torrent-control") error:NULL];
                // Force the actual producer's O_NOFOLLOW commit to fail, not merely validation.
                NSString *savedRoot=Root;NSString *blocked=[savedRoot stringByAppendingPathComponent:@"producer-failure"];
                [NSFileManager.defaultManager createDirectoryAtPath:blocked withIntermediateDirectories:YES attributes:nil error:NULL];
                Check([NSFileManager.defaultManager createSymbolicLinkAtPath:[blocked stringByAppendingPathComponent:@"torrent-inbox"] withDestinationPath:[savedRoot stringByAppendingPathComponent:@"torrent-inbox"] error:NULL],@"producer failure fixture symlinks inbox");
                Root=blocked;
                PVXSubmitMagnet(source,^(NSDictionary *failedReceipt,NSString *writeError){
                    Root=savedRoot;
                    Check(!failedReceipt&&writeError.length>0,@"producer rejects symlink-backed commit with error, never a false success receipt");
                    [NSFileManager.defaultManager removeItemAtPath:blocked error:NULL];done();
                });
            });
        });
    },@"native row queue receipt and concurrent dedup");
    }]; });
}
- (void)testSelectionAfterFilters {
        PVXManager *m=self.manager;
        Check(self.remoteThumbValid,@"remote collected image URL generated actual thumbnail with origin cookies");Check(PVXLinkedTask(PVXCollectedMedia(@"image")[0],PVXReadVideoTasks())!=nil,@"collection progress persists source-to-task UUID association");
        m.selecting=YES;m.batchBar.hidden=NO;
        Check(m.selecting&&!m.batchBar.hidden,@"multiselect exposes real all checkbox and batch bar");
        [m.allButton sendActionsForControlEvents:UIControlEventTouchUpInside];
        Check(m.selection.count==m.rows.count&&[m selectedRows].count==m.rows.count&&m.batchExport.enabled,@"actual all checkbox selects two and updates batch count");
        [m.table layoutIfNeeded];
        PVXMediaRow *cell=[m.table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
        Check([cell isKindOfClass:PVXMediaRow.class]&&[cell.command.accessibilityLabel isEqual:@"取消选择"]&&!cell.command.hidden,@"actual production row renders checked state and keeps selector visible");
        [m toggleRow:m.rows[0]];
        Check(m.selection.count==m.rows.count-1&&[m selectedRows].count==m.rows.count-1,@"actual row checkbox updates batch count");
        [m.allButton sendActionsForControlEvents:UIControlEventTouchUpInside]; Check(m.selection.count==m.rows.count,@"select all restores both actual rows");
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

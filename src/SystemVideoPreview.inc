// Included only by MediaPreview.m. AVPlayerViewController is instantiated
// directly; no subclass, custom AVPlayerLayer, transport buttons or PiP owner.
@interface PVXSystemVideoSession : NSObject <AVPlayerViewControllerDelegate>
@property(nonatomic,strong) AVPlayerViewController *controller;
@property(nonatomic,strong) AVPlayerItem *item;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,copy) NSString *previousCategory,*previousMode;
@property(nonatomic) AVAudioSessionCategoryOptions previousOptions;
@property(nonatomic) BOOL audioActive,observing,started,pipStarting,pipActive,restoring,finished;
@property(nonatomic) NSTimeInterval cleanupAfter;
- (void)finish;
@end
static NSMutableSet<PVXSystemVideoSession*> *PVXNativeVideos;
static char PVXNativeItemContext;
@implementation PVXSystemVideoSession
- (void)finish {
    if(self.finished)return;
    self.finished=YES;
    [self.timer invalidate];self.timer=nil;
    if(self.observing){[self.item removeObserver:self forKeyPath:@"status" context:&PVXNativeItemContext];self.observing=NO;}
    [self.controller.player pause];self.controller.player=nil;self.controller.delegate=nil;
    self.item=nil;self.controller=nil;
    if(self.audioActive){AVAudioSession *audio=AVAudioSession.sharedInstance;[audio setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];if(self.previousCategory.length)[audio setCategory:self.previousCategory mode:self.previousMode options:self.previousOptions error:nil];self.audioActive=NO;}
    [PVXNativeVideos removeObject:self];
}
- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context {
    if(context!=&PVXNativeItemContext){[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];return;}
    if(self.item.status==AVPlayerItemStatusFailed){__weak typeof(self)weak=self;dispatch_async(dispatch_get_main_queue(),^{if(!weak.finished&&weak.controller.presentingViewController)PVXAlert(@"视频播放失败",weak.item.error.localizedDescription?:@"系统无法读取该视频，请检查文件或原始链接。");});}
}
- (void)playerViewControllerWillStartPictureInPicture:(AVPlayerViewController*)controller {self.pipStarting=YES;}
- (void)playerViewControllerDidStartPictureInPicture:(AVPlayerViewController*)controller {self.pipStarting=NO;self.pipActive=YES;}
- (void)playerViewController:(AVPlayerViewController*)controller failedToStartPictureInPictureWithError:(NSError*)error {self.pipStarting=NO;self.pipActive=NO;PVXAlert(@"画中画未启动",error.localizedDescription?:@"系统暂不支持此视频的画中画。");}
- (BOOL)playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart:(AVPlayerViewController*)controller {return YES;}
- (void)playerViewControllerDidStopPictureInPicture:(AVPlayerViewController*)controller {self.pipStarting=NO;self.pipActive=NO;self.cleanupAfter=NSDate.date.timeIntervalSince1970+2;}
- (void)playerViewController:(AVPlayerViewController*)controller restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void(^)(BOOL))completion {
    if(self.finished){completion(NO);return;}
    if(controller.presentingViewController&&controller.viewIfLoaded.window){completion(YES);return;}
    UIViewController *presenter=PVXPresenter();if(!presenter||presenter.isBeingPresented||presenter.isBeingDismissed){completion(NO);return;}
    self.restoring=YES;
    [presenter presentViewController:controller animated:YES completion:^{self.restoring=NO;completion(controller.viewIfLoaded.window!=nil);}];
}
- (void)playerViewController:(AVPlayerViewController*)controller willEndFullScreenPresentationWithAnimationCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    // The native Done button remains Apple's own. Clean only after an actual
    // dismissal, never when transitioning to system PiP or restoring its UI.
    __weak typeof(self)weak=self;
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){
        if(context.isCancelled)return;
        dispatch_async(dispatch_get_main_queue(),^{if(weak.started&&NSDate.date.timeIntervalSince1970>=weak.cleanupAfter&&!weak.pipActive&&!weak.pipStarting&&!weak.restoring&&!controller.presentingViewController&&!controller.viewIfLoaded.window)[weak finish];});
    }];
}
@end
static void PVXPresentSystemVideo(NSURL *url,NSDictionary *options) {
    UIViewController *presenter=PVXPresenter();
    if(!presenter||presenter.isBeingDismissed||presenter.isBeingPresented){PVXAlert(@"无法打开视频",@"当前页面正在切换，请稍后重试。");return;}
    if(PVXNativeVideos.count){PVXAlert(@"已有视频正在播放",@"请先关闭当前系统播放器或画中画，再打开另一段视频。");return;}
    PVXSystemVideoSession *session=[PVXSystemVideoSession new];
    AVAudioSession *audio=AVAudioSession.sharedInstance;
    session.previousCategory=audio.category;session.previousMode=audio.mode;session.previousOptions=audio.categoryOptions;
    NSError *error=nil;
    if(![audio setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeMoviePlayback options:0 error:&error]||![audio setActive:YES error:&error]){
        if(session.previousCategory.length)[audio setCategory:session.previousCategory mode:session.previousMode options:session.previousOptions error:nil];
        PVXAlert(@"无法播放视频",error.localizedDescription?:@"无法启用系统音频会话。");return;
    }
    session.audioActive=YES;
    session.item=[AVPlayerItem playerItemWithAsset:[AVURLAsset URLAssetWithURL:url options:options]];
    // This exact Apple class supplies all visible video UI and system controls.
    AVPlayerViewController *controller=[[AVPlayerViewController alloc] init];
    controller.player=[AVPlayer playerWithPlayerItem:session.item];
    controller.showsPlaybackControls=YES;
    controller.allowsPictureInPicturePlayback=YES;
    controller.canStartPictureInPictureAutomaticallyFromInline=YES;
    controller.requiresLinearPlayback=NO;
    controller.videoGravity=AVLayerVideoGravityResizeAspect;
    controller.modalPresentationStyle=UIModalPresentationFullScreen;
    controller.delegate=session;session.controller=controller;
    if(!PVXNativeVideos)PVXNativeVideos=[NSMutableSet set];
    [PVXNativeVideos addObject:session];
    session.observing=YES;
    [session.item addObserver:session forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:&PVXNativeItemContext];
    session.cleanupAfter=NSDate.date.timeIntervalSince1970+5;
    __weak PVXSystemVideoSession *weak=session;
    session.timer=[NSTimer timerWithTimeInterval:.5 repeats:YES block:^(NSTimer *timer){
        PVXSystemVideoSession *s=weak;if(!s||NSDate.date.timeIntervalSince1970<s.cleanupAfter)return;
        if(!s.pipStarting&&!s.pipActive&&!s.restoring&&!s.controller.isBeingPresented&&!s.controller.isBeingDismissed&&!s.controller.presentingViewController&&!s.controller.viewIfLoaded.window)[s finish];
    }];
    [NSRunLoop.mainRunLoop addTimer:session.timer forMode:NSRunLoopCommonModes];
    [presenter presentViewController:controller animated:YES completion:^{
        if(session.finished)return;
        session.started=YES;session.cleanupAfter=0;
        [controller.player play];
    }];
}
static void PVXOpenRemoteSystemVideo(NSDictionary *row) {
    WKWebView *web=PVXCollectionWebView();
    NSURL *url=[NSURL URLWithString:[row[@"url"] isKindOfClass:NSString.class]?row[@"url"]:@""];
    NSString *frame=[row[@"frame"] isKindOfClass:NSString.class]?row[@"frame"]:row[@"page"];
    NSURL *page=[frame isKindOfClass:NSString.class]?[NSURL URLWithString:frame]:nil;
    if(!web.window||!url.host.length||url.user.length||url.password.length||!page.host.length||![@[@"http",@"https"] containsObject:url.scheme.lowercaseString]){PVXAlert(@"视频无法播放",@"本地文件已不存在，或原始网页已关闭。请重新采集或下载。");return;}
    __weak WKWebView *origin=web;NSString *owner=[web.URL.absoluteString copy];__block BOOL finished=NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,12*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(!finished){finished=YES;PVXAlert(@"读取视频超时",@"原网页未返回播放信息，请重新采集后重试。");}});
    PVXValidateCollected(web,row,^(BOOL valid,NSString *agent){if(finished)return;if(!valid){finished=YES;PVXAlert(@"视频来源已改变",@"请重新采集后再观看。");return;}
        [web.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie*> *cookies){dispatch_async(dispatch_get_main_queue(),^{if(finished)return;WKWebView *current=origin;if(!current.window||![current.URL.absoluteString isEqual:owner]||PVXCollectionWebView()!=current){finished=YES;PVXAlert(@"视频来源失效",@"原始页面已关闭或切换。");return;}
            NSMutableArray *filtered=[NSMutableArray array];for(NSHTTPCookie *c in cookies)if(PVXPreviewCookie(c,url))[filtered addObject:c];
            NSMutableDictionary *options=[NSMutableDictionary dictionary],*headers=[NSMutableDictionary dictionary];
            if(filtered.count)options[AVURLAssetHTTPCookiesKey]=filtered;
            if(agent.length<8192&&agent.length&&[agent rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location==NSNotFound)headers[@"User-Agent"]=agent;
            NSURLComponents *ref=[NSURLComponents componentsWithURL:page resolvingAgainstBaseURL:NO];ref.user=nil;ref.password=nil;ref.fragment=nil;
            if(!([page.scheme.lowercaseString isEqual:@"https"]&&[url.scheme.lowercaseString isEqual:@"http"]))headers[@"Referer"]=ref.URL.absoluteString;
            if(headers.count)options[@"AVURLAssetHTTPHeaderFieldsKey"]=headers;
            finished=YES;PVXPresentSystemVideo(url,options);
        });}];
    });
}

static void PVXOpenSystemVideo(NSDictionary *row) {
    __weak UIViewController *origin=PVXPresenter();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSString *path=PVXTaskLocalPath(row);
        dispatch_async(dispatch_get_main_queue(),^{
            UIViewController *host=origin;
            if(!host||host!=PVXPresenter()||!host.viewIfLoaded.window||host.isBeingDismissed)return;
            if(path.length)PVXPresentSystemVideo([NSURL fileURLWithPath:path],@{});
            else PVXOpenRemoteSystemVideo(row);
        });
    });
}

void PVXPlayVideoURL(NSString *url){NSURL *u=[NSURL URLWithString:url?:@""];if(!u.host.length||![@[@"http",@"https"] containsObject:u.scheme.lowercaseString]){PVXAlert(@"无法播放",@"视频 URL 无效。");return;}PVXPresentSystemVideo(u,@{});}

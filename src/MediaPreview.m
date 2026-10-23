#import "PVXCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <ImageIO/ImageIO.h>
#import <sys/stat.h>

extern void PVXValidateCollected(WKWebView *web, NSDictionary *row, void(^done)(BOOL valid, NSString *agent));

@interface PVXPreviewNetwork : NSObject <NSURLSessionDownloadDelegate>
@end
@implementation PVXPreviewNetwork
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {(void)session;(void)task;(void)response;(void)request;completionHandler(nil);}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)bytes totalBytesWritten:(int64_t)total totalBytesExpectedToWrite:(int64_t)expected {(void)session;(void)bytes;if(total>100*1024*1024||expected>100*1024*1024)[task cancel];}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {(void)session;(void)task;(void)location;}
@end
static UIImage *PVXPreviewImage(NSURL *url){NSDictionary *options=@{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways:@YES,(__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform:@YES,(__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize:@4096};CGImageSourceRef src=CGImageSourceCreateWithURL((__bridge CFURLRef)url,NULL);CGImageRef cg=src?CGImageSourceCreateThumbnailAtIndex(src,0,(__bridge CFDictionaryRef)options):NULL;UIImage *result=cg?[UIImage imageWithCGImage:cg]:nil;if(cg)CGImageRelease(cg);if(src)CFRelease(src);return result;}
static BOOL PVXPreviewCookie(NSHTTPCookie *c,NSURL *url){NSString *d=c.domain.lowercaseString;BOOL sub=[d hasPrefix:@"."];if(sub)d=[d substringFromIndex:1];NSString *host=url.host.lowercaseString,*path=url.path.length?url.path:@"/",*cp=c.path.length?c.path:@"/";return ([host isEqual:d]||(sub&&[host hasSuffix:[@"." stringByAppendingString:d]]))&&([path isEqual:cp]||([path hasPrefix:cp]&&([cp hasSuffix:@"/"]||(path.length>cp.length&&[path characterAtIndex:cp.length]=='/'))))&&(!c.secure||[url.scheme.lowercaseString isEqual:@"https"])&&(!c.expiresDate||c.expiresDate.timeIntervalSinceNow>0);}

@interface PVXPreviewController : UIViewController <UIScrollViewDelegate>
@property(nonatomic,copy) NSDictionary *row;
@property(nonatomic,strong) UIView *content;
@property(nonatomic,strong) UIScrollView *scroll;
@property(nonatomic,strong) UIImageView *imageView;
@property(nonatomic,strong) UIActivityIndicatorView *spinner;
@property(nonatomic,strong) UILabel *errorLabel;
@property(nonatomic,strong) NSURLSessionTask *imageTask;
@property(nonatomic,strong) NSURLSession *previewSession;
@end

@implementation PVXPreviewController
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor=UIColor.blackColor;
    self.content=self.view;
    UIButton *close=[UIButton buttonWithType:UIButtonTypeSystem];
    [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    close.tintColor=UIColor.whiteColor; close.translatesAutoresizingMaskIntoConstraints=NO;
    [close addTarget:self action:@selector(closePreview) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];
    [NSLayoutConstraint activateConstraints:@[[close.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],[close.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],[close.widthAnchor constraintEqualToConstant:44],[close.heightAnchor constraintEqualToConstant:44]]];
    [self showImage];
}
- (void)showError:(NSString *)text {
    if (!self.errorLabel) { self.errorLabel=[UILabel new]; self.errorLabel.textColor=UIColor.whiteColor; self.errorLabel.textAlignment=NSTextAlignmentCenter; self.errorLabel.numberOfLines=0; self.errorLabel.translatesAutoresizingMaskIntoConstraints=NO; [self.view addSubview:self.errorLabel]; [NSLayoutConstraint activateConstraints:@[[self.errorLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],[self.errorLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],[self.errorLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],[self.errorLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-24]]]; }
    self.errorLabel.text=text; self.errorLabel.hidden=NO; [self.spinner stopAnimating];
}
- (void)showImage {
    self.scroll=[[UIScrollView alloc] initWithFrame:self.view.bounds]; self.scroll.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight; self.scroll.delegate=self; self.scroll.minimumZoomScale=1; self.scroll.maximumZoomScale=6; self.scroll.backgroundColor=UIColor.blackColor; [self.view insertSubview:self.scroll atIndex:0];
    self.imageView=[UIImageView new]; self.imageView.contentMode=UIViewContentModeScaleAspectFit; self.imageView.frame=self.scroll.bounds; self.imageView.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight; [self.scroll addSubview:self.imageView];
    NSString *path=PVXTaskLocalPath(self.row);
    if (path.length) { struct stat st; if (lstat(path.fileSystemRepresentation,&st)||!S_ISREG(st.st_mode)||st.st_size<=0) { [self showError:@"本地图片文件不可用。"]; return; } dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{ UIImage *image=PVXPreviewImage([NSURL fileURLWithPath:path]); dispatch_async(dispatch_get_main_queue(),^{ if(!self.isViewLoaded)return; if(image)self.imageView.image=image; else [self showError:@"图片格式无法预览。"]; }); }); return; }
    [self fetchRemoteImage];
}
- (void)fetchRemoteImage {
    WKWebView *web=PVXCollectionWebView(); NSURL *url=[NSURL URLWithString:[self.row[@"url"] isKindOfClass:NSString.class]?self.row[@"url"]:@""]; NSURL *page=[NSURL URLWithString:[self.row[@"page"] isKindOfClass:NSString.class]?self.row[@"page"]:@""];
    if(!web||!web.window||!url.host.length||!page.host.length||![@[@"http",@"https"] containsObject:url.scheme.lowercaseString]) { [self showError:@"远程图片需要仍然打开的原始网页。"] ; return; }
    self.spinner=[[UIActivityIndicatorView alloc]initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge]; self.spinner.color=UIColor.whiteColor; self.spinner.center=self.view.center; self.spinner.autoresizingMask=UIViewAutoresizingFlexibleTopMargin|UIViewAutoresizingFlexibleBottomMargin|UIViewAutoresizingFlexibleLeftMargin|UIViewAutoresizingFlexibleRightMargin; [self.view addSubview:self.spinner]; [self.spinner startAnimating];
    NSDictionary *row=self.row; __weak typeof(self) weak=self;
    PVXValidateCollected(web,row,^(BOOL valid,NSString *agent){ if(!valid){[weak showError:@"图片来源已失效，请重新采集。"] ;return;} [web.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie*> *cookies){ NSMutableArray *matching=[NSMutableArray array]; for(NSHTTPCookie *c in cookies)if(PVXPreviewCookie(c,url))[matching addObject:c]; NSMutableURLRequest *req=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:45]; req.HTTPMethod=@"GET"; if(agent.length&&agent.length<8192) [req setValue:agent forHTTPHeaderField:@"User-Agent"]; if(!([page.scheme.lowercaseString isEqual:@"https"]&&[url.scheme.lowercaseString isEqual:@"http"])) [req setValue:page.absoluteString forHTTPHeaderField:@"Referer"]; NSDictionary *fields=[NSHTTPCookie requestHeaderFieldsWithCookies:matching]; if(fields[@"Cookie"]) [req setValue:fields[@"Cookie"] forHTTPHeaderField:@"Cookie"]; NSURLSessionConfiguration *cfg=NSURLSessionConfiguration.ephemeralSessionConfiguration;cfg.HTTPCookieStorage=nil;cfg.HTTPShouldSetCookies=NO;cfg.timeoutIntervalForResource=60;NSURLSession *session=[NSURLSession sessionWithConfiguration:cfg delegate:[PVXPreviewNetwork new] delegateQueue:nil];weak.previewSession=session;NSURLSessionDownloadTask *task=[session downloadTaskWithRequest:req completionHandler:^(NSURL *file,NSURLResponse *response,NSError *error){struct stat st;BOOL bounded=file&&!lstat(file.fileSystemRepresentation,&st)&&S_ISREG(st.st_mode)&&st.st_size>0&&st.st_size<=100*1024*1024;UIImage *decoded=bounded?PVXPreviewImage(file):nil;[session finishTasksAndInvalidate];dispatch_async(dispatch_get_main_queue(),^{ if(!weak.isViewLoaded||weak.isBeingDismissed)return; NSHTTPURLResponse *http=[response isKindOfClass:NSHTTPURLResponse.class]?(id)response:nil; if(error||http.statusCode<200||http.statusCode>=300||!bounded){[weak showError:[NSString stringWithFormat:@"图片载入失败%@。",error.localizedDescription?:@""]];return;} UIImage *image=decoded; if(image)weak.imageView.image=image; else [weak showError:@"服务器返回的内容不是可显示图片。"]; [weak.spinner stopAnimating]; }); }]; weak.imageTask=task; [task resume]; }]; });
}
- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView { (void)scrollView; return self.imageView; }
- (void)closePreview { [self.imageTask cancel];[self.previewSession invalidateAndCancel];[self dismissViewControllerAnimated:YES completion:nil]; }
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated];[self.imageTask cancel];[self.previewSession invalidateAndCancel]; }
- (void)dealloc { [_imageTask cancel];[_previewSession invalidateAndCancel]; }
@end

#import "SystemVideoPreview.inc"

void PVXPreviewMedia(NSDictionary *row) {
    if(!NSThread.isMainThread){NSDictionary *copy=[row isKindOfClass:NSDictionary.class]?[row copy]:nil;dispatch_async(dispatch_get_main_queue(),^{PVXPreviewMedia(copy);});return;}
    if(![row isKindOfClass:NSDictionary.class]||![@[@"image",@"video"] containsObject:row[@"kind"]]){PVXAlert(@"无法预览",@"媒体项目无效。");return;}
    if([row[@"kind"] isEqual:@"video"]){PVXOpenSystemVideo([row copy]);return;}
    UIViewController *presenter=PVXPresenter();if(!presenter){PVXAlert(@"无法预览",@"找不到可显示预览的页面。");return;}
    PVXPreviewController *vc=[PVXPreviewController new];vc.row=[row copy];vc.modalPresentationStyle=UIModalPresentationFullScreen;[presenter presentViewController:vc animated:YES completion:nil];
}

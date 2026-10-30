// On-device isolation probe for the system player preflight watchdog.
// Uses the production SystemVideoPreview.inc; never touches installed PyVideo,
// production tasks, or the real Safari process.
#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import "PVXCommon.h"

static NSMutableArray<NSString*> *PVXAlerts;
static NSString *PVXReportPath;
static UIViewController *PVXRootController;

UIViewController *PVXPresenter(void) { return PVXRootController; }
void PVXAlert(NSString *title, NSString *message) {
    if (!PVXAlerts) PVXAlerts = [NSMutableArray array];
    [PVXAlerts addObject:[NSString stringWithFormat:@"%@|%@", title ?: @"", message ?: @""]];
}
WKWebView *PVXCollectionWebView(void) { return nil; }
NSString *PVXTaskPreviewLocalPath(NSDictionary *task) { (void)task; return nil; }
void PVXValidateCollected(WKWebView *web, NSDictionary *row, void (^done)(BOOL, NSString *)) {
    (void)web; (void)row; done(YES, @"PVXPlayerTrial/1.0");
}
static BOOL PVXPreviewCookie(NSHTTPCookie *c, NSURL *url) { (void)c; (void)url; return YES; }

#import "SystemVideoPreview.inc"

@interface PVXTrialApp : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end

static BOOL PVXWriteReport(NSDictionary *report) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL];
    return json && [json writeToFile:PVXReportPath atomically:YES];
}

static void PVXMakeFixture(NSString *path, void (^done)(BOOL)) {
    NSError *error = nil;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:path] fileType:AVFileTypeMPEG4 error:&error];
    if (!writer) { done(NO); return; }
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{AVVideoCodecKey: AVVideoCodecTypeH264, AVVideoWidthKey: @320, AVVideoHeightKey: @180}];
    input.expectsMediaDataInRealTime = NO;
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input sourcePixelBufferAttributes:@{(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32ARGB), (__bridge NSString *)kCVPixelBufferWidthKey: @320, (__bridge NSString *)kCVPixelBufferHeightKey: @180}];
    [writer addInput:input];
    if (![writer startWriting]) { done(NO); return; }
    [writer startSessionAtSourceTime:kCMTimeZero];
    CVPixelBufferRef buffer = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &buffer) != kCVReturnSuccess || !buffer) { done(NO); return; }
    CVPixelBufferLockBaseAddress(buffer, 0);
    unsigned char *base = CVPixelBufferGetBaseAddress(buffer);
    size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    for (size_t y = 0; y < 180; y++) for (size_t x = 0; x < 320; x++) {
        unsigned char *p = base + y * stride + x * 4;
        p[0] = 255; p[1] = (unsigned char)(x / 2); p[2] = (unsigned char)(y); p[3] = 128;
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    for (int frame = 0; frame < 90; frame++) {
        NSTimeInterval limit = NSDate.date.timeIntervalSince1970 + 8;
        while (!input.readyForMoreMediaData && writer.status == AVAssetWriterStatusWriting && NSDate.date.timeIntervalSince1970 < limit) usleep(10000);
        if (!input.readyForMoreMediaData || ![adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(frame, 30)]) { CVPixelBufferRelease(buffer); done(NO); return; }
    }
    CVPixelBufferRelease(buffer);
    [input markAsFinished];
    [writer finishWritingWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{ done(writer.status == AVAssetWriterStatusCompleted); });
    }];
}

@implementation PVXTrialApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    PVXAlerts = [NSMutableArray array];
    PVXReportPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"pvx-player-trial.json"];
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    PVXRootController = [UIViewController new];
    PVXRootController.view.backgroundColor = UIColor.whiteColor;
    self.window.rootViewController = PVXRootController;
    [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self run]; });
    return YES;
}
- (void)run {
    NSString *file = [NSTemporaryDirectory() stringByAppendingPathComponent:@"fixture.mp4"];
    [NSFileManager.defaultManager removeItemAtPath:file error:NULL];
    PVXMakeFixture(file, ^(BOOL ok) {
        if (!ok) { PVXWriteReport(@{@"success": @NO, @"error": @"fixture writer failed"}); return; }
        NSDictionary *row = @{@"kind": @"video", @"url": @"https://fixture.invalid/local.mp4", @"title": @"watchdog fixture"};
        PVXPresentSystemVideoWithSource([NSURL fileURLWithPath:file], @{}, row);
        // Hold beyond the old 20 s preflight deadline. A regression re-arms the
        // watchdog and calls PVXAlert, which this probe records as failure.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 23 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            AVPlayerViewController *player = (AVPlayerViewController *)PVXRootController.presentedViewController;
            BOOL presented = [player isKindOfClass:AVPlayerViewController.class];
            NSTimeInterval position = presented ? CMTimeGetSeconds(player.player.currentTime) : -1;
            NSDictionary *report = @{
                @"success": @(presented && PVXAlerts.count == 0),
                @"playerPresentedAfter23s": @(presented),
                @"watchdogAlerts": PVXAlerts ?: @[],
                @"playbackPosition": @(position),
                @"systemVersion": UIDevice.currentDevice.systemVersion,
                @"scope": @"isolated production SystemVideoPreview.inc probe; no production task or Safari process"
            };
            PVXWriteReport(report);
            NSLog(@"PVX_PLAYER_TRIAL_RESULT %@", [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:report options:0 error:NULL] encoding:NSUTF8StringEncoding]);
        });
    });
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"PVXTrialApp"); }
}

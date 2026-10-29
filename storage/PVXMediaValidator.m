#import "PVXMediaValidator.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <sys/stat.h>
#import <math.h>

// All state transitions are serialized on queue. Potentially blocking asset and
// reader work runs elsewhere, so the independent deadline can always finish.
@interface PVXMediaValidation : NSObject
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong, nullable) dispatch_source_t timer;
@property(nonatomic, copy) NSString *path;
@property(nonatomic) double expected;
@property(nonatomic) BOOL requireAudio;
@property(nonatomic, copy, nullable) void (^completion)(BOOL, NSDictionary *);
@property(nonatomic, strong, nullable) AVURLAsset *asset;
@property(nonatomic, strong, nullable) AVAssetImageGenerator *generator;
@property(nonatomic, strong, nullable) AVAssetReader *reader;
@property(nonatomic, strong) NSMutableDictionary *details;
@property(nonatomic) BOOL finished;
@property(nonatomic) NSUInteger frames;
@property(nonatomic) NSUInteger attempted;
@property(nonatomic) struct stat initialStat;
- (void)finish:(BOOL)valid reason:(NSString *)reason;
- (void)start;
@end

static BOOL PVXFiniteDuration(CMTime time, double *seconds) {
    if (!CMTIME_IS_NUMERIC(time)) return NO;
    *seconds = CMTimeGetSeconds(time);
    return isfinite(*seconds) && *seconds > 0;
}

static BOOL PVXLoaded(id<AVAsynchronousKeyValueLoading> object, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        if ([object statusOfValueForKey:key error:NULL] != AVKeyValueStatusLoaded) return NO;
    }
    return YES;
}

@implementation PVXMediaValidation
- (void)finish:(BOOL)valid reason:(NSString *)reason {
    // queue only; cancel the deadline and release every cancellation resource.
    if (self.finished) return;
    self.finished = YES;
    if (valid) {
        struct stat now;
        struct stat before = self.initialStat;
        if (lstat(self.path.fileSystemRepresentation, &now) != 0 ||
            !S_ISREG(now.st_mode) || now.st_dev != before.st_dev ||
            now.st_ino != before.st_ino || now.st_size != before.st_size ||
            now.st_mtime != before.st_mtime) {
            valid = NO;
            reason = @"file_changed";
        }
    }
    self.details[@"reason"] = reason;
    self.details[@"valid"] = @(valid);
    self.details[@"videoFramesDecoded"] = @(self.frames);
    self.details[@"fullDecode"] = @NO;
    if (self.timer) { dispatch_source_cancel(self.timer); self.timer = nil; }
    [self.asset cancelLoading];
    [self.generator cancelAllCGImageGeneration];
    [self.reader cancelReading];
    self.generator = nil;
    self.reader = nil;
    self.asset = nil;
    NSDictionary *result = [self.details copy];
    void (^callback)(BOOL, NSDictionary *) = self.completion;
    self.completion = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ if (callback) callback(valid, result); });
}

- (void)readAudio:(AVAssetTrack * _Nullable)audio {
    // queue only. One decoded PCM buffer establishes readability, not full decode.
    if (!audio) { [self finish:YES reason:@"ok"]; return; }
    AVURLAsset *asset = self.asset;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSError *error = nil;
            AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
            AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc]
                initWithTrack:audio outputSettings:@{AVFormatIDKey: @(kAudioFormatLinearPCM)}];
            output.alwaysCopiesSampleData = NO;
            BOOL configured = reader && [reader canAddOutput:output];
            if (configured) [reader addOutput:output];
            dispatch_async(self.queue, ^{
                if (self.finished) { [reader cancelReading]; return; }
                if (!configured) { [self finish:NO reason:@"audio_reader_setup"]; return; }
                self.reader = reader;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    @autoreleasepool {
                        BOOL readable = NO;
                        if ([reader startReading]) {
                            CMSampleBufferRef sample = [output copyNextSampleBuffer];
                            if (sample) {
                                CMBlockBufferRef data = CMSampleBufferGetDataBuffer(sample);
                                readable = CMSampleBufferDataIsReady(sample) &&
                                    CMSampleBufferGetNumSamples(sample) > 0 && data &&
                                    CMBlockBufferGetDataLength(data) > 0;
                                CFRelease(sample);
                            }
                        }
                        dispatch_async(self.queue, ^{
                            if (self.finished) return;
                            self.details[@"audioSampleDecoded"] = @(readable);
                            if (readable) [self finish:YES reason:@"ok"]; else if ([self.details[@"fileBytes"] longLongValue] > 200*1024*1024) [self finish:YES reason:@"ok_large_file_audio_track"]; else [self finish:NO reason:@"audio_decode_failed"];
                        });
                    }
                });
            });
        }
    });
}

- (void)sampleVideo:(AVAssetTrack *)video audio:(AVAssetTrack * _Nullable)audio {
    // Track metadata was asynchronously loaded before entering this method.
    CGSize size = video.naturalSize;
    double duration = 0;
    CMTimeRange range = video.timeRange;
    double start = CMTimeGetSeconds(range.start);
    if (!isfinite(size.width) || !isfinite(size.height) || size.width <= 0 || size.height <= 0 ||
        size.width > 8192 || size.height > 8192 || size.width * size.height > 33554432 ||
        !PVXFiniteDuration(range.duration, &duration) || !isfinite(start) || start < 0) {
        [self finish:NO reason:@"invalid_video_metadata"]; return;
    }
    self.details[@"videoWidth"] = @(size.width);
    self.details[@"videoHeight"] = @(size.height);
    self.details[@"videoDuration"] = @(duration);
    double tolerance = MAX(2.0, self.expected * 0.005);
    if (self.expected > 0 && fabs(duration - self.expected) > tolerance) {
        [self finish:NO reason:@"video_duration_mismatch"]; return;
    }
    // Interior points avoid exact end-of-stream and tolerate AAC priming/delay:
    // audio uses its own track timeline rather than assuming an initial PTS of 0.
    double margin = MIN(0.10, duration * 0.05);
    NSArray<NSNumber *> *positions = @[@(start + margin), @(start + duration * 0.5),
                                      @(start + duration - margin)];
    NSMutableArray<NSValue *> *times = [NSMutableArray array];
    for (NSNumber *position in positions)
        [times addObject:[NSValue valueWithCMTime:CMTimeMakeWithSeconds(position.doubleValue, 600000)]];
    self.details[@"requestedVideoSampleSeconds"] = positions;
    if (self.details[@"fileBytes"] && [self.details[@"fileBytes"] longLongValue] > 200*1024*1024) { self.details[@"videoFramesUnavailable"]=@YES; [self readAudio:audio]; return; }
    AVAssetImageGenerator *generator = [[AVAssetImageGenerator alloc] initWithAsset:self.asset];
    generator.maximumSize = CGSizeMake(640, 640);
    generator.appliesPreferredTrackTransform = YES;
    CMTime slack = CMTimeMakeWithSeconds(MIN(0.25, duration * 0.1), 600000);
    generator.requestedTimeToleranceBefore = slack;
    generator.requestedTimeToleranceAfter = slack;
    self.generator = generator;
    [generator generateCGImagesAsynchronouslyForTimes:times completionHandler:
        ^(CMTime requested, CGImageRef image, CMTime actual,
          AVAssetImageGeneratorResult result, NSError *error) {
            (void)requested; (void)error;
            // Image references are borrowed and only inspected inside this callback.
            BOOL decoded = result == AVAssetImageGeneratorSucceeded && image &&
                CGImageGetWidth(image) > 0 && CGImageGetHeight(image) > 0 &&
                CMTIME_IS_NUMERIC(actual) && isfinite(CMTimeGetSeconds(actual));
            double actualSeconds = CMTimeGetSeconds(actual);
            dispatch_async(self.queue, ^{
                if (self.finished) return;
                self.attempted += 1;
                if (!decoded) { if (self.attempted == times.count) { if (!self.frames) self.details[@"videoFramesUnavailable"]=@YES; [self readAudio:audio]; } return; }
                NSMutableArray *actuals = self.details[@"actualVideoSampleSeconds"];
                [actuals addObject:@(actualSeconds)];
                self.frames += 1;
                if (self.frames == times.count) [self readAudio:audio];
            });
        }];
}

- (void)inspectAsset:(AVURLAsset *)asset {
    dispatch_async(self.queue, ^{
        if (self.finished) return;
        if (!PVXLoaded(asset, @[@"tracks", @"duration", @"playable"]) || !asset.playable) {
            [self finish:NO reason:@"asset_unreadable"]; return;
        }
        double duration = 0;
        if (!PVXFiniteDuration(asset.duration, &duration)) {
            [self finish:NO reason:@"invalid_duration"]; return;
        }
        self.details[@"duration"] = @(duration);
        if (self.expected > 0 && fabs(duration - self.expected) > MAX(2.0, self.expected * 0.005)) {
            [self finish:NO reason:@"duration_mismatch"]; return;
        }
        AVAssetTrack *video = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        AVAssetTrack *audio = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
        self.details[@"hasAudio"] = @(audio != nil);
        if (!video) { [self finish:NO reason:@"missing_video"]; return; }
        if (self.requireAudio && !audio) { [self finish:NO reason:@"missing_audio"]; return; }
        [video loadValuesAsynchronouslyForKeys:@[@"naturalSize", @"timeRange"] completionHandler:^{
            dispatch_async(self.queue, ^{
                if (self.finished) return;
                if (!PVXLoaded(video, @[@"naturalSize", @"timeRange"])) {
                    [self finish:NO reason:@"video_metadata_unreadable"]; return;
                }
                [self sampleVideo:video audio:audio];
            });
        }];
    });
}

- (void)start {
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_timer(self.timer, dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_SEC),
                             DISPATCH_TIME_FOREVER, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(self.timer, ^{
        if (self.details[@"videoWidth"] && self.details[@"duration"]) [self finish:YES reason:@"ok_large_file_tracks"];
        else [self finish:NO reason:@"timeout"];
    });
    dispatch_resume(self.timer);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            struct stat info = {0};
            const char *file = self.path.fileSystemRepresentation;
            BOOL regular = file && lstat(file, &info) == 0 && S_ISREG(info.st_mode) && info.st_size > 0;
            dispatch_async(self.queue, ^{
                if (self.finished) return;
                if (!isfinite(self.expected)) { [self finish:NO reason:@"invalid_expected_duration"]; return; }
                if (!regular) { [self finish:NO reason:@"not_regular_nonempty_file"]; return; }
                self.initialStat = info;
                self.details[@"fileBytes"] = @(info.st_size);
                AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:self.path]
                    options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
                self.asset = asset;
                [asset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration", @"playable"]
                    completionHandler:^{ [self inspectAsset:asset]; }];
            });
        }
    });
}
@end

void PVXValidateMediaFile(NSString *path, double expectedDuration, BOOL requireAudio,
                          void (^done)(BOOL, NSDictionary *)) {
    PVXMediaValidation *job = [PVXMediaValidation new];
    job.queue = dispatch_queue_create("com.pvx.media-validation", DISPATCH_QUEUE_SERIAL);
    job.path = [path copy];
    job.expected = expectedDuration;
    job.requireAudio = requireAudio;
    job.completion = [done copy];
    job.details = [@{@"expectedDuration": @(expectedDuration), @"requireAudio": @(requireAudio),
                     @"audioSampleDecoded": @NO, @"actualVideoSampleSeconds": [NSMutableArray array],
                     @"validationScope": @"three-video-frames-and-one-audio-buffer"} mutableCopy];
    dispatch_async(job.queue, ^{ [job start]; });
}

// Test-only AVAssetWriter fixture, compiled with the production preview module.
- (void)verifySystemPlayerAfterImage {
    [self.manager dismissViewControllerAnimated:NO completion:^{[self createPlayableFixture];}];
}
- (void)createPlayableFixture {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSString *uuid=@"88888888-8888-4888-8888-888888888888";
        NSString *file=PVXPath([NSString stringWithFormat:@"media/%@.mp4",uuid]);
        [NSFileManager.defaultManager createDirectoryAtPath:file.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
        [NSFileManager.defaultManager removeItemAtPath:file error:NULL];
        NSError *error=nil;
        AVAssetWriter *writer=[[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:file] fileType:AVFileTypeMPEG4 error:&error];
        Check(writer!=nil&&!error,@"real test H264 writer created");
        AVAssetWriterInput *input=[AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{AVVideoCodecKey:AVVideoCodecTypeH264,AVVideoWidthKey:@320,AVVideoHeightKey:@180}];
        input.expectsMediaDataInRealTime=NO;
        AVAssetWriterInputPixelBufferAdaptor *adaptor=[AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input sourcePixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32ARGB),(id)kCVPixelBufferWidthKey:@320,(id)kCVPixelBufferHeightKey:@180}];
        [writer addInput:input];Check([writer startWriting],@"real H264 writer starts");[writer startSessionAtSourceTime:kCMTimeZero];
        CVPixelBufferRef buffer=NULL;
        Check(CVPixelBufferPoolCreatePixelBuffer(NULL,adaptor.pixelBufferPool,&buffer)==kCVReturnSuccess&&buffer,@"real video pixel buffer allocated");
        CVPixelBufferLockBaseAddress(buffer,0);
        unsigned char *base=CVPixelBufferGetBaseAddress(buffer);size_t stride=CVPixelBufferGetBytesPerRow(buffer);
        for(size_t y=0;y<180;y++)for(size_t x=0;x<320;x++){unsigned char *p=base+y*stride+x*4;p[0]=255;p[1]=20;p[2]=(unsigned char)(y+40);p[3]=(unsigned char)(x/2+50);}
        CVPixelBufferUnlockBaseAddress(buffer,0);
        for(int frame=0;frame<90;frame++){
            NSTimeInterval limit=NSDate.date.timeIntervalSince1970+8;
            while(!input.readyForMoreMediaData&&writer.status==AVAssetWriterStatusWriting&&NSDate.date.timeIntervalSince1970<limit)usleep(10000);
            Check(input.readyForMoreMediaData&&[adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(frame,30)],@"actual H264 frame appended");
        }
        CVPixelBufferRelease(buffer);[input markAsFinished];
        [writer finishWritingWithCompletionHandler:^{dispatch_async(dispatch_get_main_queue(),^{
            Check(writer.status==AVAssetWriterStatusCompleted,@"playable MP4 fixture finalized");
            NSDictionary *task=@{@"id":uuid,@"kind":@"video",@"state":@"ready",@"title":@"System AVKit fixture",@"created":@(NSDate.date.timeIntervalSince1970)};
            Check(PVXAtomic(task,PVXPath([NSString stringWithFormat:@"tasks/%@.plist",uuid]),NULL),@"real playable task snapshot written");
            PVXPreviewMedia(task);
            Wait(150,^BOOL{return [self.manager.presentedViewController isKindOfClass:AVPlayerViewController.class];},^{
                AVPlayerViewController *player=(id)self.manager.presentedViewController;
                Check(player.class==AVPlayerViewController.class,[NSString stringWithFormat:@"native Apple player public class %@ runtime %@",NSStringFromClass(player.class),NSStringFromClass(object_getClass(player))]);
                Check(player.showsPlaybackControls&&player.allowsPictureInPicturePlayback&&!player.requiresLinearPlayback,@"exact Apple AVPlayerViewController enables standard controls seeking and PiP");
                Check(player.modalPresentationStyle==UIModalPresentationFullScreen,@"system video presented directly fullscreen without custom wrapper");
                Check(player.contentOverlayView.subviews.count==0,@"no custom buttons layered over system player");
                Wait(150,^BOOL{return player.player.currentItem.status==AVPlayerItemStatusReadyToPlay;},^{
                    Wait(100,^BOOL{return CMTimeGetSeconds(player.player.currentTime)>.2;},^{
                        Check([player.player.currentItem.asset tracksWithMediaType:AVMediaTypeVideo].count==1,@"system player decodes real H264 track and advances time");
                        [player.player pause];
                        [player.player seekToTime:CMTimeMakeWithSeconds(1.25,600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished){dispatch_async(dispatch_get_main_queue(),^{
                            Check(finished&&fabs(CMTimeGetSeconds(player.player.currentTime)-1.25)<.12,@"native AVPlayer seeking works on real clip");
                            Capture(@"native-player",^{
                                [self.manager dismissViewControllerAnimated:NO completion:^{
                                    AVPlayer *old=player.player;
                                    Wait(50,^BOOL{return player.player==nil&&old.rate==0;},^{
                                        Check(YES,@"dismissing system player releases player and audio session owner");
                                        [self verifyWatchdogSnapshot];
                                    },@"system player session cleanup");
                                }];
                            });
                        });}];
                    },@"real playback time advancing");
                },@"native player item ready");
            },@"exact system player presented");
        });}];
    });
}

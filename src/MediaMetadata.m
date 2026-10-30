#import "PVXCommon.h"
#import "PVXMediaResource.h"
#import "MediaMetadataState.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <math.h>

static NSString *PVXMetadataKey(NSDictionary *row);
static NSCache *PVXPreviewAssets;
static NSCache *PVXMetadataCache; static NSMutableDictionary *PVXMetadataWaiters; static dispatch_once_t PVXMetadataOnce;
static void PVXMetadataSetup(void){dispatch_once(&PVXMetadataOnce,^{PVXMetadataCache=[NSCache new];PVXMetadataCache.countLimit=256;PVXMetadataWaiters=[NSMutableDictionary dictionary];PVXPreviewAssets=[NSCache new];PVXPreviewAssets.countLimit=8;[[NSNotificationCenter defaultCenter]addObserverForName:@"PVXPreviewAssetReady" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){NSDictionary *row=n.userInfo[@"row"];if([row isKindOfClass:NSDictionary.class]&&[n.object isKindOfClass:AVURLAsset.class])[PVXPreviewAssets setObject:n.object forKey:PVXMetadataKey(row)];}];});}
static NSString *PVXText(id v,NSUInteger n){return [v isKindOfClass:NSString.class]?[v substringToIndex:MIN(n,[v length])]:@"";}
static NSString *PVXMetadataKey(NSDictionary *row){return [@[(row[@"kind"]?:@"video"),PVXText(row[@"url"],16384),PVXText(row[@"page"],16384),PVXText(row[@"frame"],16384),PVXText(row[@"poster"],16384),PVXText(row[@"documentID"],512),(row[@"headers"]?:@{})] description];}
static NSURL *PVXURL(NSDictionary *r){NSURL *u=[NSURL URLWithString:PVXText(r[@"url"],16384)];return u.host.length&&[@[@"http",@"https"] containsObject:u.scheme.lowercaseString]?u:nil;}
static NSString *PVXBytes(long long n){return n>0?[NSByteCountFormatter stringFromByteCount:n countStyle:NSByteCountFormatterCountStyleDecimal]:@"大小未知";}
static NSString *PVXReferer(NSDictionary *r){NSURLComponents *c=[NSURLComponents componentsWithString:PVXText(r[@"frame"]?:r[@"page"],16384)];c.user=nil;c.password=nil;c.fragment=nil;return c.URL.absoluteString?:@"";}
static BOOL PVXHTTPValid(NSHTTPURLResponse *h){return h&&h.statusCode>=200&&h.statusCode<300;}
static BOOL PVXRange(NSHTTPURLResponse *h,long long *total){NSString *s=h.allHeaderFields[@"Content-Range"]?:h.allHeaderFields[@"content-range"];if(![s isKindOfClass:NSString.class])return NO;NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:@"^bytes [0-9]+-[0-9]+/([0-9]+)$" options:0 error:nil];NSTextCheckingResult *m=[re firstMatchInString:s options:0 range:NSMakeRange(0,s.length)];if(!m)return NO;long long n=[[s substringWithRange:[m rangeAtIndex:1]] longLongValue];if(total)*total=n;return n>0;}
static long long PVXResponseLength(NSHTTPURLResponse *h){id v=h.allHeaderFields[@"Content-Length"]?:h.allHeaderFields[@"content-length"];return [v respondsToSelector:@selector(longLongValue)]?[v longLongValue]:0;}
static NSString *PVXManifestQuality(NSData *d,NSInteger *outW,NSInteger *outH){NSString *s=[[NSString alloc]initWithData:d encoding:NSUTF8StringEncoding];if(!s.length)return nil;NSRegularExpression *r=[NSRegularExpression regularExpressionWithPattern:@"RESOLUTION\\s*=\\s*(\\d+)x(\\d+)" options:NSRegularExpressionCaseInsensitive error:nil];NSInteger bw=0,bh=0;for(NSTextCheckingResult *m in [r matchesInString:s options:0 range:NSMakeRange(0,s.length)]){NSInteger w=[[s substringWithRange:[m rangeAtIndex:1]]integerValue],h=[[s substringWithRange:[m rangeAtIndex:2]]integerValue];if(w*h>bw*bh){bw=w;bh=h;}}if(outW)*outW=bw;if(outH)*outH=bh;return bw&&bh?[NSString stringWithFormat:@"%ldp · %ld×%ld",(long)MIN(bw,bh),(long)bw,(long)bh]:nil;}
static UIImage *PVXImageData(NSData *data,NSInteger *w,NSInteger *h){if(!data.length||data.length>100*1024*1024)return nil;CGImageSourceRef s=CGImageSourceCreateWithData((__bridge CFDataRef)data,NULL);if(!s)return nil;NSDictionary *p=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(s,0,NULL));NSInteger iw=[p[(__bridge NSString*)kCGImagePropertyPixelWidth] integerValue],ih=[p[(__bridge NSString*)kCGImagePropertyPixelHeight] integerValue];if(w)*w=iw;if(h)*h=ih;NSDictionary *o=@{(__bridge NSString*)kCGImageSourceCreateThumbnailFromImageAlways:@YES,(__bridge NSString*)kCGImageSourceCreateThumbnailWithTransform:@YES,(__bridge NSString*)kCGImageSourceThumbnailMaxPixelSize:@480};CGImageRef cg=CGImageSourceCreateThumbnailAtIndex(s,0,(__bridge CFDictionaryRef)o);UIImage *im=cg?[UIImage imageWithCGImage:cg]:nil;if(cg)CGImageRelease(cg);CFRelease(s);return im;}
static UIImage *PVXImageFile(NSURL *file,NSInteger *w,NSInteger *h){CGImageSourceRef s=CGImageSourceCreateWithURL((__bridge CFURLRef)file,NULL);if(!s)return nil;NSDictionary *p=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(s,0,NULL));NSInteger iw=[p[(__bridge NSString*)kCGImagePropertyPixelWidth] integerValue],ih=[p[(__bridge NSString*)kCGImagePropertyPixelHeight] integerValue];if(w)*w=iw;if(h)*h=ih;NSDictionary *o=@{(__bridge NSString*)kCGImageSourceCreateThumbnailFromImageAlways:@YES,(__bridge NSString*)kCGImageSourceCreateThumbnailWithTransform:@YES,(__bridge NSString*)kCGImageSourceThumbnailMaxPixelSize:@480};CGImageRef cg=CGImageSourceCreateThumbnailAtIndex(s,0,(__bridge CFDictionaryRef)o);UIImage *im=cg?[UIImage imageWithCGImage:cg]:nil;if(cg)CGImageRelease(cg);CFRelease(s);return im;}
static void PVXDeliver(NSString *key,NSDictionary *value){if([value[@"thumbnail"] isKindOfClass:UIImage.class]&&![value[@"error"] length])[PVXMetadataCache setObject:[value copy] forKey:key];NSArray *a=[PVXMetadataWaiters[key] copy]?:@[];[PVXMetadataWaiters removeObjectForKey:key];for(void(^b)(NSDictionary*) in a)b(value?:@{});}
// All job state and row delivery are serialized on the main queue. Network and decode are not.
static NSUInteger PVXMetadataActive;
static NSMutableArray *PVXMetadataPending;
static void PVXMetadataSchedule(NSString *key,void (^job)(void)) {
    if (!PVXMetadataPending) PVXMetadataPending=[NSMutableArray array];
    if (PVXMetadataActive<PVXMetadataConcurrencyLimit) { PVXMetadataActive++; job(); }
    else {
        id pending=[job copy];[PVXMetadataPending addObject:pending];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            NSUInteger index=[PVXMetadataPending indexOfObjectIdenticalTo:pending];
            if(index==NSNotFound)return;
            [PVXMetadataPending removeObjectAtIndex:index];
            PVXDeliver(key,@{@"error":@"媒体封面排队超时",@"sizeText":@"大小未知"});
        });
    }
}
static void PVXMetadataRelease(void) {
    if (PVXMetadataActive) PVXMetadataActive--;
    if (PVXMetadataPending.count) {
        void (^job)(void)=[PVXMetadataPending.firstObject copy];
        [PVXMetadataPending removeObjectAtIndex:0]; PVXMetadataActive++; job();
    }
}
static NSMutableURLRequest *PVXMetadataRequest(NSURL *url,NSDictionary *row,NSArray *cookies,NSString *ua) {
    NSMutableURLRequest *q=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    q.HTTPMethod=@"GET";
    NSDictionary *saved=[row[@"headers"] isKindOfClass:NSDictionary.class]?row[@"headers"]:@{};
    NSString *agent=PVXText(saved[@"User-Agent"],16384); if(!agent.length)agent=ua;
    if(agent.length&&[agent rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location==NSNotFound)[q setValue:agent forHTTPHeaderField:@"User-Agent"];
    NSString *ref=PVXReferer(row);
    if(ref.length&&!([ref hasPrefix:@"https:"]&&[url.scheme.lowercaseString isEqual:@"http"]))[q setValue:ref forHTTPHeaderField:@"Referer"];
    NSDictionary *fields=[NSHTTPCookie requestHeaderFieldsWithCookies:PVXMediaCookiesForURL(cookies,url)];
    if(fields[@"Cookie"])[q setValue:fields[@"Cookie"] forHTTPHeaderField:@"Cookie"];
    return q;
}
static NSString *PVXURLManifestQuality(NSURL *url,NSInteger *outW,NSInteger *outH){NSString *text=url.absoluteString?:@"";NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:@"(?:^|[^0-9])(\\d{3,5})[xX](\\d{3,5})(?:[^0-9]|$)" options:0 error:nil];NSTextCheckingResult *m=[re firstMatchInString:text options:0 range:NSMakeRange(0,text.length)];if(!m)return nil;NSInteger w=[[text substringWithRange:[m rangeAtIndex:1]] integerValue],h=[[text substringWithRange:[m rangeAtIndex:2]] integerValue];if(outW)*outW=w;if(outH)*outH=h;return w>0&&h>0?[NSString stringWithFormat:@"%ldp · %ld×%ld",(long)MIN(w,h),(long)w,(long)h]:nil;}
static void PVXStart(NSDictionary *row,NSArray *cookies,NSString *ua,NSString *key) {
    NSURL *u=PVXURL(row);
    NSMutableDictionary *base=[@{@"quality":@"分辨率未知",@"sizeText":@"大小未知"} mutableCopy];
    __block PVXMetadataState state={0};
    __block AVURLAsset *asset=nil;
    __block AVAssetImageGenerator *generator=nil;
    __block id previewObserver=nil;
    __block NSUInteger assetAttempt=0;
    __block BOOL borrowedAsset=NO;
    void (^finish)(BOOL)=^(BOOL timeout){
        if(!PVXMetadataTakeDelivery(&state,timeout))return;
        [generator cancelAllCGImageGeneration]; if(!borrowedAsset)[asset cancelLoading];
        if(previewObserver){[[NSNotificationCenter defaultCenter]removeObserver:previewObserver];previewObserver=nil;}
        if(timeout&&!base[@"thumbnail"]&&![base[@"error"] length])base[@"error"]=@"媒体封面读取超时";
        PVXDiagEvent(@"metadata",[base[@"error"] length]?@"failed":@"complete",@{@"kind":row[@"kind"]?:@"",@"url":row[@"url"]?:@"",@"quality":base[@"quality"]?:@"",@"sizeText":base[@"sizeText"]?:@"",@"error":base[@"error"]?:@"",@"hasThumbnail":@([base[@"thumbnail"] isKindOfClass:UIImage.class])});
        PVXDeliver(key,base); PVXMetadataRelease();
    };
    PVXDiagEvent(@"metadata",@"start",@{@"kind":row[@"kind"]?:@"",@"url":row[@"url"]?:@"",@"protocol":row[@"protocol"]?:@""});
    if(!u){base[@"error"]=@"不是有效的 HTTP 媒体 URL";finish(YES);return;}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,25*NSEC_PER_SEC),dispatch_get_main_queue(),^{finish(YES);});
    BOOL image=[row[@"kind"] isEqual:@"image"];
    NSString *protocol=PVXText(row[@"protocol"],32).lowercaseString;
    BOOL manifest=[@[@"hls",@"dash"] containsObject:protocol]||[u.path.lowercaseString containsString:@".m3u8"]||[u.path.lowercaseString containsString:@".mpd"];
    NSMutableURLRequest *q=PVXMetadataRequest(u,row,cookies,ua);
    if(image){
        PVXMediaResourceFetch(q,0,100*1024*1024,^(NSData *d,NSURL *f,NSHTTPURLResponse *h,NSError *e){
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
                NSInteger w=0,hh=0;UIImage *im=f?PVXImageFile(f,&w,&hh):PVXImageData(d,&w,&hh);long long bytes=d.length;
                if(f){bytes=[[[NSFileManager defaultManager]attributesOfItemAtPath:f.path error:nil][NSFileSize] longLongValue];[[NSFileManager defaultManager]removeItemAtURL:f error:nil];}
                dispatch_async(dispatch_get_main_queue(),^{if(state.delivered)return;state.probeDone=state.coverDone=YES;
                    if(!im||e||(h&&!PVXHTTPValid(h)))base[@"error"]=e.localizedDescription?:@"图片响应不是可完整解码的图像";
                    else {base[@"thumbnail"]=im;base[@"sizeText"]=PVXBytes(bytes);base[@"width"]=@(w);base[@"height"]=@(hh);base[@"quality"]=[NSString stringWithFormat:@"%ld×%ld",(long)w,(long)hh];}finish(NO);
                });
            });
        });return;
    }
    if(!manifest)[q setValue:@"bytes=0-0" forHTTPHeaderField:@"Range"];
    PVXMediaResourceFetch(q,manifest?2*1024*1024:128*1024,0,^(NSData *d,NSURL *f,NSHTTPURLResponse *h,NSError *e){
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSInteger w=0,hh=0;NSString *quality=manifest?PVXURLManifestQuality(u,&w,&hh):nil;if(!quality.length&&!e)quality=PVXManifestQuality(d,&w,&hh);long long total=0;BOOL ranged=!e&&PVXHTTPValid(h)&&PVXRange(h,&total);if(!ranged&&!manifest&&!e&&PVXHTTPValid(h))total=PVXResponseLength(h);
            dispatch_async(dispatch_get_main_queue(),^{if(state.delivered)return;if(quality.length){base[@"quality"]=quality;base[@"width"]=@(w);base[@"height"]=@(hh);}if(ranged)base[@"sizeText"]=PVXBytes(total);state.probeDone=YES;finish(NO);});
        });
    });
    // A manifest probe is not a thumbnail. HLS/DASH must also reach the asset path.
    void (^loadAsset)(void)=^{
        if(state.delivered)return;
        NSMutableDictionary *opts=[NSMutableDictionary dictionary];
        // Keep the live jar: AVFoundation filters per request, including variant/key/segment hosts.
        if(cookies.count)opts[AVURLAssetHTTPCookiesKey]=cookies;
        NSMutableDictionary *headers=[PVXMetadataRequest(u,row,cookies,ua).allHTTPHeaderFields mutableCopy];
        [headers removeObjectForKey:@"Cookie"]; // Never pin a master URL's Cookie to every segment host.
        if(headers.count)opts[@"AVURLAssetHTTPHeaderFieldsKey"]=headers;
        [generator cancelAllCGImageGeneration];if(!borrowedAsset)[asset cancelLoading];
        AVURLAsset *ready=[PVXPreviewAssets objectForKey:key];borrowedAsset=ready!=nil;
        asset=ready?:[AVURLAsset URLAssetWithURL:u options:opts];
        AVURLAsset *loadingAsset=asset;NSUInteger attempt=++assetAttempt;
        [loadingAsset loadValuesAsynchronouslyForKeys:@[@"tracks",@"duration"] completionHandler:^{
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
                NSError *error=nil;BOOL loaded=[loadingAsset statusOfValueForKey:@"tracks" error:&error]==AVKeyValueStatusLoaded;
                AVAssetTrack *track=loaded?[loadingAsset tracksWithMediaType:AVMediaTypeVideo].firstObject:nil;
                CGSize z=track?CGSizeApplyAffineTransform(track.naturalSize,track.preferredTransform):CGSizeZero;
                double duration=[loadingAsset statusOfValueForKey:@"duration" error:nil]==AVKeyValueStatusLoaded?CMTimeGetSeconds(loadingAsset.duration):NAN;
                dispatch_async(dispatch_get_main_queue(),^{
                    if(state.delivered||attempt!=assetAttempt)return;
                    if(!track){base[@"error"]=error.localizedDescription?:@"媒体没有可用的视频轨道";state.coverDone=YES;finish(NO);return;}
                    CGFloat w=fabs(z.width),h=fabs(z.height);if(w>0&&h>0){base[@"width"]=@(w);base[@"height"]=@(h);base[@"quality"]=[NSString stringWithFormat:@"%.0fp · %.0f×%.0f",MIN(w,h),w,h];}
                    generator=[[AVAssetImageGenerator alloc]initWithAsset:loadingAsset];generator.appliesPreferredTrackTransform=YES;generator.maximumSize=CGSizeMake(480,480);
                    // Only near-start frames; unknown/live duration permits 0 and short retries.
                    NSMutableArray *times=[NSMutableArray array];
                    for(NSNumber *n in @[@0.0,@0.5,@1.0])if(!isfinite(duration)||duration<=0||n.doubleValue<duration)[times addObject:[NSValue valueWithCMTime:CMTimeMakeWithSeconds(n.doubleValue,600)]];
                    __block NSUInteger remaining=times.count;
                    [generator generateCGImagesAsynchronouslyForTimes:times completionHandler:^(CMTime requested,CGImageRef cg,CMTime actual,AVAssetImageGeneratorResult result,NSError *imageError){
                        UIImage *im=cg?[UIImage imageWithCGImage:cg]:nil;
                        dispatch_async(dispatch_get_main_queue(),^{if(state.delivered||state.coverDone||attempt!=assetAttempt)return;if(remaining)remaining--;if(im){base[@"thumbnail"]=im;state.coverDone=YES;[generator cancelAllCGImageGeneration];}else if(!remaining){base[@"error"]=imageError.localizedDescription?:@"视频首帧不可用";state.coverDone=YES;}finish(NO);});
                    }];
                });
            });
        }];
    };
    previewObserver=[[NSNotificationCenter defaultCenter]addObserverForName:@"PVXPreviewAssetReady" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){
        NSDictionary *source=n.userInfo[@"row"];
        if(!state.delivered&&!state.coverDone&&[source isKindOfClass:NSDictionary.class]&&[PVXMetadataKey(source) isEqual:key]&&[n.object isKindOfClass:AVURLAsset.class]){
            [PVXPreviewAssets setObject:n.object forKey:key];loadAsset();
        }
    }];
    // Only the collector's explicitly associated poster is eligible; no arbitrary page images.
    NSURL *poster=[NSURL URLWithString:PVXText(row[@"poster"],16384)];
    if(poster.host.length&&[@[@"http",@"https"] containsObject:poster.scheme.lowercaseString]){
        NSMutableURLRequest *posterRequest=PVXMetadataRequest(poster,row,cookies,ua);posterRequest.timeoutInterval=8;
        PVXMediaResourceFetch(posterRequest,4*1024*1024,0,^(NSData *d,NSURL *f,NSHTTPURLResponse *h,NSError *e){
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{UIImage *im=!e&&(!h||PVXHTTPValid(h))?PVXImageData(d,NULL,NULL):nil;
                dispatch_async(dispatch_get_main_queue(),^{if(state.delivered)return;if(im){base[@"thumbnail"]=im;state.coverDone=YES;finish(NO);}else loadAsset();});
            });
        });
    }else loadAsset();
}

void PVXFetchMediaMetadata(NSDictionary *row,void(^done)(NSDictionary*)) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{PVXFetchMediaMetadata(row,done);});return;}
    PVXMetadataSetup();row=[row copy];
    // An empty early poster or another frame/session must not poison the later associated row.
    NSString *key=PVXMetadataKey(row);
    NSDictionary *cached=[PVXMetadataCache objectForKey:key];if(cached){if(done)done(cached);return;}
    NSMutableArray *wait=PVXMetadataWaiters[key];if(wait){if(done)[wait addObject:[done copy]];return;}
    wait=[NSMutableArray array];if(done)[wait addObject:[done copy]];PVXMetadataWaiters[key]=wait;
    PVXMetadataSchedule(key,^{
        WKWebView *web=PVXCollectionWebView()?:PVXCurrentWebView();
        __block BOOL started=NO;
        void (^start)(NSArray*,NSString*)=^(NSArray *cookies,NSString *ua){dispatch_async(dispatch_get_main_queue(),^{if(started)return;started=YES;PVXStart(row,cookies,ua,key);});};
        if(!web){start(@[],@"");return;}
        // Cookie/JS callbacks can disappear when the source web view is torn down.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(!started)start(@[],@"");});
        [web.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray *cookies){
            [web evaluateJavaScript:@"navigator.userAgent" completionHandler:^(id value,NSError *error){start(cookies,[value isKindOfClass:NSString.class]?value:@"");}];
        }];
    });
}

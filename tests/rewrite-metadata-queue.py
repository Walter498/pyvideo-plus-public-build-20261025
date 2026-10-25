from pathlib import Path
p=Path('/var/minis/workspace/pyvideo-plus/src/MediaMetadata.m');s=p.read_text();a=s.index('static void PVXMetadataStart(');b=s.index('void PVXFetchMediaMetadata(',a)
new=r'''static dispatch_semaphore_t PVXMetadataSlots;
static void PVXMetadataStart(NSDictionary *row,NSArray *cookies,NSString *ua,NSString *key){
 NSURL *url=PVXMetadataURL(row);if(!url){PVXMetadataDeliver(key,@{@"quality":@"不是媒体 URL",@"sizeText":@"不可下载"});return;}
 NSMutableDictionary *result=[@{@"quality":@"分辨率未知",@"sizeText":([url.path.lowercaseString containsString:@".m3u8"]||[url.path.lowercaseString containsString:@".mpd"])?@"HLS/DASH · 大小下载后确定":@"大小未知"} mutableCopy];
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
  dispatch_semaphore_wait(PVXMetadataSlots,DISPATCH_TIME_FOREVER);
  NSURLSessionConfiguration *cfg=NSURLSessionConfiguration.ephemeralSessionConfiguration;cfg.HTTPCookieStorage=nil;cfg.HTTPShouldSetCookies=NO;cfg.timeoutIntervalForRequest=20;cfg.timeoutIntervalForResource=30;
  NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];request.HTTPMethod=@"HEAD";if(ua.length)[request setValue:ua forHTTPHeaderField:@"User-Agent"];
  NSURLComponents *ref=[NSURLComponents componentsWithString:PVXMetadataText(row[@"page"],16384)];ref.user=nil;ref.password=nil;ref.fragment=nil;if(ref.URL)[request setValue:ref.URL.absoluteString forHTTPHeaderField:@"Referer"];if(cookies.count){NSDictionary *fields=[NSHTTPCookie requestHeaderFieldsWithCookies:cookies];if(fields[@"Cookie"])[request setValue:fields[@"Cookie"] forHTTPHeaderField:@"Cookie"];}
  NSURLSession *session=[NSURLSession sessionWithConfiguration:cfg];
  NSURLSessionDataTask *task=[session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){
   NSHTTPURLResponse *http=[response isKindOfClass:NSHTTPURLResponse.class]?(id)response:nil;long long length=http.expectedContentLength;if(length>0)result[@"sizeText"]=PVXMetadataBytes(length);[session finishTasksAndInvalidate];
   NSMutableDictionary *options=[NSMutableDictionary dictionary];if(cookies.count)options[AVURLAssetHTTPCookiesKey]=cookies;if(ua.length)options[@"AVURLAssetHTTPHeaderFieldsKey"]=@{@"User-Agent":ua};AVURLAsset *asset=[AVURLAsset URLAssetWithURL:url options:options];
   [asset loadValuesAsynchronouslyForKeys:@[@"tracks",@"duration"] completionHandler:^{
    AVAssetTrack *track=[asset tracksWithMediaType:AVMediaTypeVideo].firstObject;CGSize size=track?CGSizeApplyAffineTransform(track.naturalSize,track.preferredTransform):CGSizeZero;CGFloat width=fabs(size.width),height=fabs(size.height);NSString *codec=PVXMetadataCodec(track);
    if(width>0&&height>0){NSString *label=MIN(width,height)>=2160?([NSString stringWithFormat:@"4K · %.0f×%.0f",width,height]):[NSString stringWithFormat:@"%.0fp · %.0f×%.0f",MIN(width,height),width,height];if(codec.length)label=[label stringByAppendingFormat:@" · %@",codec];result[@"quality"]=label;result[@"width"]=@(width);result[@"height"]=@(height);}
    CGImageRef cg=nil;if(track){AVAssetImageGenerator *gen=[[AVAssetImageGenerator alloc] initWithAsset:asset];gen.appliesPreferredTrackTransform=YES;gen.maximumSize=CGSizeMake(480,480);cg=[gen copyCGImageAtTime:CMTimeMake(0,1) actualTime:NULL error:nil];}UIImage *image=cg?[UIImage imageWithCGImage:cg]:nil;if(cg)CGImageRelease(cg);if(image)result[@"thumbnail"]=image;
    dispatch_async(dispatch_get_main_queue(),^{PVXMetadataDeliver(key,result);});dispatch_semaphore_signal(PVXMetadataSlots);
   }];
  }];
  [task resume];
 });
}
'''
s=s[:a]+new+s[b:];s=s.replace('if(!PVXMetadataCache){PVXMetadataCache=[NSCache new];PVXMetadataCache.countLimit=256;PVXMetadataWaiters=[NSMutableDictionary dictionary];}','if(!PVXMetadataCache){PVXMetadataCache=[NSCache new];PVXMetadataCache.countLimit=256;PVXMetadataWaiters=[NSMutableDictionary dictionary];PVXMetadataSlots=dispatch_semaphore_create(2);}',1);p.write_text(s)

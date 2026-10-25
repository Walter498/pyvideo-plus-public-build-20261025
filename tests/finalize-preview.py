from pathlib import Path
p=Path(__file__).resolve().parents[1]/'src/MediaPreview.m';s=p.read_text()
s=s.replace('@property(nonatomic,strong) NSURLSessionDataTask *imageTask;','@property(nonatomic,strong) NSURLSessionTask *imageTask;\n@property(nonatomic,strong) NSURLSession *previewSession;')
a='CGImageSourceRef src=CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],NULL); CGImageRef cg=src?CGImageSourceCreateImageAtIndex(src,0,NULL):NULL; UIImage *image=cg?[UIImage imageWithCGImage:cg]:nil; if(cg)CGImageRelease(cg); if(src)CFRelease(src);'
assert a in s;s=s.replace(a,'UIImage *image=PVXPreviewImage([NSURL fileURLWithPath:path]);',1)
a='for(NSHTTPCookie *c in cookies){NSString *domain=c.domain.lowercaseString; if([domain hasPrefix:@"."])domain=[domain substringFromIndex:1]; BOOL host=[url.host.lowercaseString isEqual:domain]||[url.host.lowercaseString hasSuffix:[@"." stringByAppendingString:domain]]; if(host&&(!c.secure||[url.scheme.lowercaseString isEqual:@"https"])&&(!c.expiresDate||c.expiresDate.timeIntervalSinceNow>0)) [matching addObject:c];}'
assert a in s;s=s.replace(a,'for(NSHTTPCookie *c in cookies)if(PVXPreviewCookie(c,url))[matching addObject:c];',1)
a='for(NSHTTPCookie *c in cookies){NSString *d=c.domain.lowercaseString;if([d hasPrefix:@"."])d=[d substringFromIndex:1];BOOL match=[url.host.lowercaseString isEqual:d]||[url.host.lowercaseString hasSuffix:[@"." stringByAppendingString:d]];if(match&&(!c.secure||[url.scheme.lowercaseString isEqual:@"https"])&&(!c.expiresDate||c.expiresDate.timeIntervalSinceNow>0))[filtered addObject:c];}'
assert a in s;s=s.replace(a,'for(NSHTTPCookie *c in cookies)if(PVXPreviewCookie(c,url))[filtered addObject:c];',1)
a='NSURLSessionDataTask *task=[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){ dispatch_async(dispatch_get_main_queue(),^{'
b='NSURLSessionConfiguration *cfg=NSURLSessionConfiguration.ephemeralSessionConfiguration;cfg.HTTPCookieStorage=nil;cfg.HTTPShouldSetCookies=NO;cfg.timeoutIntervalForResource=60;NSURLSession *session=[NSURLSession sessionWithConfiguration:cfg delegate:[PVXPreviewNetwork new] delegateQueue:nil];weak.previewSession=session;NSURLSessionDownloadTask *task=[session downloadTaskWithRequest:req completionHandler:^(NSURL *file,NSURLResponse *response,NSError *error){struct stat st;BOOL bounded=file&&!lstat(file.fileSystemRepresentation,&st)&&S_ISREG(st.st_mode)&&st.st_size>0&&st.st_size<=100*1024*1024;UIImage *decoded=bounded?PVXPreviewImage(file):nil;[session finishTasksAndInvalidate];dispatch_async(dispatch_get_main_queue(),^{'
assert a in s;s=s.replace(a,b,1)
s=s.replace('data.length>100*1024*1024||!data.length','!bounded',1).replace('UIImage *image=[UIImage imageWithData:data]; if(image)weak.imageView.image=image;','UIImage *image=decoded; if(image)weak.imageView.image=image;',1)
s=s.replace('影片播放失敗','视频播放失败').replace('影片音讯','视频音频').replace('音讯会话','音频会话')
p.write_text(s)

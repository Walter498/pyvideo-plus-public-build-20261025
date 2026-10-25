from pathlib import Path
p=Path('/var/minis/workspace/pyvideo-plus/src/Images.m')
s=p.read_text()
a=s.index('void PVXValidateCollected(')
b=s.index('NSDictionary *PVXActiveVideo',a)
new=r'''static BOOL PVXSnapshotContainsURL(NSDictionary *snapshot,NSDictionary *row){
 NSString *wanted=row[@"url"];if(![wanted isKindOfClass:NSString.class])return NO;
 NSArray *rows=[row[@"kind"] isEqual:@"image"]?snapshot[@"images"]:snapshot[@"videos"];
 if(![rows isKindOfClass:NSArray.class])return NO;
 for(NSDictionary *fresh in rows){
  if([fresh[@"url"] isEqual:wanted])return YES;
  for(NSDictionary *source in fresh[@"sources"])if([source[@"url"] isEqual:wanted])return YES;
 }
 return NO;
}
void PVXValidateCollected(WKWebView *web,NSDictionary *row,void(^done)(BOOL,NSString*)){if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{PVXValidateCollected(web,row,done);});return;}if(!web||![row isKindOfClass:NSDictionary.class]){done(NO,@"");return;}NSString *owner=web.URL.absoluteString?:@"",*frameURL=row[@"frame"]?:row[@"page"];if(![owner isEqual:frameURL]){done(NO,@"");return;}
 WKFrameInfo *frame=nil;for(NSDictionary *s in [[[PVXMediaBridge shared] frames] objectForKey:web].allValues){if([s[@"owner"] isEqual:owner]&&[s[@"frameURL"] isEqual:frameURL]){frame=s[@"frameInfo"];if(frame)break;}}
 id b=PVXBrowser();WKContentWorld *world=PVXGet(b,@"world");if(@available(iOS 14.0,*))world=[WKContentWorld pageWorld];else if(![world isKindOfClass:WKContentWorld.class])world=WKContentWorld.defaultClientWorld;
 NSString *script=@"(()=>{const c=globalThis.__pvxMedia_v1;const s=c&&c.snapshot();return s&&{page:s.page,documentID:s.documentID,images:s.images,videos:s.videos,agent:navigator.userAgent};})()";
 void(^finishSnapshot)(id,NSError*)=^(id result,NSError *error){NSDictionary *snapshot=[result isKindOfClass:NSDictionary.class]?result:nil;NSString *page=snapshot[@"page"],*agent=snapshot[@"agent"];BOOL samePage=!error&&[page isKindOfClass:NSString.class]&&[page isEqual:owner];BOOL source= samePage&&PVXSnapshotContainsURL(snapshot,row);/* Performance candidates are intentionally validated by URL and current page, not stale documentID. */if(!source&&samePage&&[row[@"sourceKind"] isEqual:@"performance"]&&PVXMediaProtocol(row[@"url"]))source=YES;BOOL valid=samePage&&source;done(valid,[agent isKindOfClass:NSString.class]?agent:@"");};
 if(frame&&!frame.isMainFrame)[web evaluateJavaScript:script inFrame:frame inContentWorld:world completionHandler:finishSnapshot];else [web evaluateJavaScript:script inFrame:nil inContentWorld:world completionHandler:finishSnapshot];
}
'''
s=s[:a]+new+s[b:]
p.write_text(s)

p=Path('/var/minis/workspace/pyvideo-plus/src/Collection.m');s=p.read_text()
a=s.index(' PVXValidateCollected(w,c,^(BOOL stillValid')
b=s.index('});});}];});',a)+len('});');old=s[a:b]
new=''' if(finished)return;if(PVXPinGeneration!=generation||![weakWeb.URL.absoluteString isEqual:owner]){finish(nil,@"原始页面已切换，任务未提交。");return;}NSURL *url=PVXCollectionHTTP(c[@"url"]);NSMutableDictionary *headers=[NSMutableDictionary dictionary];NSString *ua=agent.length?agent:currentAgent;if(ua.length&&ua.length<=16384&&[ua rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location==NSNotFound)headers[@"User-Agent"]=ua;NSString *referer=c[@"frame"];if(!([referer hasPrefix:@"https:"]&&[url.scheme.lowercaseString isEqual:@"http"]))headers[@"Referer"]=referer;NSString *uuid=NSUUID.UUID.UUIDString;NSNumber *created=@(NSDate.date.timeIntervalSince1970);NSNumber *height=@0;for(NSDictionary *s in c[@"sources"])if([s[@"url"] isEqual:c[@"url"]]){height=s[@"height"];break;}NSDictionary *request=[kind isEqual:@"image"]?@{@"id":uuid,@"kind":@"image",@"created":created,@"url":c[@"url"],@"title":c[@"title"],@"page":referer,@"headers":headers,@"cookies":PVXCollectionCookies(cookies,url)}:@{@"id":uuid,@"created":created,@"url":c[@"url"],@"title":c[@"title"],@"height":height,@"page":referer,@"poster":c[@"poster"],@"headers":headers,@"cookies":PVXCollectionCookies(cookies,url)};if(!PVXCollectionWrite(request,kind)){finish(nil,@"无法原子写入下载任务，请检查存储空间与权限。");return;}NSDictionary *receipt=@{@"id":uuid,@"state":@"submitted",@"kind":kind,@"title":c[@"title"],@"created":created,@"key":c[@"key"]};[[NSNotificationCenter defaultCenter] postNotificationName:@"PVXTasksChanged" object:nil];finish(receipt,nil);'''
s=s[:a]+new+s[b:]
p.write_text(s)

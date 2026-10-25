from pathlib import Path
p=Path('/var/minis/workspace/pyvideo-plus/src/Images.m')
s=p.read_text()
a=s.index('void PVXValidateCollected(')
b=s.index('NSDictionary *PVXActiveVideo',a)
new=r'''void PVXValidateCollected(WKWebView *web,NSDictionary *row,void(^done)(BOOL,NSString*)){if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{PVXValidateCollected(web,row,done);});return;}if(!web||![row isKindOfClass:NSDictionary.class]){done(NO,@"");return;}NSString *owner=web.URL.absoluteString?:@"",*frameURL=row[@"frame"]?:row[@"page"];if(!PVXImageURL(frameURL)){done(NO,@"");return;}
 WKFrameInfo *frame=nil;for(NSDictionary *s in [[[PVXMediaBridge shared] frames] objectForKey:web].allValues){if([s[@"owner"] isEqual:owner]&&[s[@"frameURL"] isEqual:frameURL]){frame=s[@"frameInfo"];break;}}
 id b=PVXBrowser();WKContentWorld *world=PVXGet(b,@"world");if(@available(iOS 14.0,*))world=[WKContentWorld pageWorld];else if(![world isKindOfClass:WKContentWorld.class])world=WKContentWorld.defaultClientWorld;
 NSString *script=@"(()=>{const c=globalThis.__pvxMedia_v1;const s=c&&c.snapshot();return s&&{page:s.page,documentID:s.documentID,images:s.images,videos:s.videos,agent:navigator.userAgent};})()";
 void(^finishSnapshot)(id,NSError*)=^(id result,NSError *error){NSDictionary *snapshot=[result isKindOfClass:NSDictionary.class]?result:nil;NSString *page=snapshot[@"page"],*agent=snapshot[@"agent"];BOOL samePage=!error&&[page isKindOfClass:NSString.class]&&[page isEqual:frameURL];BOOL source=samePage&&PVXSnapshotContainsURL(snapshot,row);if(!source&&samePage&&[row[@"sourceKind"] isEqual:@"performance"]&&PVXMediaProtocol(row[@"url"]))source=YES;done(samePage&&source,[agent isKindOfClass:NSString.class]?agent:@"");};
 if(frame&&!frame.isMainFrame)[web evaluateJavaScript:script inFrame:frame inContentWorld:world completionHandler:finishSnapshot];else if([frameURL isEqual:owner])[web evaluateJavaScript:script inFrame:nil inContentWorld:world completionHandler:finishSnapshot];else done(NO,@"");
}
'''
s=s[:a]+new+s[b:]
# Insert active runtime export after PVXActiveVideo definition.
needle='NSDictionary *PVXActiveVideo(void){return [[PVXMediaBridge shared] active];}\n'
insert=r'''NSDictionary *PVXActiveVideo(void){return [[PVXMediaBridge shared] active];}
void PVXExportActiveRuntime(void(^completion)(BOOL)){if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{PVXExportActiveRuntime(completion);});return;}WKWebView *web=PVXCollectionWebView();if(!web){if(completion)completion(NO);return;}NSDictionary *best=nil;WKFrameInfo *frame=nil;NSString *owner=web.URL.absoluteString?:@"";for(NSDictionary *s in [[[PVXMediaBridge shared] frames] objectForKey:web].allValues){if(![s[@"owner"] isEqual:owner])continue;NSDictionary *a=s[@"active"];if(![a[@"blob"] boolValue]&&!PVXString(a[@"blobURL"],16384))continue;BOOL foreground=[a[@"fullscreen"] boolValue]||[a[@"pip"] boolValue];BOOL bestForeground=[best[@"fullscreen"] boolValue]||[best[@"pip"] boolValue];if(!best||(foreground&&!bestForeground)||(foreground==bestForeground&&[a[@"at"] doubleValue]>[best[@"at"] doubleValue])){best=a;frame=s[@"frameInfo"];}}
 if(!best){if(completion)completion(NO);return;}WKContentWorld *world=@available(iOS 14.0,*)?[WKContentWorld pageWorld]:WKContentWorld.defaultClientWorld;NSString *script=@"(()=>{const c=globalThis.__pvxMedia_v1;return !!(c&&c.exportActiveRuntime&&c.exportActiveRuntime());})()";void(^finish)(id,NSError*)=^(id value,NSError *error){if(completion)completion(!error&&[value boolValue]);};if(frame&&!frame.isMainFrame)[web evaluateJavaScript:script inFrame:frame inContentWorld:world completionHandler:finish];else[web evaluateJavaScript:script inFrame:nil inContentWorld:world completionHandler:finish];}
'''
assert needle in s
s=s.replace(needle,insert,1)
p.write_text(s)

p=Path('/var/minis/workspace/pyvideo-plus/src/PVXCommon.h');s=p.read_text();s=s.replace('FOUNDATION_EXPORT NSDictionary * _Nullable PVXActiveVideo(void);','FOUNDATION_EXPORT NSDictionary * _Nullable PVXActiveVideo(void);\nFOUNDATION_EXPORT void PVXExportActiveRuntime(void(^ _Nullable completion)(BOOL started));');p.write_text(s)

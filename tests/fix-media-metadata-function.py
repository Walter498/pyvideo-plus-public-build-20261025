from pathlib import Path
p=Path('/var/minis/workspace/pyvideo-plus/src/MediaMetadata.m');s=p.read_text().replace('NSByteCountFormatterDecimal','NSByteCountFormatterCountStyleDecimal')
a=s.index('void PVXFetchMediaMetadata(')
new=r'''void PVXFetchMediaMetadata(NSDictionary *row,void(^done)(NSDictionary *)){if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{PVXFetchMediaMetadata(row,done);});return;}if(!PVXMetadataCache){PVXMetadataCache=[NSCache new];PVXMetadataCache.countLimit=256;PVXMetadataWaiters=[NSMutableDictionary dictionary];}NSString *url=PVXMetadataText(row[@"url"],16384),*key=[NSString stringWithFormat:@"%@|%@",row[@"kind"]?:@"video",url];NSDictionary *cached=[PVXMetadataCache objectForKey:key];if(cached){if(done)done(cached);return;}NSMutableArray *wait=PVXMetadataWaiters[key];if(wait){if(done)[wait addObject:[done copy]];return;}wait=[NSMutableArray array];if(done)[wait addObject:[done copy]];PVXMetadataWaiters[key]=wait;WKWebView *web=PVXCollectionWebView()?:PVXCurrentWebView();if(!web){PVXMetadataStart(row,@[],@"",key);return;}[web.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray *cookies){[web evaluateJavaScript:@"navigator.userAgent" completionHandler:^(id value,NSError *error){PVXMetadataStart(row,cookies,[value isKindOfClass:NSString.class]?value:@"",key);}];}];}
'''
s=s[:a]+new
p.write_text(s)

from pathlib import Path
p=Path('/var/minis/workspace/pyvideo-plus/src/Images.m');s=p.read_text();a=s.index('- (void)mergeResourceURLs:');b=s.index('- (void)refreshForWeb:',a)
method='''- (void)mergeResourceURLs:(NSArray*)urls web:(WKWebView*)w {
    if(!w || ![urls isKindOfClass:NSArray.class] || !urls.count)return;
    NSMutableDictionary *map=[self.frames objectForKey:w];
    if(!map){map=[NSMutableDictionary dictionary];[self.frames setObject:map forKey:w];}
    NSString *owner=w.URL.absoluteString?:@""; NSString *key=nil; NSMutableDictionary *snap=nil;
    for(NSString *candidate in map){NSDictionary *old=map[candidate];if([old[@"owner"] isEqual:owner]){key=candidate;snap=[old mutableCopy];break;}}
    if(!snap){key=[NSString stringWithFormat:@"resource-%lld",(long long)(NSDate.date.timeIntervalSince1970*1000)];snap=[@{ @"images":@[], @"videos":@[], @"runtime":@[], @"owner":owner, @"frameURL":owner, @"at":@(NSDate.date.timeIntervalSince1970) } mutableCopy];}
    NSMutableArray *videos=[snap[@"videos"] mutableCopy]?:[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];
    for(NSDictionary *old in videos)if([old[@"url"] isKindOfClass:NSString.class])[seen addObject:old[@"url"]];
    for(id raw in urls){
        if(![raw isKindOfClass:NSString.class]||![PVXImageURL(raw)])continue;
        NSString *url=raw,*lower=url.lowercaseString,*protocol=[lower containsString:@".m3u8"]?@"hls":([lower containsString:@".mpd"]?@"dash":(([lower containsString:@".mp4"]||[lower containsString:@".m4s"])?@"video":@"network"));
        if([seen containsObject:url])continue;[seen addObject:url];
        [videos addObject:@{ @"kind":@"video", @"url":url, @"protocol":protocol, @"sourceKind":@"performance", @"sources":@[@{ @"url":url, @"height":@0 }], @"height":@0, @"title":@"网页媒体源", @"poster":@"", @"page":owner, @"frame":owner, @"key":[NSString stringWithFormat:@"%@|video|%@",key,url] }];
    }
    snap[@"videos"]=videos;map[key]=snap;[[NSNotificationCenter defaultCenter] postNotificationName:@"PVXMediaChanged" object:w];
}
'''
s=s[:a]+method+s[b:];p.write_text(s)

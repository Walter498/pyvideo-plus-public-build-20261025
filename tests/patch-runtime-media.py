from pathlib import Path
p=Path('/var/minis/workspace/pyvideo-plus/src/Images.m');s=p.read_text()
old='NSMutableDictionary *snapshot=[@{@"images":images,@"videos":videos,@"owner":owner,@"frameURL":m[@"page"],@"at":@(NSDate.date.timeIntervalSince1970),@"frameInfo":message.frameInfo} mutableCopy];'
new='''NSMutableArray *runtime=[NSMutableArray array];for(id rr in m[@"runtime"]){if([rr isKindOfClass:NSDictionary.class]&&[rr[@"protocol"] isEqual:@"mse"])[runtime addObject:@{ @"kind":@"runtime", @"protocol":@"mse", @"mime":rr[@"mime"]?:@"", @"blob":rr[@"blob"]?:@"", @"title":rr[@"title"]?:@"当前运行时媒体" }];}
 NSMutableDictionary *snapshot=[@{@"images":images,@"videos":videos,@"runtime":runtime,@"owner":owner,@"frameURL":m[@"page"],@"at":@(NSDate.date.timeIntervalSince1970),@"frameInfo":message.frameInfo} mutableCopy];'''
assert old in s;s=s.replace(old,new,1);p.write_text(s)

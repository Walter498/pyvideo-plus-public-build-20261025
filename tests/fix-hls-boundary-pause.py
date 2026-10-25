from pathlib import Path
p=Path('/var/minis/workspace/pyvideo-plus/src/TaskSupport.m');s=p.read_text()
old='''void PVXTaskAction(NSDictionary *task, NSString *action) {
    if ([action isEqual:@"delete"]) {
        PVXDeleteTasks(@[task], ^(NSString *error) { if (error) PVXAlert(@"删除未完成", error); });
        return;
    }
    NSDictionary *copy=[task copy];NSString *requested=[action copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSError *error=nil;BOOL ok=PVXQueueControl(copy,requested,&error);if(!ok)dispatch_async(dispatch_get_main_queue(),^{PVXAlert(@"任务操作失败", @"下载服务接口不可用或操作不受支持");});});
}'''
new='''static NSDictionary *PVXFindLiveTask(NSString *uuid){for(NSDictionary *row in PVXReadVideoTasks())if([row[@"id"] isEqual:uuid])return row;return nil;}
static void PVXQueuePauseAtSegmentBoundary(NSDictionary *task){
    NSString *uuid=PVXSafeText(task[@"id"],64);NSNumber *initial=task[@"segmentsDone"];
    if(!initial){NSError *error=nil;if(!PVXQueueControl(task,@"pause",&error))dispatch_async(dispatch_get_main_queue(),^{PVXAlert(@"任务操作失败",@"暂停请求未入队");});return;}
    NSTimeInterval deadline=NSDate.date.timeIntervalSince1970+20;
    while(NSDate.date.timeIntervalSince1970<deadline){NSDictionary *live=PVXFindLiveTask(uuid);NSString *state=PVXSafeText(live[@"state"],32);NSNumber *done=live[@"segmentsDone"];if(!live||![[@[@"queued",@"downloading",@"hls",@"remuxing",@"converting",@"checking"]] containsObject:state]||[done longLongValue]>[initial longLongValue])break;usleep(100000);}
    NSError *error=nil;if(!PVXQueueControl(task,@"pause",&error))dispatch_async(dispatch_get_main_queue(),^{PVXAlert(@"任务操作失败",@"暂停请求未入队");});
}
void PVXTaskAction(NSDictionary *task, NSString *action) {
    if ([action isEqual:@"delete"]) {
        PVXDeleteTasks(@[task], ^(NSString *error) { if (error) PVXAlert(@"删除未完成", error); });
        return;
    }
    NSDictionary *copy=[task copy];NSString *requested=[action copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        if([requested isEqual:@"pause"]){PVXQueuePauseAtSegmentBoundary(copy);return;}
        NSError *error=nil;BOOL ok=PVXQueueControl(copy,requested,&error);if(!ok)dispatch_async(dispatch_get_main_queue(),^{PVXAlert(@"任务操作失败", @"下载服务接口不可用或操作不受支持");});
    });
}'''
assert old in s;s=s.replace(old,new,1);p.write_text(s)

p=Path('/var/minis/workspace/pyvideo-plus/src/DownloadsUI.m');s=p.read_text();s=s.replace('self.feedback.text=@"正在暂停下载";}else if([@[@"failed",@"albumFailed"] containsObject:state])action=@"retry";', 'self.feedback.text=@"等待当前分片完成后暂停";}else if([@[@"failed",@"albumFailed"] containsObject:state])action=@"retry";',1);p.write_text(s)

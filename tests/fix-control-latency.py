from pathlib import Path
p=Path('/var/minis/workspace/pyvideo-plus/src/DownloadsUI.m');s=p.read_text()
# Add a control request gate so rapid taps cannot enqueue pause twice or turn pause into retry/restart.
s=s.replace('@property(nonatomic,strong)NSMutableDictionary<NSString*,NSDictionary*> *submissions;','@property(nonatomic,strong)NSMutableDictionary<NSString*,NSDictionary*> *submissions;\n@property(nonatomic,strong)NSMutableDictionary<NSString*,NSString*> *controlPending;',1)
s=s.replace('self.submissions=[NSMutableDictionary dictionary];self.closeButton=', 'self.submissions=[NSMutableDictionary dictionary];self.controlPending=[NSMutableDictionary dictionary];self.closeButton=',1)
old='''- (void)toggleTransfer:(NSDictionary*)r{NSDictionary *task=r[@"linkedTask"]?:r;if(!task[@"id"]){[self submitRows:@[r]];return;}NSString *state=PVXText(task[@"state"]);if([state isEqual:@"paused"]){PVXTaskAction(task,@"resume");self.feedback.text=@"正在继续下载";}else if([@[@"queued",@"downloading",@"hls",@"checking",@"converting",@"remuxing"] containsObject:state]){PVXTaskAction(task,@"pause");self.feedback.text=@"正在暂停下载";}else if([@[@"failed",@"albumFailed"] containsObject:state])PVXTaskAction(task,@"retry");[self readData];}'''
new='''- (void)toggleTransfer:(NSDictionary*)r{NSDictionary *task=r[@"linkedTask"]?:r;if(!task[@"id"]){[self submitRows:@[r]];return;}NSString *uuid=PVXText(task[@"id"]);if(self.controlPending[uuid])return;NSString *state=PVXText(task[@"state"]);NSString *action=nil;if([state isEqual:@"paused"]){action=@"resume";self.feedback.text=@"正在继续下载";}else if([state isEqual:@"pausing"]){self.feedback.text=@"正在暂停下载，请等待状态更新";return;}else if([@[@"queued",@"downloading",@"hls",@"checking",@"converting",@"remuxing"] containsObject:state]){action=@"pause";self.feedback.text=@"正在暂停下载";}else if([@[@"failed",@"albumFailed"] containsObject:state])action=@"retry";if(!action)return;self.controlPending[uuid]=action;PVXTaskAction(task,action);__weak typeof(self)weak=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,1.2*NSEC_PER_SEC),dispatch_get_main_queue(),^{[weak.controlPending removeObjectForKey:uuid];[weak readData];});[self readData];}'''
assert old in s;s=s.replace(old,new,1)
p.write_text(s)

# Task control must not block the UI while writing the control IPC.
p=Path('/var/minis/workspace/pyvideo-plus/src/TaskSupport.m');s=p.read_text()
old='''    NSError *error = nil;
    if (!PVXQueueControl(task, action, &error)) PVXAlert(@"任务操作失败", @"下载服务接口不可用或操作不受支持");'''
new='''    NSDictionary *copy=[task copy];NSString *requested=[action copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSError *error=nil;BOOL ok=PVXQueueControl(copy,requested,&error);if(!ok)dispatch_async(dispatch_get_main_queue(),^{PVXAlert(@"任务操作失败", @"下载服务接口不可用或操作不受支持");});});'''
assert old in s;s=s.replace(old,new,1)
p.write_text(s)

from pathlib import Path
p=Path('/var/minis/workspace/pyvideo-plus/src/TaskSupport.m');s=p.read_text();a=s.index('void PVXRequestTaskSnapshot(');b=s.index('NSArray<NSDictionary*> *PVXReadVideoTasks',a)
new=r'''void PVXRequestTaskSnapshot(void(^completion)(NSArray<NSDictionary*>*,NSDictionary*)) {
 PVXSnapshotSetup();[PVXSnapshotLock lock];if(completion)[PVXSnapshotCallbacks addObject:[completion copy]];if(PVXSnapshotRunning){[PVXSnapshotLock unlock];return;}PVXSnapshotRunning=YES;[PVXSnapshotLock unlock];
 dispatch_async(PVXSnapshotQueue,^{@autoreleasepool{
  NSArray *rows=PVXScanVideoTasks();static NSTimeInterval lastStorage;NSTimeInterval now=NSDate.date.timeIntervalSince1970;NSDictionary *cached=PVXSnapshotStorage?:@{};BOOL refreshStorage=!cached.count||now-lastStorage>=15;
  [PVXSnapshotLock lock];PVXSnapshotRows=rows;NSArray *first=[PVXSnapshotCallbacks copy];[PVXSnapshotCallbacks removeAllObjects];[PVXSnapshotLock unlock];
  dispatch_async(dispatch_get_main_queue(),^{for(void(^block)(NSArray*,NSDictionary*) in first)block(rows,cached);});
  if(refreshStorage){NSDictionary *storage=PVXStorageSummary();lastStorage=NSDate.date.timeIntervalSince1970;[PVXSnapshotLock lock];PVXSnapshotStorage=storage;NSArray *second=[PVXSnapshotCallbacks copy];[PVXSnapshotCallbacks removeAllObjects];PVXSnapshotRunning=NO;[PVXSnapshotLock unlock];dispatch_async(dispatch_get_main_queue(),^{for(void(^block)(NSArray*,NSDictionary*) in second)block(rows,storage);});}
  else{[PVXSnapshotLock lock];PVXSnapshotRunning=NO;NSArray *late=[PVXSnapshotCallbacks copy];[PVXSnapshotCallbacks removeAllObjects];[PVXSnapshotLock unlock];dispatch_async(dispatch_get_main_queue(),^{for(void(^block)(NSArray*,NSDictionary*) in late)block(rows,cached);});}
 }});
}
'''
s=s[:a]+new+s[b:];p.write_text(s)

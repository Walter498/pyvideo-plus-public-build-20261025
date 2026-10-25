from pathlib import Path
p=Path('/var/minis/workspace/pyvideo-plus/src/DownloadsUI.m')
s=p.read_text();a=s.index('- (void)readData{');b=s.index('- (void)applyFilter:',a)
new=r'''- (void)readData{
 if(self.reading||self.rangeDisplay)return;
 self.reading=YES;NSInteger mode=self.mainTabs.selectedSegmentIndex;NSString *kind=[self.kind copy];__weak typeof(self)weak=self;
 if(mode==1){
  NSArray *media=[PVXCollectedMedia(kind) copy];
  /* Use the already cached task snapshot for collection linking. This path
     never waits for a disk scan or storage-size enumeration. */
  NSArray *cachedTasks=[PVXReadVideoTasks() copy]?:@[];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
   NSMutableArray *list=[NSMutableArray arrayWithCapacity:media.count];
   for(NSDictionary *row in media){NSMutableDictionary *r=[row mutableCopy];NSDictionary *task=PVXLinkedTask(row,cachedTasks);if(task)r[@"linkedTask"]=task;[list addObject:r];}
   dispatch_async(dispatch_get_main_queue(),^{PVXManager *manager=weak;if(!manager)return;manager.reading=NO;if(mode!=manager.mainTabs.selectedSegmentIndex||![kind isEqual:manager.kind]||manager.rangeDisplay)return;for(NSMutableDictionary *r in list){NSString *key=PVXRowID(r);if([manager.pending containsObject:key])r[@"submissionState"]=@"正在提交请求…";else if(manager.submissions[key])r[@"submissionState"]=@"已提交 · 下载页可查看状态";}manager.allRows=list;[manager applyFilter:NO];});
  });return;
 }
 PVXRequestTaskSnapshot(^(NSArray *tasks,NSDictionary *space){PVXManager *manager=weak;if(!manager)return;manager.reading=NO;if(mode!=manager.mainTabs.selectedSegmentIndex||![kind isEqual:manager.kind]||manager.rangeDisplay){[manager readData];return;}manager.allRows=tasks;manager.spaceLabel.text=PVXText(space[@"text"]);PVXApplyAutoSavePreferences(tasks);[manager applyFilter:NO];});
}
'''
s=s[:a]+new+s[b:];p.write_text(s)

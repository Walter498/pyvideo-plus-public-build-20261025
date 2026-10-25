from pathlib import Path
P=Path(__file__).resolve().parents[1]
p=P/'src/DownloadsUI.m';s=p.read_text();a=s.index('- (void)readData{');b=s.index('- (void)applyFilter:',a)
s=s[:a]+'''- (void)readData{
    if(self.reading||self.rangeDisplay)return;
    self.reading=YES;NSInteger mode=self.mainTabs.selectedSegmentIndex;NSString *kind=[self.kind copy];
    // WK access is main-thread only; take just the in-memory DOM snapshot here.
    NSArray *media=mode==1?[PVXCollectedMedia(kind) copy]:nil;
    __weak typeof(self)weak=self;
    PVXRequestTaskSnapshot(^(NSArray *tasks,NSDictionary *space){
        PVXManager *manager=weak;if(!manager)return;manager.reading=NO;
        if(mode!=manager.mainTabs.selectedSegmentIndex||![kind isEqual:manager.kind]||manager.rangeDisplay){[manager readData];return;}
        if(mode==0){manager.allRows=tasks;manager.spaceLabel.text=PVXText(space[@"text"]);[manager applyFilter:NO];return;}
        // Link-file reads also stay off the main thread (hundreds of candidates).
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
            NSMutableArray *list=[NSMutableArray array];
            for(NSDictionary *row in media){NSMutableDictionary *r=[row mutableCopy];NSDictionary *task=PVXLinkedTask(row,tasks);if(task)r[@"linkedTask"]=task;[list addObject:r];}
            dispatch_async(dispatch_get_main_queue(),^{PVXManager *self=weak;if(!self)return;if(mode!=self.mainTabs.selectedSegmentIndex||![kind isEqual:self.kind]||self.rangeDisplay)return;
                for(NSUInteger i=0;i<list.count;i++){NSMutableDictionary *r=list[i];NSString *key=PVXRowID(r);if([self.pending containsObject:key])r[@"submissionState"]=@"正在提交请求…";else if(self.submissions[key])r[@"submissionState"]=@"已提交 · 下载页可查看状态";}
                self.allRows=list;self.spaceLabel.text=PVXText(space[@"text"]);[self applyFilter:NO];
            });
        });
    });
}
''' +s[b:];p.write_text(s)
p=P/'src/PVXCommon.h';s=p.read_text();a='FOUNDATION_EXPORT NSArray<NSDictionary*> *PVXReadVideoTasks(void);';assert a in s;s=s.replace(a,a+'\nFOUNDATION_EXPORT void PVXRequestTaskSnapshot(void(^ _Nullable completion)(NSArray<NSDictionary*> *rows, NSDictionary *storage));',1);p.write_text(s)

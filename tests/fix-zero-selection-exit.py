from pathlib import Path
p=Path('/var/minis/workspace/pyvideo-plus/src/DownloadsUI.m');s=p.read_text()
old='for(NSInteger i=lo;i<=hi;i++){NSString *key=PVXRowID(self.rangeRows[(NSUInteger)i]);if(self.rangeSelecting)[self.selection addObject:key];else[self.selection removeObject:key];}[self applyFilter:NO];}'
new='for(NSInteger i=lo;i<=hi;i++){NSString *key=PVXRowID(self.rangeRows[(NSUInteger)i]);if(self.rangeSelecting)[self.selection addObject:key];else[self.selection removeObject:key];}if(self.selecting&&!self.selection.count){[self finishSelection];return;}[self applyFilter:NO];}'
assert old in s;s=s.replace(old,new,1)
old='- (void)selectAll{if(self.selection.count==self.rows.count)[self.selection removeAllObjects];else for(NSDictionary *r in self.rows)[self.selection addObject:PVXRowID(r)];[self applyFilter:NO];}'
new='- (void)selectAll{if(self.selection.count==self.rows.count){[self finishSelection];return;}for(NSDictionary *r in self.rows)[self.selection addObject:PVXRowID(r)];[self applyFilter:NO];}'
assert old in s;s=s.replace(old,new,1)
p.write_text(s)

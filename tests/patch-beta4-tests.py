from pathlib import Path
p=Path(__file__).resolve().parent/'webkit-beta3-ui.m';s=p.read_text()
s=s.replace('@property(nonatomic) BOOL started;','@property(nonatomic) BOOL started;\n@property(nonatomic) BOOL remoteThumbValid;')
a='PVXSubmitMedia(images[0],^(NSDictionary *receipt,NSString *error){'
assert a in s;s=s.replace(a,'PVXFetchTaskThumbnail(images[0],^(UIImage *image){self.remoteThumbValid=image!=nil;});\n    '+a,1)
a='Check(m.rows.count==2,@"collect all count restored");'
assert a in s;s=s.replace(a,a+'\n        Check(self.remoteThumbValid,@"remote collected image URL generated actual thumbnail with origin cookies");',1)
a='Check(m.selection.count==0&&!m.batchExport.enabled,@"select all toggles off and disables empty batch");'
assert a in s;s=s.replace(a,a+'\n        m.rangeBase=[NSSet set];m.rangeRows=[m.rows copy];m.rangeStart=0;m.rangeSelecting=YES;[m applyRangeToRow:1];Check(m.selection.count==2,@"long press range selects downwards");[m applyRangeToRow:0];Check(m.selection.count==1,@"reverse drag contracts selected range");m.rangeSelecting=NO;m.rangeBase=[NSSet setWithArray:@[PVXRowID(m.rows[0]),PVXRowID(m.rows[1])]];[m applyRangeToRow:1];Check(m.selection.count==0,@"long press selected range deselects downwards");m.rangeRows=nil;m.rangeBase=nil;',1)
a='Check(m.timer.valid&&m.visible,@"production one-second refresh timer active before menu");'
assert a in s;s=s.replace(a,a+'\n        PVXMediaRow *dated=[m.table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];Check([dated.dateLabel.text hasPrefix:@"下载日期："]&&[dated.dateLabel.text containsString:@"/"]&&[dated.dateLabel.text containsString:@":"],@"real created timestamp rendered as month/day hour:minute");',1)
p.write_text(s)

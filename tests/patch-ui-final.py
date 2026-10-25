from pathlib import Path
P=Path('/var/minis/workspace/pyvideo-plus')
# Swipe delete must not show a confirmation; normal row-menu deletion keeps confirmation.
p=P/'src/DownloadsUI.m';s=p.read_text()
old='__weak typeof(self)w=self;UIContextualAction*d=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除" handler:^(UIContextualAction*a,UIView*v,void(^done)(BOOL)){done(YES);[w confirmDelete:@[task]];}];'
new='__weak typeof(self)w=self;UIContextualAction*d=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除" handler:^(UIContextualAction*a,UIView*v,void(^done)(BOOL)){done(YES);PVXDeleteTasks(@[task],^(NSString*e){if(e.length)PVXAlert(@"删除未完成",e);[w readData];});}];'
assert old in s;s=s.replace(old,new,1)
# call auto-save for ready task snapshots, then add playback settings menu item
old='if(mode==0){manager.allRows=tasks;manager.spaceLabel.text=PVXText(space[@"text"]);[manager applyFilter:NO];return;}'
new='if(mode==0){manager.allRows=tasks;manager.spaceLabel.text=PVXText(space[@"text"]);PVXApplyAutoSavePreferences(tasks);[manager applyFilter:NO];return;}'
assert old in s;s=s.replace(old,new,1)
old='UIAction *settings=[UIAction actionWithTitle:@"下载设置" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(UIAction*x){[w openSettings];}];return [UIMenu'
new='UIAction *settings=[UIAction actionWithTitle:@"下载设置" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(UIAction*x){[w openSettings];}];UIAction *playSettings=[UIAction actionWithTitle:@"播放设置" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(UIAction*x){[w openPlaybackSettings];}];return [UIMenu'
assert old in s;s=s.replace(old,new,1)
s=s.replace('children:@[settings]]]];}', 'children:@[settings,playSettings]]]];}',1)
# add playback setting method beside openSettings
needle='- (void)openSettings{'
idx=s.index(needle)
method='- (void)openPlaybackSettings{BOOL autoPlay=[NSUserDefaults.standardUserDefaults objectForKey:@"com.crctdd.pyvideo.plus.autoPlay"]==nil?YES:[NSUserDefaults.standardUserDefaults boolForKey:@"com.crctdd.pyvideo.plus.autoPlay"];UIAlertController*a=[UIAlertController alertControllerWithTitle:@"播放设置" message:nil preferredStyle:UIAlertControllerStyleActionSheet];[a addAction:[UIAlertAction actionWithTitle:autoPlay?@"自动播放：开（点击关闭）":@"自动播放：关（点击开启）" style:UIAlertActionStyleDefault handler:^(UIAlertAction*x){[NSUserDefaults.standardUserDefaults setBool:!autoPlay forKey:@"com.crctdd.pyvideo.plus.autoPlay"];}]];[a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];a.popoverPresentationController.sourceView=self.moreButton;a.popoverPresentationController.sourceRect=self.moreButton.bounds;[self presentViewController:a animated:YES completion:nil];}\n'
s=s[:idx]+method+s[idx:]
p.write_text(s)
# Export direct system player URL for the top menu's new playback task.
p=P/'src/PVXCommon.h';s=p.read_text();s=s.replace('FOUNDATION_EXPORT void PVXPreviewMedia(NSDictionary *row);','FOUNDATION_EXPORT void PVXPreviewMedia(NSDictionary *row);\nFOUNDATION_EXPORT void PVXPlayVideoURL(NSString *url);',1);p.write_text(s)
p=P/'src/SystemVideoPreview.inc';s=p.read_text();
if 'void PVXPlayVideoURL(NSString *url)' not in s:s += '\nvoid PVXPlayVideoURL(NSString *url){NSURL *u=[NSURL URLWithString:url?:@""];if(!u.host.length||![@[@"http",@"https"] containsObject:u.scheme.lowercaseString]){PVXAlert(@"无法播放",@"视频 URL 无效。");return;}PVXPresentSystemVideo(u,@{});}\n'
p=P/'src/SystemVideoPreview.inc';p.write_text(s)
# Make top menu use direct system player URL for arbitrary URL instead of only collected media.
p=P/'src/DownloadsUI.m';s=p.read_text();old='for(NSDictionary*r in PVXCollectedMedia(@"video"))if([r[@"url"] isEqual:u]){PVXPreviewMedia(r);return;}PVXAlert(@"无法播放",@"该 URL 尚未被当前网页采集。");'
new='if(u.length){PVXPlayVideoURL(u);return;}PVXAlert(@"无法播放",@"请输入视频 URL。");'
assert old in s;s=s.replace(old,new,1);p.write_text(s)

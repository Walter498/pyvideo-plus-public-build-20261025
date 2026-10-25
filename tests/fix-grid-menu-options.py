from pathlib import Path
p=Path('/var/minis/workspace/pyvideo-plus/src/DownloadsUI.m');s=p.read_text()
# Grid cell persistent selection marker.
s=s.replace('@property(nonatomic,strong)UIImageView *cover;@property(nonatomic,strong)UILabel *title,*status;@property(nonatomic,copy)NSString *identity;','@property(nonatomic,strong)UIImageView *cover,*selectionIcon;@property(nonatomic,strong)UILabel *title,*status;@property(nonatomic,copy)NSString *identity;',1)
s=s.replace('_cover=[UIImageView new];_cover.contentMode=UIViewContentModeScaleAspectFill;', '_cover=[UIImageView new];_cover.contentMode=UIViewContentModeScaleAspectFill;_selectionIcon=[UIImageView new];_selectionIcon.image=[UIImage systemImageNamed:@"checkmark.circle.fill"];_selectionIcon.tintColor=UIColor.systemBlueColor;_selectionIcon.hidden=YES;',1)
s=s.replace('for(UIView *v in @[_cover,_title,_status])[self.contentView addSubview:v];','for(UIView *v in @[_cover,_selectionIcon,_title,_status])[self.contentView addSubview:v];',1)
s=s.replace('self.cover.frame=CGRectMake(0,0,w,w*.62);self.title.frame=', 'self.cover.frame=CGRectMake(0,0,w,w*.62);self.selectionIcon.frame=CGRectMake(w-30,8,22,22);self.title.frame=',1)
# Remove bottom More button entirely.
s=s.replace('*batchExport,*batchDelete,*batchMore;', '*batchExport,*batchDelete;',1)
s=s.replace('self.batchMore=[self button:@"更多" symbol:nil action:@selector(moreSelected)];for(UIView *v in @[self.batchExport,self.batchDelete,self.batchMore])[self.batchBar addSubview:v];','for(UIView *v in @[self.batchExport,self.batchDelete])[self.batchBar addSubview:v];',1)
s=s.replace('self.batchMore.enabled=self.selection.count>0;','',1)
s=s.replace('self.batchMore.hidden=self.mainTabs.selectedSegmentIndex==1;','',1)
s=s.replace('CGFloat bw=self.batchBar.bounds.size.width/3;self.batchExport.frame=CGRectMake(0,2,bw,48);self.batchDelete.frame=CGRectMake(bw,2,bw,48);self.batchMore.frame=CGRectMake(2*bw,2,bw,48);','CGFloat bw=self.batchBar.bounds.size.width/2;self.batchExport.frame=CGRectMake(0,2,bw,48);self.batchDelete.frame=CGRectMake(bw,2,bw,48);',1)
# Grid must reload whenever filter/order changes, not only UITableView.
s=s.replace('if(structural)[self.table reloadData];else for(NSIndexPath *path in self.table.indexPathsForVisibleRows){','if(structural){[self.table reloadData];[self.grid reloadData];}else for(NSIndexPath *path in self.table.indexPathsForVisibleRows){',1)
s=s.replace('}if(!next.count){UILabel *label=', '}[self.grid reloadData];if(!next.count){UILabel *label=',1)
# Grid cell applies current filtered/sorted row and selected visual.
old='c.identity=PVXRowID(r);c.title.text=PVXText(r[@"title"]);c.status.text=PVXTaskPresentation(r)[@"status"];c.cover.image=[UIImage systemImageNamed:[r[@"kind"] isEqual:@"image"]?@"photo":@"play.rectangle"];'
new='c.identity=PVXRowID(r);c.selectionIcon.hidden=!self.selecting||![self.selection containsObject:c.identity];c.title.text=PVXText(r[@"title"]);c.status.text=PVXTaskPresentation(r)[@"status"];c.cover.image=[UIImage systemImageNamed:[r[@"kind"] isEqual:@"image"]?@"photo":@"play.rectangle"];'
assert old in s;s=s.replace(old,new,1)
# Remove unusable creation and playback menu entries; retain display, batch, download settings.
start=s.index('- (UIMenu*)topMenu{')
end=s.index('\n- (void)batchTransfer:',start)
newmenu='''- (UIMenu*)topMenu{__weak typeof(self)w=self;UIAction *icon=[UIAction actionWithTitle:@"图标" image:[UIImage systemImageNamed:@"square.grid.2x2"] identifier:nil handler:^(UIAction*x){[w setGridMode:YES];}];UIAction *list=[UIAction actionWithTitle:@"列表" image:[UIImage systemImageNamed:@"list.bullet"] identifier:nil handler:^(UIAction*x){[w setGridMode:NO];}];icon.state=self.gridMode?UIMenuElementStateOn:UIMenuElementStateOff;list.state=!self.gridMode?UIMenuElementStateOn:UIMenuElementStateOff;UIAction *pause=[UIAction actionWithTitle:@"全部暂停下载" image:[UIImage systemImageNamed:@"pause.circle"] identifier:nil handler:^(UIAction*x){[w batchTransfer:@"pause"];}];UIAction *resume=[UIAction actionWithTitle:@"全部开始下载" image:[UIImage systemImageNamed:@"play.circle"] identifier:nil handler:^(UIAction*x){[w batchTransfer:@"resume"];}];UIAction *settings=[UIAction actionWithTitle:@"下载设置" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(UIAction*x){[w openSettings];}];return [UIMenu menuWithTitle:@"" children:@[[UIMenu menuWithTitle:@"显示模式" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[icon,list]],[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[pause,resume]],[UIMenu menuWithTitle:@"设置" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[settings]]]];}'''
s=s[:start]+newmenu+s[end:]
# Remove unreachable batch more method if still present.
s=s.replace('- (void)moreSelected{[self showMenu:[self selectedRows] anchor:self.batchMore];}\n','',1)
p.write_text(s)

# Make Player overflow menu rebuilt on every opening, removing stale injected actions first.
p=Path('/var/minis/workspace/pyvideo-plus/src/Player.m');s=p.read_text()
start=s.index('static BOOL PVXPlayerContainsAction(');end=s.index('\nstatic UIAction *PVXPlayerDownloadAction',start)
helper='''static NSArray *PVXPlayerStripInjected(NSArray *children){NSMutableArray *out=[NSMutableArray array];for(UIMenuElement *item in children){if([item isKindOfClass:UIAction.class]&&([((UIAction*)item).identifier isEqual:@"com.crctdd.pyvideo.plus.download-current-video"]||[((UIAction*)item).identifier isEqual:@"com.crctdd.pyvideo.plus.player-manager"]))continue;if([item isKindOfClass:UIMenu.class]){UIMenu*m=(UIMenu*)item;[out addObject:[m menuByReplacingChildren:PVXPlayerStripInjected(m.children)]];}else [out addObject:item];}return out;}\n'''
s=s[:start]+helper+s[end:]
old='''    if (PVXPlayerContainsAction(children, 0)) return original;
    UIAction *manager = [UIAction actionWithTitle:@"下载管理"'''
new='''    children=PVXPlayerStripInjected(children);
    UIAction *manager = [UIAction actionWithTitle:@"下载管理"'''
assert old in s;s=s.replace(old,new,1)
p.write_text(s)

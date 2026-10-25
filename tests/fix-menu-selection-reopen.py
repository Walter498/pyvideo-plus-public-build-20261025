from pathlib import Path
p=Path('/var/minis/workspace/pyvideo-plus/src/DownloadsUI.m');s=p.read_text()
# The right-side row command is not a multi-select control.
old='cell.command.showsMenuAsPrimaryAction=YES;cell.command.menu=[weak rowMenu:r];cell.pressed=^(NSString *identity,UIView *anchor){[weak commandForID:identity anchor:anchor];};'
new='cell.command.hidden=weak.selecting;cell.command.showsMenuAsPrimaryAction=!weak.selecting;cell.command.menu=weak.selecting?nil:[weak rowMenu:r];cell.pressed=^(NSString *identity,UIView *anchor){if(!weak.selecting)[weak commandForID:identity anchor:anchor];};'
assert old in s;s=s.replace(old,new,1)
# Make selection mode a real state machine; zero selected rows exits immediately.
old='- (void)toggleRow:(NSDictionary*)r{NSString *key=PVXRowID(r);if([self.selection containsObject:key])[self.selection removeObject:key];else[self.selection addObject:key];[self applyFilter:NO];}'
new='''- (void)finishSelection{
    [self endRange];self.selecting=NO;[self.selection removeAllObjects];self.batchBar.hidden=YES;self.allButton.hidden=YES;self.moreButton.hidden=NO;self.moreButton.menu=[self topMenu];[self.view setNeedsLayout];[self applyFilter:YES];
}
- (void)toggleRow:(NSDictionary*)r{NSString *key=PVXRowID(r);if([self.selection containsObject:key])[self.selection removeObject:key];else[self.selection addObject:key];if(self.selecting&&!self.selection.count){[self finishSelection];return;}[self applyFilter:NO];}'''
assert old in s;s=s.replace(old,new,1)
# Long press starts selection and keeps row command menus disabled.
old='if(!self.selecting){self.selecting=YES;self.batchBar.hidden=NO;self.allButton.hidden=YES;[self.view setNeedsLayout();}'
# exact source has no semicolon after setNeedsLayout? inspect known string
if old not in s:
 old='if(!self.selecting){self.selecting=YES;self.batchBar.hidden=NO;self.allButton.hidden=YES;[self.view setNeedsLayout];}'
new='if(!self.selecting){self.selecting=YES;self.batchBar.hidden=NO;self.allButton.hidden=YES;self.moreButton.hidden=YES;self.moreButton.menu=nil;[self.view setNeedsLayout];}'
assert old in s;s=s.replace(old,new,1)
# Existing toggleSelection is retained for internal callers, but it must restore the top menu correctly.
old='- (void)toggleSelection{self.selecting=!self.selecting;[self.selection removeAllObjects];self.allButton.hidden=!self.selecting;self.batchBar.hidden=!self.selecting;[self.batchExport setTitle:self.mainTabs.selectedSegmentIndex?@"下载所选":@"导出" forState:UIControlStateNormal];self.batchDelete.hidden=self.mainTabs.selectedSegmentIndex==1;self.batchMore.hidden=self.mainTabs.selectedSegmentIndex==1;[self.view setNeedsLayout];[self applyFilter:NO];}'
new='''- (void)toggleSelection{if(self.selecting){[self finishSelection];return;}self.selecting=YES;[self.selection removeAllObjects];self.allButton.hidden=YES;self.batchBar.hidden=NO;self.moreButton.hidden=YES;self.moreButton.menu=nil;[self.batchExport setTitle:self.mainTabs.selectedSegmentIndex?@"下载所选":@"导出" forState:UIControlStateNormal];self.batchDelete.hidden=self.mainTabs.selectedSegmentIndex==1;self.batchMore.hidden=self.mainTabs.selectedSegmentIndex==1;[self.view setNeedsLayout];[self applyFilter:NO];}'''
assert old in s;s=s.replace(old,new,1)
# Mode changes always leave multi-select state.
old='- (void)modeChanged{self.selecting=NO;self.collapsed=NO;[self.selection removeAllObjects];self.allButton.hidden=YES;self.batchBar.hidden=YES;'
new='- (void)modeChanged{self.selecting=NO;self.collapsed=NO;[self.selection removeAllObjects];self.allButton.hidden=YES;self.batchBar.hidden=YES;self.moreButton.hidden=NO;self.moreButton.menu=[self topMenu];'
assert old in s;s=s.replace(old,new,1)
p.write_text(s)

p=Path('/var/minis/workspace/pyvideo-plus/src/Menus.m');s=p.read_text()
# Replace an existing injected action instead of reusing a stale UIAction/menu instance.
old='''static id PVXMenuAppendDownloads(id original) {
    // A nil return can deliberately suppress a menu; do not manufacture one.
    if (![original isKindOfClass:UIMenu.class] || !NSThread.isMainThread) return original;
    UIMenu *menu = original;
    if (PVXMenuContainsDownload(menu)) return menu;
    UIAction *action = [UIAction actionWithTitle:@"下载视频与图片"
                                         image:[UIImage systemImageNamed:@"arrow.down.circle"]
                                    identifier:PVXDownloadMenuIdentifier
                                       handler:^(__unused UIAction *sender) {
        // Queue past the menu's dismissal; never retain a browser/window context.
        dispatch_async(dispatch_get_main_queue(), ^{ PVXOpenDownloads(); });
    }];
    // Unlike rebuilding a UIMenu from its title/options, this preserves metadata,
    // subtitle, identifiers, attributes, existing disabled actions and providers.
    return [menu menuByReplacingChildren:[menu.children arrayByAddingObject:action]];
}'''
new='''static UIMenu *PVXStripDownloadAction(UIMenu *menu) {
    if (![menu isKindOfClass:UIMenu.class]) return menu;
    NSMutableArray *children=[NSMutableArray array];BOOL changed=NO;
    for(UIMenuElement *child in menu.children){
        if([child isKindOfClass:UIAction.class]&&[((UIAction*)child).identifier isEqualToString:PVXDownloadMenuIdentifier]){changed=YES;continue;}
        if([child isKindOfClass:UIMenu.class]){UIMenu *nested=PVXStripDownloadAction((UIMenu*)child);changed|=nested!=child;[children addObject:nested];}
        else [children addObject:child];
    }
    return changed?[menu menuByReplacingChildren:children]:menu;
}
static id PVXMenuAppendDownloads(id original) {
    if (![original isKindOfClass:UIMenu.class] || !NSThread.isMainThread) return original;
    UIMenu *menu=PVXStripDownloadAction((UIMenu*)original);
    UIAction *action=[UIAction actionWithTitle:@"下载视频与图片" image:[UIImage systemImageNamed:@"arrow.down.circle"] identifier:PVXDownloadMenuIdentifier handler:^(__unused UIAction *sender){dispatch_async(dispatch_get_main_queue(),^{PVXOpenDownloads();});}];
    return [menu menuByReplacingChildren:[menu.children arrayByAddingObject:action]];
}'''
assert old in s;s=s.replace(old,new,1)
# The item menu setter is the final delivery point for recreated address-bar menus.
old='static void PVXBarSetMenu(id self,SEL command,id menu) { ((void(*)(id,SEL,id))PVXOldBarSetMenu)(self,command,PVXRemoveOriginalTabAction(menu)); }'
new='static void PVXBarSetMenu(id self,SEL command,id menu) { UIMenu *clean=PVXRemoveOriginalTabAction(menu); ((void(*)(id,SEL,id))PVXOldBarSetMenu)(self,command,PVXMenuAppendDownloads(clean)); }'
assert old in s;s=s.replace(old,new,1)
p.write_text(s)

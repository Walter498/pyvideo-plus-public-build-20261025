from pathlib import Path
p=Path(__file__).resolve().parents[1]/'src/DownloadsUI.m'
s=p.read_text()
def edit(a,b):
 global s
 assert a in s,a[:100]
 s=s.replace(a,b,1)
edit('@[_cover,_heading,_stateIcon,_stateLabel,_details,_badge,_command,_progress]','@[_cover,_heading,_stateIcon,_stateLabel,_details,_dateLabel,_badge,_command,_progress]')
edit('- (void)activate{if(self.pressed)self.pressed(self.rowID,self.command);}','- (void)activate{if(self.pressed)self.pressed(self.rowID,self.command);}\n- (void)openPreview{if(self.preview)self.preview(self.rowID);}')
edit('self.details.frame=CGRectMake(x,76,right,18);','self.details.frame=CGRectMake(x,75,right,18);self.dateLabel.frame=CGRectMake(x,95,right,17);')
edit('self.table.rowHeight=108;','self.table.rowHeight=126;')
edit('self.requested=NO;self.cover.contentMode','self.requested=NO;self.retryAfter=0;self.cover.contentMode')
edit('self.details.text=p[@"size"];','self.details.text=p[@"size"];self.dateLabel.hidden=collect;NSTimeInterval stamp=[r[@"created"] doubleValue];static NSDateFormatter *dateFormatter;static dispatch_once_t dateOnce;dispatch_once(&dateOnce,^{dateFormatter=[NSDateFormatter new];dateFormatter.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];dateFormatter.dateFormat=@"MM/dd HH:mm";});self.dateLabel.text=!collect&&stamp>0?[NSString stringWithFormat:@"下载日期：%@",[dateFormatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:stamp]]]:@"";')
edit('if(!self.requested){self.requested=YES;','if(!self.requested&&NSDate.date.timeIntervalSince1970>=self.retryAfter){self.requested=YES;')
edit('if([weak.rowID isEqual:identity]&&image){weak.cover.image=image;weak.cover.contentMode=UIViewContentModeScaleAspectFill;}','if([weak.rowID isEqual:identity]){if(image){weak.cover.image=image;weak.cover.contentMode=UIViewContentModeScaleAspectFill;}else{weak.requested=NO;weak.retryAfter=NSDate.date.timeIntervalSince1970+3;}}')
edit('self.rowID=nil;self.pressed=nil;self.requested=NO;','self.rowID=nil;self.pressed=nil;self.preview=nil;self.requested=NO;self.retryAfter=0;')
edit('return cell;}\n- (NSDictionary*)rowForID:', 'cell.preview=^(NSString *identity){NSDictionary *row=[weak rowForID:identity];if(!row)return;if(weak.selecting)[weak toggleRow:row];else PVXPreviewMedia(row);};return cell;}\n- (NSDictionary*)rowForID:')
p.write_text(s)

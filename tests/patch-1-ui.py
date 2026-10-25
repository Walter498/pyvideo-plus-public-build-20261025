from pathlib import Path
p=Path(__file__).resolve().parents[1]/'src/DownloadsUI.m';s=p.read_text()
def e(a,b):
 global s
 assert a in s,a[:120]
 s=s.replace(a,b,1)
e('@property(nonatomic,strong)UILabel *heading,*stateLabel,*details,*badge,*dateLabel;','@property(nonatomic,strong)UILabel *heading,*stateLabel,*details,*badge,*dateLabel,*qualityLabel;')
e('@property(nonatomic)BOOL requested;','@property(nonatomic)BOOL requested,qualityRequested;')
e('_dateLabel=[UILabel new];','_qualityLabel=[UILabel new];_qualityLabel.font=[UIFont systemFontOfSize:9 weight:UIFontWeightBold];_qualityLabel.textColor=UIColor.whiteColor;_qualityLabel.backgroundColor=[UIColor colorWithWhite:0 alpha:.7];_qualityLabel.textAlignment=NSTextAlignmentCenter;_qualityLabel.layer.cornerRadius=3;_qualityLabel.clipsToBounds=YES;_dateLabel=[UILabel new];')
e('_dateLabel,_badge,_command,_progress]','_dateLabel,_badge,_qualityLabel,_command,_progress]')
e('self.badge.frame=CGRectMake(10,11,34,16);','self.badge.frame=CGRectMake(10,11,34,16);self.qualityLabel.frame=CGRectMake(MAX(10,c-84),MAX(28,h-25),82,16);')
e('self.requested=NO;self.retryAfter=0;self.cover.contentMode','self.requested=NO;self.qualityRequested=NO;self.retryAfter=0;self.cover.contentMode')
e('NSDictionary *p=collect?@{','BOOL linked=collect&&[r[@"linkedTask"] isKindOfClass:NSDictionary.class];NSDictionary *p=linked?PVXTaskPresentation(r[@"linkedTask"]):collect?@{')
e('self.progress.hidden=collect||![@[@"downloading",@"hls",@"converting",@"remuxing"] containsObject:r[@"state"]];','NSDictionary *progressRow=linked?r[@"linkedTask"]:r;self.progress.hidden=(collect&&!linked)||![@[@"downloading",@"hls",@"converting",@"remuxing"] containsObject:progressRow[@"state"]];if(!self.qualityRequested){self.qualityRequested=YES;self.qualityLabel.text=@"读取分辨率…";__weak typeof(self) weakQuality=self;PVXFetchMediaQuality(linked?r[@"linkedTask"]:r,^(NSString *quality){if([weakQuality.rowID isEqual:identity]){weakQuality.qualityLabel.text=quality;weakQuality.qualityLabel.accessibilityLabel=quality;}});}')
e('self.pressed=nil;self.preview=nil;self.requested=NO;','self.pressed=nil;self.preview=nil;self.requested=NO;self.qualityRequested=NO;')
e('NSMutableArray *list=[PVXCollectedMedia(self.kind) mutableCopy]?:[NSMutableArray array];','NSMutableArray *list=[PVXCollectedMedia(self.kind) mutableCopy]?:[NSMutableArray array];NSArray *tasks=PVXReadVideoTasks();')
e('NSDictionary *r=list[i];NSString *key=PVXRowID(r);','NSDictionary *r=list[i];NSDictionary *download=PVXLinkedTask(r,tasks);if(download){NSMutableDictionary *merged=[r mutableCopy];merged[@"linkedTask"]=download;r=merged;list[i]=merged;}NSString *key=PVXRowID(r);')
e('self.submissions[key]=submitted;','self.submissions[key]=submitted;PVXRememberSource(candidate,submitted);')
# Remove Move and Tags user explicitly calls redundant, including batch-only extras.
a='UIAlertAction *move=[UIAlertAction actionWithTitle:@"移动到…"';start=s.index(a);end=s.index('if(rows.count==1&&![first[@"kind"]',start);s=s[:start]+s[end:]
e('self.search.placeholder=@"搜索标题、URL、分组或标签";','self.search.placeholder=@"搜索标题或 URL";')
e('if(rows.count==1)t.text=PVXText(rows.firstObject[field]);','if(rows.count==1)t.text=PVXText(rows.firstObject[field]);')
p.write_text(s)

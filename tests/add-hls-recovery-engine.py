from pathlib import Path
p=Path('/var/minis/workspace/pyvideo-plus/storage/Storage.m');s=p.read_text()
s=s.replace('#import <Foundation/Foundation.h>','#import <Foundation/Foundation.h>\n#import <AVFoundation/AVFoundation.h>',1)
s=s.replace('static void (*OldPump)(id, SEL);','static void (*OldPump)(id, SEL);\nstatic BOOL (*Persist)(id, SEL, id);\nstatic NSMutableSet *RecoveryAttempted;\nstatic NSMutableDictionary *RecoveryExports;',1)
# Add helpers immediately before Tick.
needle='static void Tick(void) {';idx=s.index(needle)
code=r'''static long long PVXSegmentIndex(NSString *url){
    NSString *stem=url.stringByDeletingPathExtension;long long last=-1;NSUInteger i=0;
    while(i<stem.length){while(i<stem.length&&![NSCharacterSet.decimalDigitCharacterSet characterIsMember:[stem characterAtIndex:i]])i++;if(i>=stem.length)break;NSUInteger start=i;while(i<stem.length&&[NSCharacterSet.decimalDigitCharacterSet characterIsMember:[stem characterAtIndex:i]])i++;NSString *n=[stem substringWithRange:NSMakeRange(start,i-start)];last=n.longLongValue;}
    return last;
}
static NSArray *PVXOrderedHLSFiles(NSString *uuid){
    NSString *dir=Path([NSString stringWithFormat:@"media/%@.hls",uuid]);NSArray *names=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];NSMutableArray *rows=[NSMutableArray array];
    for(NSString *name in names){if(![name.pathExtension isEqual:@"plist"]||![name hasSuffix:@".ts.plist"])continue;NSDictionary *meta=[NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:name]];NSString *response=meta[@"responseURL"];if(![response isKindOfClass:NSString.class])continue;NSString *ts=[name substringToIndex:name.length-6];NSString *path=[dir stringByAppendingPathComponent:ts];BOOL file=NO;[[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&file];if(file)continue;struct stat st;if(lstat(path.fileSystemRepresentation,&st)||!S_ISREG(st.st_mode)||st.st_size<=0)continue;[rows addObject:@{ @"index":@(PVXSegmentIndex(response)), @"url":response, @"path":path }];}
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary*a,NSDictionary*b){long long x=[a[@"index"] longLongValue],y=[b[@"index"] longLongValue];if(x>=0&&y>=0&&x!=y)return x<y?NSOrderedAscending:NSOrderedDescending;return [a[@"url"] compare:b[@"url"]];}];return rows;
}
static BOOL PVXConcatHLS(NSArray *rows,NSString *path){
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];if(![[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil])return NO;NSFileHandle*out=[NSFileHandle fileHandleForWritingAtPath:path];if(!out)return NO;BOOL ok=YES;
    for(NSDictionary *row in rows){NSFileHandle*in=[NSFileHandle fileHandleForReadingAtPath:row[@"path"]];if(!in){ok=NO;break;}@try{while(true){NSData*d=[in readDataOfLength:1024*1024];if(!d.length)break;[out writeData:d];}}@catch(NSException*e){ok=NO;}[in closeFile];if(!ok)break;}
    [out synchronizeFile];[out closeFile];return ok;
}
static void PVXFinishRecovery(id agent,NSString*uuid,NSString*temp,BOOL success,NSError*error){
    [RecoveryExports removeObjectForKey:uuid];NSString *dest=Path([NSString stringWithFormat:@"media/%@.mp4",uuid]);
    if(success&&[[NSFileManager defaultManager] moveItemAtPath:temp toPath:dest error:&error]){struct stat st;NSMutableDictionary*t=[[[agent tasks] objectForKey:uuid] mutableCopy];if(t&&!lstat(dest.fileSystemRepresentation,&st)){t[@"state"]=@"ready";t[@"fileComplete"]=@YES;t[@"received"]=@(st.st_size);t[@"total"]=@(st.st_size);t[@"mediaBytes"]=@(st.st_size);[t removeObjectForKey:@"error"];[[agent tasks] setObject:t forKey:uuid];if(Persist)Persist(agent,@selector(persist:),t);Notify(Signal);return;}}
    [[NSFileManager defaultManager] removeItemAtPath:temp error:nil];NSMutableDictionary*t=[[[agent tasks] objectForKey:uuid] mutableCopy];if(t&&error.localizedDescription.length){t[@"error"]=[NSString stringWithFormat:@"HLS恢复封装失败：%@",error.localizedDescription];[[agent tasks] setObject:t forKey:uuid];if(Persist)Persist(agent,@selector(persist:),t);Notify(Signal);}
}
static void PVXStartRecoveryExport(id agent,NSString*uuid,NSString*ts,NSInteger attempt){
    NSString *temp=Path([NSString stringWithFormat:@"media/%@.recovery.mp4",uuid]);[[NSFileManager defaultManager] removeItemAtPath:temp error:nil];AVURLAsset*asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:ts] options:nil];NSString*preset=attempt==0?AVAssetExportPresetPassthrough:AVAssetExportPresetHighestQuality;AVAssetExportSession*e=[[AVAssetExportSession alloc] initWithAsset:asset presetName:preset];if(!e){NSError*err=[NSError errorWithDomain:@"PVXRecovery" code:1 userInfo:@{NSLocalizedDescriptionKey:@"AVAssetExportSession unavailable"}];PVXFinishRecovery(agent,uuid,temp,NO,err);return;}e.outputURL=[NSURL fileURLWithPath:temp];e.outputFileType=AVFileTypeMPEG4;e.shouldOptimizeForNetworkUse=NO;RecoveryExports[uuid]=e;[e exportAsynchronouslyWithCompletionHandler:^{dispatch_async(dispatch_get_main_queue(),^{if(e.status==AVAssetExportSessionStatusCompleted){PVXFinishRecovery(agent,uuid,temp,YES,nil);return;}if(attempt==0){PVXStartRecoveryExport(agent,uuid,ts,1);return;}NSError*err=e.error?:[NSError errorWithDomain:@"PVXRecovery" code:2 userInfo:@{NSLocalizedDescriptionKey:@"MPEG-TS无法封装为MP4"}];PVXFinishRecovery(agent,uuid,temp,NO,err);});}];
}
static void PVXRecoverFailedHLS(id agent,NSDictionary*task){NSString*uuid=task[@"id"];if(!ValidID(uuid)||[RecoveryAttempted containsObject:uuid])return;RecoveryAttempted?:(RecoveryAttempted=[NSMutableSet set]);[RecoveryAttempted addObject:uuid];NSArray*rows=PVXOrderedHLSFiles(uuid);if(rows.count<2)return;dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSString*ts=Path([NSString stringWithFormat:@"media/%@.recovery.ts",uuid]);if(!PVXConcatHLS(rows,ts))return;dispatch_async(dispatch_get_main_queue(),^{PVXStartRecoveryExport(agent,uuid,ts,0);});});}
static void PVXScanFailedHLS(id agent){for(NSDictionary*t in [[agent tasks] allValues]){if([t[ @"state"] isEqual:@"failed"]&&[t[@"error"] isKindOfClass:NSString.class]&&[t[@"error"] containsString:@"HLS 封装失败"])PVXRecoverFailedHLS(agent,t);}}
'''
s=s[:idx]+code+s[idx:]
# Tick should scan recovery after original export check.
old='if (agent && [agent workerMode] && [agent reconciled]) [agent exportReady];'
new='if (agent && [agent workerMode] && [agent reconciled]) { [agent exportReady]; PVXScanFailedHLS(agent); }'
assert old in s;s=s.replace(old,new,1)
# Constructor setup init and signature Persist.
s=s.replace('!Signature(c, @selector(pump), "v", 0, NULL) ||','!Signature(c, @selector(pump), "v", 0, NULL) ||\n            !Signature(c, @selector(persist:), "B", 1, one) ||',1)
s=s.replace('Hook = (void *)dlsym(RTLD_DEFAULT, "MSHookMessageEx");','RecoveryAttempted=[NSMutableSet set];RecoveryExports=[NSMutableDictionary dictionary];\n        Persist=(void *)class_getMethodImplementation(c,@selector(persist:));\n        Hook = (void *)dlsym(RTLD_DEFAULT, "MSHookMessageEx");',1)
p.write_text(s)
# Add AVFoundation to storage link.
p=Path('/var/minis/workspace/pyvideo-plus/build-macos.py');s=p.read_text();s=s.replace("P/'storage/Storage.m','-framework','Foundation'", "P/'storage/Storage.m','-framework','Foundation','-framework','AVFoundation'",1);p.write_text(s)

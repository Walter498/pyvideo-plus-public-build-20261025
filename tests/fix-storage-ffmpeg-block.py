from pathlib import Path
p=Path('/var/minis/workspace/pyvideo-plus/storage/Storage.m')
s=p.read_text()
a=s.index('static void PVXFinishRecovery(id agent,NSString*uuid,NSString*temp,BOOL success,NSError*error);')
b=s.index('static void PVXRecoverFailedHLS',a)
block=r'''static void PVXFinishRecovery(id agent,NSString*uuid,NSString*temp,BOOL success,NSError*error);
static BOOL PVXLoadFFmpegKit(void){
 if(FFmpegKitClass)return YES;
 NSArray *paths=@[@"@rpath/ffmpegkit.framework/ffmpegkit",@"/Applications/PyVideoAgent.app/Frameworks/ffmpegkit.framework/ffmpegkit",@"/var/jb/Applications/PyVideoAgent.app/Frameworks/ffmpegkit.framework/ffmpegkit"];
 for(NSString *path in paths){FFmpegHandle=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);if(FFmpegHandle)break;}
 FFmpegKitClass=NSClassFromString(@"FFmpegKit");return FFmpegHandle&&FFmpegKitClass;
}
static BOOL PVXFFmpegRemux(NSString *input,NSString *output,NSError **outError){
 if(!PVXLoadFFmpegKit()){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:10 userInfo:@{NSLocalizedDescriptionKey:@"FFmpegKit 未加载，已转入 AVFoundation"}];return NO;}
 SEL execute=NSSelectorFromString(@"executeWithArguments:");if(![FFmpegKitClass respondsToSelector:execute]){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:11 userInfo:@{NSLocalizedDescriptionKey:@"FFmpegKit 接口不可用，已转入 AVFoundation"}];return NO;}
 NSArray *args=@[@"-hide_banner",@"-loglevel",@"error",@"-y",@"-f",@"mpegts",@"-i",input,@"-map",@"0:v:0?",@"-map",@"0:a?",@"-c",@"copy",@"-avoid_negative_ts",@"make_zero",@"-movflags",@"+faststart",output];
 id session=((id(*)(id,SEL,id))objc_msgSend)(FFmpegKitClass,execute,args);SEL getRC=NSSelectorFromString(@"getReturnCode");id rc=[session respondsToSelector:getRC]?((id(*)(id,SEL))objc_msgSend)(session,getRC):nil;SEL success=NSSelectorFromString(@"isValueSuccess");BOOL ok=rc&&[rc respondsToSelector:success]&&((BOOL(*)(id,SEL))objc_msgSend)(rc,success);struct stat st;if(ok)ok=!lstat(output.fileSystemRepresentation,&st)&&S_ISREG(st.st_mode)&&st.st_size>0;if(!ok){NSString *detail=rc&&[rc respondsToSelector:NSSelectorFromString(@"description")]?[rc description]:@"FFmpegKit remux failed";if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:12 userInfo:@{NSLocalizedDescriptionKey:detail?:@"FFmpegKit remux failed"}];[[NSFileManager defaultManager] removeItemAtPath:output error:nil];}return ok;
}
static void PVXFinishRecovery(id agent,NSString*uuid,NSString*temp,BOOL success,NSError*error){
 [RecoveryExports removeObjectForKey:uuid];NSString *dest=Path([NSString stringWithFormat:@"media/%@.mp4",uuid]);
 if(success){[[NSFileManager defaultManager] removeItemAtPath:dest error:nil];}if(success&&[[NSFileManager defaultManager] moveItemAtPath:temp toPath:dest error:&error]){struct stat st;NSMutableDictionary*t=[[[agent tasks] objectForKey:uuid] mutableCopy];if(t&&!lstat(dest.fileSystemRepresentation,&st)){t[@"state"]=@"ready";t[@"fileComplete"]=@YES;t[@"received"]=@(st.st_size);t[@"total"]=@(st.st_size);t[@"mediaBytes"]=@(st.st_size);[t removeObjectForKey:@"error"];[[agent tasks] setObject:t forKey:uuid];if(Persist)Persist(agent,@selector(persist:),t);Notify(Signal);return;}}
 [[NSFileManager defaultManager] removeItemAtPath:temp error:nil];NSMutableDictionary*t=[[[agent tasks] objectForKey:uuid] mutableCopy];if(t&&error.localizedDescription.length){t[@"error"]=[NSString stringWithFormat:@"HLS恢复封装失败：%@",error.localizedDescription];[[agent tasks] setObject:t forKey:uuid];if(Persist)Persist(agent,@selector(persist:),t);Notify(Signal);}
}
static void PVXStartAVFoundationExport(id agent,NSString*uuid,NSString*ts,NSInteger attempt,NSString *previous){
 NSString *temp=Path([NSString stringWithFormat:@"media/%@.recovery.mp4",uuid]);[[NSFileManager defaultManager] removeItemAtPath:temp error:nil];AVURLAsset*asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:ts] options:nil];NSString*preset=attempt==0?AVAssetExportPresetPassthrough:AVAssetExportPresetHighestQuality;AVAssetExportSession*e=[[AVAssetExportSession alloc] initWithAsset:asset presetName:preset];if(!e){NSError*err=[NSError errorWithDomain:@"PVXRecovery" code:1 userInfo:@{NSLocalizedDescriptionKey:@"AVAssetExportSession unavailable"}];PVXFinishRecovery(agent,uuid,temp,NO,err);return;}e.outputURL=[NSURL fileURLWithPath:temp];e.outputFileType=AVFileTypeMPEG4;e.shouldOptimizeForNetworkUse=NO;RecoveryExports[uuid]=e;[e exportAsynchronouslyWithCompletionHandler:^{dispatch_async(dispatch_get_main_queue(),^{if(e.status==AVAssetExportSessionStatusCompleted){PVXFinishRecovery(agent,uuid,temp,YES,nil);return;}if(attempt==0){PVXStartAVFoundationExport(agent,uuid,ts,1,previous);return;}NSString *detail=e.error.localizedDescription?:@"MPEG-TS无法封装为MP4";if(previous.length)detail=[NSString stringWithFormat:@"%@；AVFoundation：%@",previous,detail];NSError*err=[NSError errorWithDomain:@"PVXRecovery" code:2 userInfo:@{NSLocalizedDescriptionKey:detail}];PVXFinishRecovery(agent,uuid,temp,NO,err);});}];
}
static void PVXStartRecoveryExport(id agent,NSString*uuid,NSString*ts,NSInteger attempt){
 NSString *temp=Path([NSString stringWithFormat:@"media/%@.recovery.mp4",uuid]);RecoveryExports[uuid]=@YES;dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSError *err=nil;BOOL ok=PVXFFmpegRemux(ts,temp,&err);NSString *detail=err.localizedDescription;dispatch_async(dispatch_get_main_queue(),^{if(ok){PVXFinishRecovery(agent,uuid,temp,YES,nil);return;}PVXStartAVFoundationExport(agent,uuid,ts,0,detail);});});
}
'''
s=s[:a]+block+s[b:]
p.write_text(s)

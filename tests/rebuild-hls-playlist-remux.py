from pathlib import Path
p=Path('/var/minis/workspace/pyvideo-plus/storage/Storage.m');s=p.read_text()
a=s.index('static BOOL PVXFFmpegRemux(');b=s.index('static void PVXFinishRecovery(',a)
new=r'''static BOOL PVXWriteLocalHLSPlaylist(NSArray *rows,NSString *path,NSError **outError){
 NSMutableString *playlist=[NSMutableString stringWithString:@"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-INDEPENDENT-SEGMENTS\n"];
 for(NSDictionary *row in rows){NSString *segment=row[@"path"];if(![segment isKindOfClass:NSString.class])continue;NSString *uri=[NSURL fileURLWithPath:segment].absoluteString;[playlist appendFormat:@"#EXTINF:10.000,\n%@\n",uri];}
 [playlist appendString:@"#EXT-X-ENDLIST\n"];NSData *data=[playlist dataUsingEncoding:NSUTF8StringEncoding];if(!data||![data writeToFile:path options:NSDataWritingAtomic error:outError])return NO;chmod(path.fileSystemRepresentation,0600);return YES;
}
static BOOL PVXFFmpegRemux(NSString *input,NSString *output,NSError **outError){
 if(!PVXLoadFFmpegKit()){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:10 userInfo:@{NSLocalizedDescriptionKey:@"FFmpegKit 未加载，恢复未执行"}];return NO;}
 SEL execute=NSSelectorFromString(@"executeWithArguments:");if(![FFmpegKitClass respondsToSelector:execute]){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:11 userInfo:@{NSLocalizedDescriptionKey:@"FFmpegKit 接口不可用"}];return NO;}
 BOOL playlist=[input.pathExtension.lowercaseString isEqual:@"m3u8"];NSMutableArray *args=[NSMutableArray arrayWithObjects:@"-hide_banner",@"-loglevel",@"error",@"-y",nil];if(playlist){[args addObjectsFromArray:@[@"-protocol_whitelist",@"file,crypto,data",@"-allowed_extensions",@"ALL",@"-fflags",@"+genpts",@"-i",input]];}else{[args addObjectsFromArray:@[@"-f",@"mpegts",@"-i",input]];}[args addObjectsFromArray:@[@"-map",@"0:v:0?",@"-map",@"0:a:0?",@"-c",@"copy",@"-avoid_negative_ts",@"make_zero",@"-max_interleave_delta",@"0",@"-movflags",@"+faststart",output]];
 id session=((id(*)(id,SEL,id))objc_msgSend)(FFmpegKitClass,execute,args);SEL getRC=NSSelectorFromString(@"getReturnCode");id rc=[session respondsToSelector:getRC]?((id(*)(id,SEL))objc_msgSend)(session,getRC):nil;SEL success=NSSelectorFromString(@"isValueSuccess");BOOL ok=rc&&[rc respondsToSelector:success]&&((BOOL(*)(id,SEL))objc_msgSend)(rc,success);struct stat st;if(ok)ok=!lstat(output.fileSystemRepresentation,&st)&&S_ISREG(st.st_mode)&&st.st_size>0;if(!ok){NSString *detail=rc&&[rc respondsToSelector:NSSelectorFromString(@"description")]?[rc description]:@"FFmpegKit remux failed";if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:12 userInfo:@{NSLocalizedDescriptionKey:detail?:@"FFmpegKit remux failed"}];[[NSFileManager defaultManager] removeItemAtPath:output error:nil];}return ok;
}
'''
s=s[:a]+new+s[b:]
a=s.index('static void PVXRecoverFailedHLS(');b=s.index('static void PVXScanFailedHLS',a)
new=r'''static void PVXRecoverFailedHLS(id agent,NSDictionary*task){NSString*uuid=task[@"id"];if(!ValidID(uuid))return;dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSArray*rows=PVXOrderedHLSFiles(uuid);if(rows.count<2)return;NSString *playlist=Path([NSString stringWithFormat:@"media/%@.recovery.m3u8",uuid]);NSError *playlistError=nil;if(!PVXWriteLocalHLSPlaylist(rows,playlist,&playlistError))return;dispatch_async(dispatch_get_main_queue(),^{if([RecoveryAttempted containsObject:uuid])return;[RecoveryAttempted addObject:uuid];PVXStartRecoveryExport(agent,uuid,playlist,0);});});}
'''
s=s[:a]+new+s[b:]
p.write_text(s)

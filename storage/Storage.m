// Standalone PyVideoAgent 0.0.3 add-on. ARC, iOS 15+, Foundation only.
// The portable disk primitive is also compiled by tests/storage-beta2/io.c.
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <limits.h>

// No overwrite, no symlink traversal on leaf files, constant memory, durable
// staging then atomic link publication. Existing destinations must match bytes.
static int PVXSameFD(int a, int b) {
    struct stat sa, sb;
    if (fstat(a, &sa) || fstat(b, &sb) || !S_ISREG(sa.st_mode) ||
        !S_ISREG(sb.st_mode) || sa.st_size <= 0 || sa.st_size != sb.st_size) return 0;
    unsigned char x[65536], y[65536];
    if (lseek(a, 0, SEEK_SET) < 0 || lseek(b, 0, SEEK_SET) < 0) return 0;
    for (;;) {
        ssize_t n = read(a, x, sizeof(x));
        if (n < 0) { if (errno == EINTR) continue; return 0; }
        if (!n) return 1;
        size_t got = 0;
        while (got < (size_t)n) {
            ssize_t m = read(b, y + got, (size_t)n - got);
            if (m < 0 && errno == EINTR) continue;
            if (m <= 0) return 0;
            got += (size_t)m;
        }
        if (memcmp(x, y, (size_t)n)) return 0;
    }
}
static int PVXSyncParent(const char *path) {
    char *copy = strdup(path);
    if (!copy) return 0;
    char *slash = strrchr(copy, '/');
    if (slash) *slash = '\0';
    int fd = open(slash ? (*copy ? copy : "/") : ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    int ok = fd >= 0 && !fsync(fd);
    if (fd >= 0) close(fd);
    free(copy); return ok;
}
static int PVXRetainDisk(const char *source, const char *dest) {
    int in = open(source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (in < 0) return 0;
    struct stat before, after;
    if (fstat(in, &before) || !S_ISREG(before.st_mode) || before.st_size <= 0) {
        close(in); return 0;
    }
    int existing = open(dest, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (existing >= 0) {
        int equal = PVXSameFD(in, existing);
        close(existing); close(in); return equal;
    }
    // Agent final media is immutable in saving. Keep its inode without a second
    // full allocation; verify identity after publication before allowing cleanup.
    if (!link(source, dest)) {
        struct stat published;
        int ok = !lstat(dest, &published) && S_ISREG(published.st_mode) &&
            published.st_dev == before.st_dev && published.st_ino == before.st_ino;
        if (!ok) unlink(dest);
        if (ok) ok = PVXSyncParent(dest);
        close(in); return ok;
    }
    size_t len = strlen(dest) + 16;
    char *temp = malloc(len);
    if (!temp) { close(in); return 0; }
    snprintf(temp, len, "%s.XXXXXX", dest);
    int out = mkstemp(temp);
    int ok = out >= 0;
    unsigned char buffer[65536];
    off_t total = 0;
    while (ok) {
        ssize_t n = read(in, buffer, sizeof(buffer));
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { ok = 0; break; }
        if (!n) break;
        total += n;
        if (total > before.st_size) { ok = 0; break; }
        size_t sent = 0;
        while (sent < (size_t)n) {
            ssize_t m = write(out, buffer + sent, (size_t)n - sent);
            if (m < 0 && errno == EINTR) continue;
            if (m <= 0) { ok = 0; break; }
            sent += (size_t)m;
        }
    }
    if (ok) ok = !fstat(in, &after) && total == before.st_size &&
        before.st_size == after.st_size && before.st_mtime == after.st_mtime &&
        before.st_ctime == after.st_ctime && !fsync(out);
    if (out >= 0 && close(out)) ok = 0;
    if (ok && link(temp, dest)) {
        existing = open(dest, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        ok = existing >= 0 && PVXSameFD(in, existing);
        if (existing >= 0) close(existing);
    }
    unlink(temp); free(temp); close(in);
    return ok && PVXSyncParent(dest);
}

#ifndef PVX_STORAGE_IO_TEST
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "PVXHLSManifest.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <notify.h>
#include <dirent.h>
#include <math.h>

@interface NSObject (PVXStorageAgent)
- (BOOL)workerMode;
- (BOOL)reconciled;
- (BOOL)memoryReady;
- (NSMutableDictionary *)tasks;
- (NSMutableSet *)exports;
- (NSDictionary *)clearingRequest;
- (void)exportReady;
@end

static NSString *(*Root)(void);
static NSString *(*Media)(NSString *);
static BOOL (*Write)(id, NSString *, NSError **);
static void (*Notify)(NSString *);
static void (*Hook)(Class, SEL, IMP, IMP *);
static id (*OldTasks)(id, SEL);
static BOOL (*OldStart)(id, SEL);
static void (*OldExport)(id, SEL);
static void (*OldFinish)(id, SEL, id, BOOL, id, id);
static BOOL (*OldRemove)(id, SEL, id, NSError **);
static void (*OldDelete)(id, SEL, id);
static void (*OldPump)(id, SEL);
static BOOL (*Persist)(id, SEL, id);
static NSMutableSet *RecoveryAttempted;
static NSMutableDictionary *RecoveryExports;
static void *FFmpegHandle;
static Class FFmpegKitClass;
static NSString *FFmpegLoadError;
static void PVXBootLog(NSString *message){fprintf(stderr,"PyVideoStorage: %s\\n",message.UTF8String?:"(null)");fflush(stderr);}
static __weak id Worker;
static dispatch_source_t Timer;
static int NotificationToken;
// A getter view only. Never replaces Agent.tasks, never copies task records.
static _Thread_local void *ViewOwner;
static _Thread_local void *ViewTasks;
static _Thread_local void *ProtectedPaths;
static NSString *const Signal = @"com.crctdd.pyvideo.plus.storage";

static BOOL ValidID(id value) {
    return [value isKindOfClass:NSString.class] && [value length] == 36 &&
        [[NSUUID alloc] initWithUUIDString:value] != nil;
}
static NSString *Path(NSString *leaf) { return [Root() stringByAppendingPathComponent:leaf]; }
static BOOL SafeDirectory(NSString *path) {
    struct stat s;
    if (lstat(path.fileSystemRepresentation, &s)) {
        if (errno != ENOENT || mkdir(path.fileSystemRepresentation, 0700)) return NO;
        if (lstat(path.fileSystemRepresentation, &s)) return NO;
    }
    return S_ISDIR(s.st_mode) && !S_ISLNK(s.st_mode) && s.st_uid == geteuid();
}
static void PVXDiagnostic(NSString *name,NSDictionary *value){if(!Write||!name.length)return;NSString *dir=Path(@"plus-diagnostics");if(!SafeDirectory(dir))return;NSMutableDictionary *payload=[value mutableCopy]?:[NSMutableDictionary dictionary];payload[@"updated"] = @(NSDate.date.timeIntervalSince1970);NSString *file=[dir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"plist"]];Write(payload,file,NULL);}
static id TasksView(id self, SEL cmd) {
    if (ViewOwner == (__bridge void *)self && ViewTasks) return (__bridge id)ViewTasks;
    return OldTasks(self, cmd);
}
static long long PVXSegmentIndex(NSString *url,NSDictionary *meta){for(NSString *key in @[@"segmentIndex",@"sequence",@"sequenceNumber",@"index",@"number",@"order"]){id value=meta[key];if([value respondsToSelector:@selector(longLongValue)]&&[value longLongValue]>=0)return [value longLongValue];}NSString *stem=url.stringByDeletingPathExtension;long long last=-1;NSUInteger i=0;while(i<stem.length){while(i<stem.length&&![NSCharacterSet.decimalDigitCharacterSet characterIsMember:[stem characterAtIndex:i]])i++;if(i>=stem.length)break;NSUInteger start=i;while(i<stem.length&&[NSCharacterSet.decimalDigitCharacterSet characterIsMember:[stem characterAtIndex:i]])i++;NSString *n=[stem substringWithRange:NSMakeRange(start,i-start)];last=n.longLongValue;}return last;}
static NSArray *PVXOrderedHLSFiles(NSString *uuid){NSString *dir=Path([NSString stringWithFormat:@"media/%@.hls",uuid]);NSArray *names=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];NSMutableArray *rows=[NSMutableArray array];for(NSString *name in names){if(!([name hasSuffix:@".ts.plist"]||[name hasSuffix:@".m4s.plist"]||[name hasSuffix:@".mp4.plist"]))continue;NSDictionary *meta=[NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:name]];NSString *response=meta[@"responseURL"]?:meta[@"url"];if(![response isKindOfClass:NSString.class])continue;NSString *segment=[name substringToIndex:name.length-6],*path=[dir stringByAppendingPathComponent:segment];struct stat st;if(lstat(path.fileSystemRepresentation,&st)||!S_ISREG(st.st_mode)||st.st_size<=0)continue;[rows addObject:@{@"index":@(PVXSegmentIndex(response,meta)),@"url":response,@"path":path,@"name":name,@"bytes":@(st.st_size)}];}[rows sortUsingComparator:^NSComparisonResult(NSDictionary*a,NSDictionary*b){long long x=[a[@"index"] longLongValue],y=[b[@"index"] longLongValue];if(x>=0&&y>=0&&x!=y)return x<y?NSOrderedAscending:NSOrderedDescending;NSComparisonResult u=[a[@"url"] compare:b[@"url"]];return u==NSOrderedSame?[a[@"name"] compare:b[@"name"]]:u;}];return rows;}
static void PVXFinishRecovery(id agent,NSString*uuid,NSString*temp,BOOL success,NSError*error);
static BOOL PVXLoadFFmpegKit(void){
 if(FFmpegKitClass)return YES;
 NSArray *paths=@[[[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"Frameworks/ffmpegkit.framework/ffmpegkit"],@"@rpath/ffmpegkit.framework/ffmpegkit",@"/Applications/PyVideoAgent.app/Frameworks/ffmpegkit.framework/ffmpegkit",@"/var/jb/Applications/PyVideoAgent.app/Frameworks/ffmpegkit.framework/ffmpegkit"];
 for(NSString *path in paths){FFmpegHandle=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_GLOBAL);if(FFmpegHandle)break;const char *e=dlerror();FFmpegLoadError=e?[NSString stringWithUTF8String:e]:[NSString stringWithFormat:@"dlopen failed: %@",path];}
 FFmpegKitClass=NSClassFromString(@"FFmpegKit");return FFmpegHandle&&FFmpegKitClass;
}
static NSDictionary *PVXAllHLSResources(NSString *uuid){NSString *dir=Path([NSString stringWithFormat:@"media/%@.hls",uuid]);NSArray *names=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];NSMutableDictionary *map=[NSMutableDictionary dictionary];for(NSString *name in names){if(![name.pathExtension.lowercaseString isEqual:@"plist"])continue;NSDictionary *meta=[NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:name]];NSString *remote=meta[@"responseURL"]?:meta[@"url"]?:meta[@"source"];if(![remote isKindOfClass:NSString.class])continue;NSString *file=[name stringByDeletingPathExtension],*path=[dir stringByAppendingPathComponent:file];struct stat st;if(lstat(path.fileSystemRepresentation,&st)||!S_ISREG(st.st_mode)||st.st_size<=0)continue;NSString *local=[NSURL fileURLWithPath:path].absoluteString;NSString *base=path.lastPathComponent.lowercaseString;map[remote]=local;map[remote.lowercaseString]=local;map[base]=local;map[file.lowercaseString]=local;NSURL *u=[NSURL URLWithString:remote];if(u.path.lastPathComponent.length)map[u.path.lastPathComponent.lowercaseString]=local;}return map;}
static BOOL PVXBuildLocalHLSPlaylist(NSString *uuid,NSString *output,NSError **outError){
 NSString *dir=Path([NSString stringWithFormat:@"media/%@.hls",uuid]);NSArray *names=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];PVXHLSManifest *best=nil;NSUInteger bestCount=0;
 for(NSString *name in names){NSString *ext=name.pathExtension.lowercaseString;if(!([ext isEqual:@"m3u8"]||[ext isEqual:@"txt"]||[name.lowercaseString containsString:@"playlist"]))continue;NSString *path=[dir stringByAppendingPathComponent:name];NSData *data=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];if(data.length>2*1024*1024)continue;NSError *e=nil;PVXHLSManifest *m=[PVXHLSManifest parseData:data baseURL:[NSURL fileURLWithPath:path] error:&e];if(m&&!m.master&&m.segments.count>bestCount){best=m;bestCount=m.segments.count;}}
 if(!best){NSArray *fallback=PVXOrderedHLSFiles(uuid);if(!fallback.count){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:20 userInfo:@{NSLocalizedDescriptionKey:@"HLS 目录没有可用分片元数据"}];return NO;}NSString *first=fallback.firstObject[@"path"];BOOL ts=[first.pathExtension.lowercaseString isEqual:@"ts"];if(!ts){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:25 userInfo:@{NSLocalizedDescriptionKey:@"HLS 无原始 media playlist，且缓存不是 MPEG-TS"}];return NO;}long long min=LLONG_MAX,max=LLONG_MIN;NSMutableSet *seen=[NSMutableSet set];for(NSDictionary *row in fallback){long long n=[row[@"index"] longLongValue];if(n<0||[seen containsObject:@(n)]){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:26 userInfo:@{NSLocalizedDescriptionKey:@"HLS 分片序号缺失或重复"}];return NO;}[seen addObject:@(n)];min=MIN(min,n);max=MAX(max,n);}if(max-min+1!=(long long)fallback.count){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:27 userInfo:@{NSLocalizedDescriptionKey:@"HLS 分片序号不连续，拒绝猜测时间线"}];return NO;}NSMutableString *synthetic=[NSMutableString stringWithFormat:@"#EXTM3U\\n#EXT-X-VERSION:3\\n#EXT-X-TARGETDURATION:10\\n#EXT-X-MEDIA-SEQUENCE:%lld\\n",min];for(NSDictionary *row in fallback){[synthetic appendString:@"#EXTINF:10.000,\\n"];[synthetic appendFormat:@"%@\\n",[NSURL fileURLWithPath:row[@"path"]].absoluteString];}[synthetic appendString:@"#EXT-X-ENDLIST\\n"];NSData *out=[synthetic dataUsingEncoding:NSUTF8StringEncoding];if(![out writeToFile:output options:NSDataWritingAtomic error:outError])return NO;chmod(output.fileSystemRepresentation,0600);return YES;}
 NSArray *rows=PVXOrderedHLSFiles(uuid);NSMutableDictionary *local=[PVXAllHLSResources(uuid) mutableCopy];NSMutableDictionary *pathMap=[NSMutableDictionary dictionary];NSMutableDictionary *sequenceByLocal=[NSMutableDictionary dictionary];for(NSDictionary *row in rows){NSString *file=row[@"path"];if(file.length){NSString *fileURL=[NSURL fileURLWithPath:file].absoluteString;sequenceByLocal[fileURL]=row[@"index"];local[fileURL]=fileURL;pathMap[file.lastPathComponent.lowercaseString]=fileURL;pathMap[[file.lastPathComponent stringByDeletingPathExtension].lowercaseString]=fileURL;NSURL *remote=[NSURL URLWithString:row[@"url"]];if(remote.path.lastPathComponent.length)pathMap[remote.path.lastPathComponent.lowercaseString]=fileURL;}}
 for(PVXHLSSegment *segment in best.segments){NSURL *segmentURL=[NSURL URLWithString:segment.URI];if(segmentURL.isFileURL&&[[NSFileManager defaultManager] fileExistsAtPath:segmentURL.path])local[segment.URI]=segment.URI;if(!local[segment.URI]){NSString *mapped=pathMap[segmentURL.path.lastPathComponent.lowercaseString];if(mapped)local[segment.URI]=mapped;}if(!local[segment.URI]){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:22 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"HLS 分片未找到本地缓存：%@",segmentURL.path.lastPathComponent?:segment.URI]}];return NO;}if(segment.key.URI.length&&!local[segment.key.URI]){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:23 userInfo:@{NSLocalizedDescriptionKey:@"HLS KEY 未找到本地缓存"}];return NO;}if(segment.map.URI.length&&!local[segment.map.URI]){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:24 userInfo:@{NSLocalizedDescriptionKey:@"HLS MAP 初始化段未找到本地缓存"}];return NO;}if(segment.discontinuity||segment.gap){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:21 userInfo:@{NSLocalizedDescriptionKey:@"HLS 包含 DISCONTINUITY/GAP，未伪造时间线"}];return NO;}}
 NSMutableArray *ordered=[best.segments mutableCopy];NSMutableDictionary *seenSequence=[NSMutableDictionary dictionary];BOOL hasCompleteSequence=ordered.count==rows.count;for(PVXHLSSegment *segment in ordered){NSString *number=sequenceByLocal[local[segment.URI]];if(!number||[number longLongValue]<0||seenSequence[number]){hasCompleteSequence=NO;break;}seenSequence[number]=@YES;}NSArray *sequenceKeys=seenSequence.allKeys;long long sequenceMin=sequenceKeys.count?[[sequenceKeys valueForKeyPath:@"@min.longLongValue"] longLongValue]:-1,sequenceMax=sequenceKeys.count?[[sequenceKeys valueForKeyPath:@"@max.longLongValue"] longLongValue]:-1;if(hasCompleteSequence&&seenSequence.count==ordered.count&&sequenceMin>=0&&sequenceMax-sequenceMin+1==(long long)ordered.count)[ordered sortUsingComparator:^NSComparisonResult(PVXHLSSegment*a,PVXHLSSegment*b){long long x=[sequenceByLocal[local[a.URI]] longLongValue],y=[sequenceByLocal[local[b.URI]] longLongValue];return x==y?NSOrderedSame:(x<y?NSOrderedAscending:NSOrderedDescending);}];
 NSString *text=[best localizedTextWithSegments:ordered localURLs:local];NSData *out=[text dataUsingEncoding:NSUTF8StringEncoding];if(![out writeToFile:output options:NSDataWritingAtomic error:outError])return NO;chmod(output.fileSystemRepresentation,0600);return YES;
}
static BOOL PVXFFmpegRemux(NSString *input,NSString *output,NSError **outError){
 if(!PVXLoadFFmpegKit()){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:10 userInfo:@{NSLocalizedDescriptionKey:FFmpegLoadError?:@"FFmpegKit 未加载，恢复未执行"}];return NO;}
 SEL execute=NSSelectorFromString(@"executeWithArguments:");if(![FFmpegKitClass respondsToSelector:execute]){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:11 userInfo:@{NSLocalizedDescriptionKey:@"FFmpegKit 接口不可用"}];return NO;}
 BOOL playlist=[input.pathExtension.lowercaseString isEqual:@"m3u8"];NSMutableArray *args=[NSMutableArray arrayWithObjects:@"-hide_banner",@"-loglevel",@"error",@"-y",nil];if(playlist){[args addObjectsFromArray:@[@"-protocol_whitelist",@"file,crypto,data",@"-allowed_extensions",@"ALL",@"-fflags",@"+genpts",@"-i",input]];}else{[args addObjectsFromArray:@[@"-f",@"mpegts",@"-i",input]];}[args addObjectsFromArray:@[@"-map",@"0:v:0?",@"-map",@"0:a:0?",@"-c",@"copy",@"-avoid_negative_ts",@"make_zero",@"-max_interleave_delta",@"0",@"-movflags",@"+faststart",output]];
 id session=((id(*)(id,SEL,id))objc_msgSend)(FFmpegKitClass,execute,args);SEL getRC=NSSelectorFromString(@"getReturnCode");id rc=[session respondsToSelector:getRC]?((id(*)(id,SEL))objc_msgSend)(session,getRC):nil;SEL success=NSSelectorFromString(@"isValueSuccess");BOOL ok=rc&&[rc respondsToSelector:success]&&((BOOL(*)(id,SEL))objc_msgSend)(rc,success);struct stat st;if(ok)ok=!lstat(output.fileSystemRepresentation,&st)&&S_ISREG(st.st_mode)&&st.st_size>0;if(!ok){NSString *detail=rc&&[rc respondsToSelector:NSSelectorFromString(@"description")]?[rc description]:@"FFmpegKit remux failed";if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:12 userInfo:@{NSLocalizedDescriptionKey:detail?:@"FFmpegKit remux failed"}];[[NSFileManager defaultManager] removeItemAtPath:output error:nil];}return ok;
}

static void PVXPersistRecoveryResult(id agent,NSString *uuid,NSString *dest,BOOL valid,NSString *failure){NSMutableDictionary *t=[[[agent tasks] objectForKey:uuid] mutableCopy];if(!t)return;struct stat st;PVXDiagnostic([NSString stringWithFormat:@"hls-%@-result",uuid],@{@"event":valid?@"recovery-output-valid":@"recovery-output-invalid",@"failure":failure?:@"",@"path":dest?:@""});if(valid&&!lstat(dest.fileSystemRepresentation,&st)){t[@"state"]=@"ready";t[@"fileComplete"]=@YES;t[@"received"]=@(st.st_size);t[@"total"]=@(st.st_size);t[@"mediaBytes"]=@(st.st_size);[t removeObjectForKey:@"error"];t[@"engine"]=@"PVXHLSManifest+FFmpegKit";t[@"engineVersion"]=@1;}else{t[@"state"]=@"failed";t[@"fileComplete"]=@NO;t[@"error"]=[NSString stringWithFormat:@"HLS 封装失败（输出校验）：%@",failure?:@"输出没有可读视频轨"]; }[[agent tasks] setObject:t forKey:uuid];if(Persist)Persist(agent,@selector(persist:),t);Notify(Signal);}
static void PVXValidateRecoveryFile(id agent,NSString *uuid,NSString *dest){AVURLAsset *asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:dest] options:nil];[asset loadValuesAsynchronouslyForKeys:@[@"tracks",@"duration",@"playable"] completionHandler:^{AVAssetTrack *video=[asset tracksWithMediaType:AVMediaTypeVideo].firstObject;BOOL valid=video&&asset.playable&&CMTimeGetSeconds(asset.duration)>0;NSString *reason=valid?nil:(video?@"AVAsset 无法播放或 duration 无效":@"输出没有视频轨");dispatch_async(dispatch_get_main_queue(),^{if(!valid)[[NSFileManager defaultManager] removeItemAtPath:dest error:nil];PVXPersistRecoveryResult(agent,uuid,dest,valid,reason);});}];}
static void PVXFinishRecovery(id agent,NSString*uuid,NSString*temp,BOOL success,NSError*error){[RecoveryExports removeObjectForKey:uuid];NSString *dest=Path([NSString stringWithFormat:@"media/%@.mp4",uuid]);if(success){[[NSFileManager defaultManager] removeItemAtPath:dest error:nil];if([[NSFileManager defaultManager] moveItemAtPath:temp toPath:dest error:&error]){PVXValidateRecoveryFile(agent,uuid,dest);return;}}[[NSFileManager defaultManager] removeItemAtPath:temp error:nil];if(error.localizedDescription.length){PVXPersistRecoveryResult(agent,uuid,dest,NO,error.localizedDescription);}}
static void PVXStartAVFoundationExport(id agent,NSString*uuid,NSString*ts,NSInteger attempt,NSString *previous){
 NSString *temp=Path([NSString stringWithFormat:@"media/%@.recovery.mp4",uuid]);[[NSFileManager defaultManager] removeItemAtPath:temp error:nil];AVURLAsset*asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:ts] options:nil];NSString*preset=attempt==0?AVAssetExportPresetPassthrough:AVAssetExportPresetHighestQuality;AVAssetExportSession*e=[[AVAssetExportSession alloc] initWithAsset:asset presetName:preset];if(!e){NSError*err=[NSError errorWithDomain:@"PVXRecovery" code:1 userInfo:@{NSLocalizedDescriptionKey:@"AVAssetExportSession unavailable"}];PVXFinishRecovery(agent,uuid,temp,NO,err);return;}e.outputURL=[NSURL fileURLWithPath:temp];e.outputFileType=AVFileTypeMPEG4;e.shouldOptimizeForNetworkUse=NO;RecoveryExports[uuid]=e;[e exportAsynchronouslyWithCompletionHandler:^{dispatch_async(dispatch_get_main_queue(),^{if(e.status==AVAssetExportSessionStatusCompleted){PVXFinishRecovery(agent,uuid,temp,YES,nil);return;}if(attempt==0){PVXStartAVFoundationExport(agent,uuid,ts,1,previous);return;}NSString *detail=e.error.localizedDescription?:@"MPEG-TS无法封装为MP4";if(previous.length)detail=[NSString stringWithFormat:@"%@；AVFoundation：%@",previous,detail];NSError*err=[NSError errorWithDomain:@"PVXRecovery" code:2 userInfo:@{NSLocalizedDescriptionKey:detail}];PVXFinishRecovery(agent,uuid,temp,NO,err);});}];
}
static void PVXStartRecoveryExport(id agent,NSString*uuid,NSString*ts,NSInteger attempt){(void)attempt;
 NSString *temp=Path([NSString stringWithFormat:@"media/%@.recovery.mp4",uuid]);RecoveryExports[uuid]=@YES;dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSError *err=nil;BOOL ok=PVXFFmpegRemux(ts,temp,&err);NSString *detail=err.localizedDescription;dispatch_async(dispatch_get_main_queue(),^{if(ok){PVXFinishRecovery(agent,uuid,temp,YES,nil);return;}PVXStartAVFoundationExport(agent,uuid,ts,0,detail);});});
}
static void PVXRecoverFailedHLS(id agent,NSDictionary*task){NSString*uuid=task[@"id"];if(!ValidID(uuid)||[RecoveryAttempted containsObject:uuid])return;[RecoveryAttempted addObject:uuid];PVXDiagnostic([NSString stringWithFormat:@"hls-%@-start",uuid],@{@"event":@"recovery-started",@"state":task[@"state"]?:@"",@"error":task[@"error"]?:@""});dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSString *playlist=Path([NSString stringWithFormat:@"media/%@.recovery.m3u8",uuid]);NSError *playlistError=nil;if(!PVXBuildLocalHLSPlaylist(uuid,playlist,&playlistError)){dispatch_async(dispatch_get_main_queue(),^{NSMutableDictionary *t=[[[agent tasks] objectForKey:uuid] mutableCopy];if(t){PVXDiagnostic([NSString stringWithFormat:@"hls-%@-playlist",uuid],@{@"event":@"playlist-build-failed",@"error":playlistError.localizedDescription?:@""});t[@"state"]=@"failed";t[@"fileComplete"]=@NO;t[@"error"]=[NSString stringWithFormat:@"HLS 封装失败（清单重建）：%@",playlistError.localizedDescription?:@"无法重建本地清单"];if(Persist)Persist(agent,@selector(persist:),t);Notify(Signal);}});return;}dispatch_async(dispatch_get_main_queue(),^{PVXStartRecoveryExport(agent,uuid,playlist,0);});});}
static void PVXScanFailedHLS(id agent){for(NSDictionary*t in [[agent tasks] allValues]){NSString *error=[t[@"error"] isKindOfClass:NSString.class]?t[@"error"]:@"";if([t[@"state"] isEqual:@"failed"]&&([error containsString:@"HLS 封装失败"]||[error containsString:@"HLS恢复封装失败"]))PVXRecoverFailedHLS(agent,t);}}
static void Tick(void) {
    id agent = Worker;
    if (agent && [agent workerMode] && [agent reconciled]) { [agent exportReady]; PVXScanFailedHLS(agent); }
}
static BOOL Start(id self, SEL cmd) {
    BOOL result = OldStart(self, cmd);
    if (result && [self workerMode]) Worker = self;
    return result;
}

// Beta3: foreground system sharing is the sole export entrypoint. Drain old
// requests without inspecting preferences or ever calling the original exporter.
static void DropLegacyPhotos(void) {
    NSString *dir = Path(@"plus-manual-photos");
    if (!SafeDirectory(dir)) return;
    int fd = open(dir.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return;
    DIR *d = fdopendir(fd);
    if (!d) { close(fd); return; }
    unsigned scanned = 0;
    struct dirent *entry;
    while (scanned++ < 256 && (entry = readdir(d))) {
        NSString *name = [[NSString alloc] initWithUTF8String:entry->d_name];
        NSString *leaf = [name hasSuffix:@".claimed"] ? name.stringByDeletingPathExtension : name;
        if ([leaf.pathExtension isEqual:@"plist"] && ValidID(leaf.stringByDeletingPathExtension))
            unlinkat(fd,name.fileSystemRepresentation,0);
    }
    fsync(fd);
    closedir(d);
}
static void Export(id self, SEL cmd) {
    (void)cmd;
    if (!NSThread.isMainThread || ![self workerMode]) return;
    Worker = self;
    DropLegacyPhotos();
    // OldExport is intentionally NEVER entered. Already active Beta2 saves are
    // still finalized by Finish, preserving original/compatible retention hooks.
}

static BOOL Remove(id self, SEL cmd, NSString *path, NSError **error) {
    NSSet *protected = (__bridge id)ProtectedPaths;
    if (protected && [protected containsObject:path]) return YES;
    return OldRemove(self, cmd, path, error);
}
static void Finish(id self, SEL cmd, id uuid, BOOL success, id error, id assetID) {
    NSDictionary *task = ValidID(uuid) ? OldTasks(self, @selector(tasks))[uuid] : nil;
    BOOL eligible = NSThread.isMainThread && success && ![self clearingRequest] &&
        [[self exports] containsObject:uuid] && [task[@"state"] isEqual:@"saving"];
    NSSet *protected = nil;
    NSString *retained = nil;
    if (eligible) {
        NSString *original = Media(uuid);
        NSString *compatible = [original stringByAppendingString:@".compatible.mp4"];
        retained = Path([NSString stringWithFormat:@"retained/%@.mp4", uuid]);
        // Prefer original; only use compatible when original is absent.
        struct stat st;
        BOOL originalExists = !lstat(original.fileSystemRepresentation, &st);
        NSString *source = originalExists ? original : compatible;
        BOOL copied = SafeDirectory(Path(@"retained")) && PVXRetainDisk(source.fileSystemRepresentation, retained.fileSystemRepresentation);
        if (copied) {
            NSMutableDictionary *metadata = [@{@"id":uuid, @"source":originalExists ? @"original" : @"compatible", @"created":@(NSDate.date.timeIntervalSince1970)} mutableCopy];
            if ([task[@"mediaBytes"] isKindOfClass:NSNumber.class]) metadata[@"mediaBytes"] = task[@"mediaBytes"];
            Write(metadata, [retained stringByAppendingString:@".plist"], NULL);
        } else {
            // Disk full/permission/collision: preserve both exact media leaves while
            // original commits the real Photos success and savedAt/assetID.
            protected = [NSSet setWithObjects:original, compatible, nil];
        }
    }
    void *previous = ProtectedPaths;
    ProtectedPaths = (__bridge void *)protected;
    @try { OldFinish(self, cmd, uuid, success, error, assetID); }
    @finally { ProtectedPaths = previous; }
    if (eligible) Notify(Signal);
}
static void Delete(id self, SEL cmd, id uuid) {
    OldDelete(self, cmd, uuid);
    NSDictionary *task = ValidID(uuid) ? OldTasks(self, @selector(tasks))[uuid] : nil;
    if ([task[@"state"] isEqual:@"deleted"]) {
        NSString *p = Path([NSString stringWithFormat:@"retained/%@.mp4", uuid]);
        unlink(p.fileSystemRepresentation);
        unlink([p stringByAppendingString:@".plist"].fileSystemRepresentation);
    }
}

static NSInteger PVXConfiguredParallel(void){NSDictionary *v=[NSDictionary dictionaryWithContentsOfFile:Path(@"plus-preferences.plist")];NSInteger n=[v[@"parallelDownloads"] integerValue];return n>=1&&n<=15?n:15;}
static void PVXPumpWithConfiguredLimit(id self, SEL cmd){
    OldPump(self,cmd);
    if(![self workerMode]||![self reconciled]||![self memoryReady])return;
    NSMutableDictionary *tasks=[self tasks],*jobs=[self valueForKey:@"jobs"],*checks=[self valueForKey:@"checks"];if(!tasks||!jobs||!checks)return;
    NSInteger limit=PVXConfiguredParallel(),active=(NSInteger)jobs.count+(NSInteger)checks.count;if(active>=limit)return;
    for(NSDictionary *task in [tasks.allValues copy]){
        if(active>=limit||![task isKindOfClass:NSDictionary.class]||![task[@"state"] isEqual:@"queued"]||!ValidID(task[@"id"])||jobs[task[@"id"]]||checks[task[@"id"]])continue;
        NSString *hls=[task[@"hlsSourceURL"] isKindOfClass:NSString.class]?task[@"hlsSourceURL"]:nil;
        ((void(*)(id,SEL,id,id))objc_msgSend)(self,NSSelectorFromString(@"startTask:hlsURL:"),task,hls);active++;
    }
}
static void (*OldClear)(id, SEL);
static void Clear(id self, SEL cmd) {
    BOOL wasClearing = [self clearingRequest] != nil;
    OldClear(self, cmd);
    if (!wasClearing || [self clearingRequest] || [OldTasks(self, @selector(tasks)) count]) return;
    NSString *dir = Path(@"retained");
    if (!SafeDirectory(dir)) return;
    DIR *d = opendir(dir.fileSystemRepresentation);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        NSString *name = [[NSString alloc] initWithUTF8String:e->d_name];
        NSString *uuid = [name hasSuffix:@".mp4.plist"] ? [name substringToIndex:name.length - 10] : name.stringByDeletingPathExtension;
        if (ValidID(uuid) && ([name hasSuffix:@".mp4"] || [name hasSuffix:@".mp4.plist"])) unlink([dir stringByAppendingPathComponent:name].fileSystemRepresentation);
    }
    closedir(d);
}

static BOOL Signature(Class cls, SEL sel, const char *ret, unsigned count, const char **args) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method || method_getNumberOfArguments(method) != count + 2) return NO;
    char *type = method_copyReturnType(method);
    BOOL ok = type && !strcmp(type, ret);
    free(type);
    for (unsigned i = 0; ok && i < count + 2; i++) {
        type = method_copyArgumentType(method, i);
        const char *expected = i == 0 ? "@" : i == 1 ? ":" : args[i - 2];
        ok = type && !strcmp(type, expected);
        free(type);
    }
    return ok;
}
static BOOL KnownImage(void) {
    const struct mach_header_64 *h = (const void *)_dyld_get_image_header(0);
    // The agent is already identified by process name and the complete ABI
    // signature gate below. A fixed UUID became stale after every Apple
    // rebuild/re-sign and silently prevented Storage from ever installing.
    return h && h->magic == MH_MAGIC_64 && h->filetype == MH_EXECUTE;
}
#ifndef PVX_STORAGE_MOCK
__attribute__((constructor))
static void Install(void) {
    @autoreleasepool {
        PVXBootLog(@"constructor-enter");
        if (![NSProcessInfo.processInfo.arguments.firstObject.lastPathComponent isEqual:@"PyVideoAgent"] || !KnownImage()) { PVXBootLog(@"gate-process-or-uuid-failed"); return; }
        Class c = NSClassFromString(@"PVAgent");
        const char *finishArgs[] = {"@", "B", "@", "@"};
        const char *one[] = {"@"};
        const char *removeArgs[] = {"@", "^@"};
        const char *twoObjects[] = {"@", "@"};
        // All checks happen before any mutation. Unsupported ABI leaves original intact.
        if (!c || !Signature(c, @selector(startWorker), "B", 0, NULL) ||
            !Signature(c, @selector(exportReady), "v", 0, NULL) ||
            !Signature(c, @selector(pump), "v", 0, NULL) ||
            !Signature(c, @selector(persist:), "B", 1, one) ||
            !Signature(c, NSSelectorFromString(@"startTask:hlsURL:"), "v", 2, twoObjects) ||
            !Signature(c, @selector(tasks), "@", 0, NULL) ||
            !Signature(c, @selector(workerMode), "B", 0, NULL) ||
            !Signature(c, @selector(reconciled), "B", 0, NULL) ||
            !Signature(c, @selector(memoryReady), "B", 0, NULL) ||
            !Signature(c, @selector(exports), "@", 0, NULL) ||
            !Signature(c, @selector(clearingRequest), "@", 0, NULL) ||
            !Signature(c, NSSelectorFromString(@"finishExport:success:error:assetID:"), "v", 4, finishArgs) ||
            !Signature(c, NSSelectorFromString(@"finishDeletion:"), "v", 1, one) ||
            !Signature(c, NSSelectorFromString(@"finishClearAll"), "v", 0, NULL) ||
            !Signature(NSFileManager.class, @selector(removeItemAtPath:error:), "B", 2, removeArgs)) { PVXBootLog(@"gate-agent-abi-failed"); return; }
        PVXBootLog(@"gate-agent-abi-ok");
        RecoveryAttempted=[NSMutableSet set];RecoveryExports=[NSMutableDictionary dictionary];
        Persist=(void *)class_getMethodImplementation(c,@selector(persist:));
        Hook = (void *)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
        if (!Hook) {
            NSString *base = [NSProcessInfo.processInfo.arguments.firstObject stringByDeletingLastPathComponent];
            for (NSString *leaf in @[@".jbroot/usr/lib/libsubstrate.dylib", @".jbroot/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"]) {
                void *handle = dlopen([[base stringByAppendingPathComponent:leaf] fileSystemRepresentation], RTLD_NOW | RTLD_GLOBAL);
                if (handle) Hook = (void *)dlsym(handle, "MSHookMessageEx");
                if (Hook) break;
            }
        }
        Root = (void *)dlsym(RTLD_DEFAULT, "PVStateDirectory");
        Media = (void *)dlsym(RTLD_DEFAULT, "PVMediaPath");
        Write = (void *)dlsym(RTLD_DEFAULT, "PVWrite");
        Notify = (void *)dlsym(RTLD_DEFAULT, "PVNotify");
        if (!Hook || !Root || !Media || !Write || !Notify) { PVXBootLog(@"gate-symbol-lookup-failed"); return; }
        PVXBootLog(@"gate-symbol-lookup-ok");
        // Require the original C entrypoints to belong to the executable image.
        void *symbols[] = {(void *)Root, (void *)Media, (void *)Write, (void *)Notify};
        for (unsigned i = 0; i < sizeof(symbols)/sizeof(symbols[0]); i++) {
            Dl_info info;
            if (!dladdr(symbols[i], &info) || info.dli_fbase != (void *)_dyld_get_image_header(0)) { PVXBootLog(@"gate-symbol-owner-failed"); return; }
        }
        if (!SafeDirectory(Root())) { PVXBootLog(@"gate-root-directory-failed"); return; }
        PVXBootLog(@"gate-root-directory-ok");
        Hook(c, @selector(tasks), (IMP)TasksView, (IMP *)&OldTasks);
        Hook(c, @selector(pump), (IMP)PVXPumpWithConfiguredLimit, (IMP *)&OldPump);
        Hook(NSFileManager.class, @selector(removeItemAtPath:error:), (IMP)Remove, (IMP *)&OldRemove);
        Hook(c, NSSelectorFromString(@"finishExport:success:error:assetID:"), (IMP)Finish, (IMP *)&OldFinish);
        Hook(c, NSSelectorFromString(@"finishDeletion:"), (IMP)Delete, (IMP *)&OldDelete);
        Hook(c, NSSelectorFromString(@"finishClearAll"), (IMP)Clear, (IMP *)&OldClear);
        Hook(c, @selector(startWorker), (IMP)Start, (IMP *)&OldStart);
        Hook(c, @selector(exportReady), (IMP)Export, (IMP *)&OldExport);
        dispatch_async(dispatch_get_main_queue(), ^{
            notify_register_dispatch(Signal.UTF8String, &NotificationToken, dispatch_get_main_queue(), ^(int token) { (void)token; Tick(); });
            Timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(Timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
            dispatch_source_set_event_handler(Timer, ^{ @autoreleasepool { Tick(); } });
            dispatch_resume(Timer);
        });
    }
}
#endif // !PVX_STORAGE_MOCK
#endif // !PVX_STORAGE_IO_TEST

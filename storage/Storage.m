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
static _Thread_local void *ProtectedPaths;
static NSString *const Signal = @"com.crctdd.pyvideo.plus.storage";

static BOOL ValidID(id value) {
    return [value isKindOfClass:NSString.class] && [value length] == 36 &&
        [[NSUUID alloc] initWithUUIDString:value] != nil;
}
static NSString *PVXFallbackRoot(void){NSString *home=NSHomeDirectory();return [home stringByAppendingPathComponent:@"Library/Application Support/com.crctdd.pyvideo"];}
static NSString *Path(NSString *leaf){NSString *root=Root?Root():nil;if(!root.length)root=PVXFallbackRoot();return [root stringByAppendingPathComponent:leaf];}
static BOOL SafeDirectory(NSString *path){struct stat s;if(lstat(path.fileSystemRepresentation,&s)){if(errno!=ENOENT||mkdir(path.fileSystemRepresentation,0700))return NO;if(lstat(path.fileSystemRepresentation,&s))return NO;}return S_ISDIR(s.st_mode)&&!S_ISLNK(s.st_mode)&&s.st_uid==geteuid();}
static void PVXBootMark(NSString *stage,NSDictionary *fields){if(!stage.length)return;NSString *dir=Path(@"plus-diagnostics");if(!SafeDirectory(dir))return;NSMutableDictionary *payload=[fields mutableCopy]?:[NSMutableDictionary dictionary];payload[@"stage"]=stage;payload[@"updated"]=@(NSDate.date.timeIntervalSince1970);NSString *file=[dir stringByAppendingPathComponent:@"storage-bootstrap.plist"];[payload writeToFile:file atomically:YES];NSString *stageFile=[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"storage-%@.plist",stage]];[payload writeToFile:stageFile atomically:YES];}
static void PVXDiagnostic(NSString *name,NSDictionary *value){if(!name.length)return;NSString *dir=Path(@"plus-diagnostics");if(!SafeDirectory(dir))return;NSMutableDictionary *payload=[value mutableCopy]?:[NSMutableDictionary dictionary];payload[@"updated"] = @(NSDate.date.timeIntervalSince1970);NSString *file=[dir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"plist"]];if(Write)Write(payload,file,NULL);else[payload writeToFile:file atomically:YES];}
static long long PVXSegmentIndex(NSString *url,NSDictionary *meta){for(NSString *key in @[@"segmentIndex",@"sequence",@"sequenceNumber",@"index",@"number",@"order"]){id value=meta[key];if([value respondsToSelector:@selector(longLongValue)]&&[value longLongValue]>=0)return [value longLongValue];}NSString *stem=url.stringByDeletingPathExtension;long long last=-1;NSUInteger i=0;while(i<stem.length){while(i<stem.length&&![NSCharacterSet.decimalDigitCharacterSet characterIsMember:[stem characterAtIndex:i]])i++;if(i>=stem.length)break;NSUInteger start=i;while(i<stem.length&&[NSCharacterSet.decimalDigitCharacterSet characterIsMember:[stem characterAtIndex:i]])i++;NSString *n=[stem substringWithRange:NSMakeRange(start,i-start)];last=n.longLongValue;}return last;}
static NSArray *PVXOrderedHLSFiles(NSString *uuid){NSString *dir=Path([NSString stringWithFormat:@"media/%@.hls",uuid]);NSArray *names=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];NSMutableArray *rows=[NSMutableArray array];for(NSString *name in names){if(!([name hasSuffix:@".ts.plist"]||[name hasSuffix:@".m4s.plist"]||[name hasSuffix:@".mp4.plist"]))continue;NSDictionary *meta=[NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:name]];NSString *response=meta[@"responseURL"]?:meta[@"url"];if(![response isKindOfClass:NSString.class])continue;NSString *segment=[name substringToIndex:name.length-6],*path=[dir stringByAppendingPathComponent:segment];struct stat st;if(lstat(path.fileSystemRepresentation,&st)||!S_ISREG(st.st_mode)||st.st_size<=0)continue;[rows addObject:@{@"index":@(PVXSegmentIndex(response,meta)),@"url":response,@"path":path,@"name":name,@"bytes":@(st.st_size)}];}[rows sortUsingComparator:^NSComparisonResult(NSDictionary*a,NSDictionary*b){long long x=[a[@"index"] longLongValue],y=[b[@"index"] longLongValue];if(x>=0&&y>=0&&x!=y)return x<y?NSOrderedAscending:NSOrderedDescending;NSComparisonResult u=[a[@"url"] compare:b[@"url"]];return u==NSOrderedSame?[a[@"name"] compare:b[@"name"]]:u;}];return rows;}
static void PVXFinishRecovery(id agent,NSString*uuid,NSString*temp,BOOL success,NSError*error);
static BOOL PVXLoadFFmpegKit(void);
static NSString *PVXFFmpegLeaf(void){return @"Frameworks/ffmpegkit.framework/ffmpegkit";}
static NSArray<NSString*> *PVXFFmpegCandidates(void){NSMutableOrderedSet *set=[NSMutableOrderedSet orderedSet];NSString *leaf=PVXFFmpegLeaf();NSString *exe=NSProcessInfo.processInfo.arguments.firstObject;NSString *exeDir=exe.stringByDeletingLastPathComponent;NSString *main=[NSBundle mainBundle].bundlePath;for(NSString *root in @[main?:@"",exeDir?:@""]){if(root.length)[set addObject:[root stringByAppendingPathComponent:leaf]];}Dl_info info={0};if(dladdr((const void *)PVXLoadFFmpegKit,&info)&&info.dli_fname){NSString *storageDir=[NSString stringWithUTF8String:info.dli_fname].stringByDeletingLastPathComponent;[set addObject:[storageDir stringByAppendingPathComponent:leaf]];}[set addObject:@"@rpath/ffmpegkit.framework/ffmpegkit"];[set addObject:@"/Applications/PyVideoAgent.app/Frameworks/ffmpegkit.framework/ffmpegkit"];[set addObject:@"/var/jb/Applications/PyVideoAgent.app/Frameworks/ffmpegkit.framework/ffmpegkit"];return set.array;}
static BOOL PVXLoadFFmpegKit(void){
 if(FFmpegKitClass)return YES;
 NSMutableArray *attempts=[NSMutableArray array];
 for(NSString *path in PVXFFmpegCandidates()){
  BOOL exists=access(path.fileSystemRepresentation,F_OK)==0;
  void *handle=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_GLOBAL);
  const char *raw=dlerror();NSString *detail=raw?[NSString stringWithUTF8String:raw]:@"";
  [attempts addObject:@{ @"path":path, @"exists":@(exists), @"loaded":@(handle!=NULL), @"error":detail }];
  if(handle){FFmpegHandle=handle;break;}
 }
 FFmpegKitClass=NSClassFromString(@"FFmpegKit");
 PVXDiagnostic(@"ffmpeg-load",@{ @"loaded":@(FFmpegHandle!=NULL&&FFmpegKitClass!=Nil), @"attempts":attempts });
 if(!FFmpegHandle||!FFmpegKitClass){FFmpegLoadError=[attempts.lastObject[@"error"] length]?attempts.lastObject[@"error"]:@"FFmpegKit 未加载";return NO;}
 return YES;
}
static NSDictionary *PVXAllHLSResources(NSString *uuid){NSString *dir=Path([NSString stringWithFormat:@"media/%@.hls",uuid]);NSArray *names=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];NSMutableDictionary *map=[NSMutableDictionary dictionary];for(NSString *name in names){if(![name.pathExtension.lowercaseString isEqual:@"plist"])continue;NSDictionary *meta=[NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:name]];NSString *remote=meta[@"responseURL"]?:meta[@"url"]?:meta[@"source"];if(![remote isKindOfClass:NSString.class])continue;NSString *file=[name stringByDeletingPathExtension],*path=[dir stringByAppendingPathComponent:file];struct stat st;if(lstat(path.fileSystemRepresentation,&st)||!S_ISREG(st.st_mode)||st.st_size<=0)continue;NSString *local=[NSURL fileURLWithPath:path].absoluteString;NSString *base=path.lastPathComponent.lowercaseString;map[remote]=local;map[remote.lowercaseString]=local;map[base]=local;map[file.lowercaseString]=local;NSURL *u=[NSURL URLWithString:remote];if(u.path.lastPathComponent.length)map[u.path.lastPathComponent.lowercaseString]=local;}return map;}
static BOOL PVXBuildLocalHLSPlaylist(NSString *uuid,NSString *output,NSError **outError){
 NSString *dir=Path([NSString stringWithFormat:@"media/%@.hls",uuid]);NSArray *names=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];PVXHLSManifest *best=nil;NSUInteger bestCount=0;
 for(NSString *name in names){NSString *ext=name.pathExtension.lowercaseString;if(!([ext isEqual:@"m3u8"]||[ext isEqual:@"txt"]||[name.lowercaseString containsString:@"playlist"]))continue;NSString *path=[dir stringByAppendingPathComponent:name];NSData *data=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];if(data.length>2*1024*1024)continue;NSError *e=nil;PVXHLSManifest *m=[PVXHLSManifest parseData:data baseURL:[NSURL fileURLWithPath:path] error:&e];if(m&&!m.master&&m.segments.count>bestCount){best=m;bestCount=m.segments.count;}}
 if(!best){NSArray *fallback=PVXOrderedHLSFiles(uuid);if(!fallback.count){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:20 userInfo:@{NSLocalizedDescriptionKey:@"HLS 目录没有可用分片元数据"}];return NO;}NSString *first=fallback.firstObject[@"path"];BOOL ts=[first.pathExtension.lowercaseString isEqual:@"ts"];if(!ts){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:25 userInfo:@{NSLocalizedDescriptionKey:@"HLS 无原始 media playlist，且缓存不是 MPEG-TS"}];return NO;}long long min=LLONG_MAX,max=LLONG_MIN;NSMutableSet *seen=[NSMutableSet set];for(NSDictionary *row in fallback){long long n=[row[@"index"] longLongValue];if(n<0||[seen containsObject:@(n)]){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:26 userInfo:@{NSLocalizedDescriptionKey:@"HLS 分片序号缺失或重复"}];return NO;}[seen addObject:@(n)];min=MIN(min,n);max=MAX(max,n);}if(max-min+1!=(long long)fallback.count){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:27 userInfo:@{NSLocalizedDescriptionKey:@"HLS 分片序号不连续，拒绝猜测时间线"}];return NO;}NSMutableString *synthetic=[NSMutableString stringWithFormat:@"#EXTM3U\\n#EXT-X-VERSION:3\\n#EXT-X-TARGETDURATION:10\\n#EXT-X-MEDIA-SEQUENCE:%lld\\n",min];for(NSDictionary *row in fallback){[synthetic appendString:@"#EXTINF:10.000,\\n"];[synthetic appendFormat:@"%@\\n",[NSURL fileURLWithPath:row[@"path"]].absoluteString];}[synthetic appendString:@"#EXT-X-ENDLIST\\n"];NSData *out=[synthetic dataUsingEncoding:NSUTF8StringEncoding];if(![out writeToFile:output options:NSDataWritingAtomic error:outError])return NO;chmod(output.fileSystemRepresentation,0600);return YES;}
 NSArray *rows=PVXOrderedHLSFiles(uuid);NSMutableDictionary *local=[PVXAllHLSResources(uuid) mutableCopy];NSMutableDictionary *pathMap=[NSMutableDictionary dictionary];NSMutableDictionary *sequenceByLocal=[NSMutableDictionary dictionary];for(NSDictionary *row in rows){NSString *file=row[@"path"];if(file.length){NSString *fileURL=[NSURL fileURLWithPath:file].absoluteString;sequenceByLocal[fileURL]=row[@"index"];local[fileURL]=fileURL;pathMap[file.lastPathComponent.lowercaseString]=fileURL;pathMap[[file.lastPathComponent stringByDeletingPathExtension].lowercaseString]=fileURL;NSURL *remote=[NSURL URLWithString:row[@"url"]];if(remote.path.lastPathComponent.length)pathMap[remote.path.lastPathComponent.lowercaseString]=fileURL;}}
 for(PVXHLSSegment *segment in best.segments){NSURL *segmentURL=[NSURL URLWithString:segment.URI];if(segmentURL.isFileURL&&[[NSFileManager defaultManager] fileExistsAtPath:segmentURL.path])local[segment.URI]=segment.URI;if(!local[segment.URI]){NSString *mapped=pathMap[segmentURL.path.lastPathComponent.lowercaseString];if(mapped)local[segment.URI]=mapped;}if(!local[segment.URI]){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:22 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"HLS 分片未找到本地缓存：%@",segmentURL.path.lastPathComponent?:segment.URI]}];return NO;}if(segment.key.URI.length&&!local[segment.key.URI]){NSURL *keyURL=[NSURL URLWithString:segment.key.URI];if(keyURL.scheme.length&&![@[@"http",@"https",@"file"] containsObject:keyURL.scheme.lowercaseString]){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:23 userInfo:@{NSLocalizedDescriptionKey:@"HLS KEY URI 协议无效"}];return NO;}}
 if(segment.map.URI.length&&!local[segment.map.URI]){NSURL *mapURL=[NSURL URLWithString:segment.map.URI];if(!mapURL.isFileURL){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:24 userInfo:@{NSLocalizedDescriptionKey:@"HLS MAP 未找到本地缓存"}];return NO;}}if(segment.discontinuity||segment.gap){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:21 userInfo:@{NSLocalizedDescriptionKey:@"HLS 包含 DISCONTINUITY/GAP，未伪造时间线"}];return NO;}}
 NSMutableArray *ordered=[best.segments mutableCopy];NSMutableDictionary *seenSequence=[NSMutableDictionary dictionary];BOOL hasCompleteSequence=ordered.count==rows.count;for(PVXHLSSegment *segment in ordered){NSString *number=sequenceByLocal[local[segment.URI]];if(!number||[number longLongValue]<0||seenSequence[number]){hasCompleteSequence=NO;break;}seenSequence[number]=@YES;}NSArray *sequenceKeys=seenSequence.allKeys;long long sequenceMin=sequenceKeys.count?[[sequenceKeys valueForKeyPath:@"@min.longLongValue"] longLongValue]:-1,sequenceMax=sequenceKeys.count?[[sequenceKeys valueForKeyPath:@"@max.longLongValue"] longLongValue]:-1;if(hasCompleteSequence&&seenSequence.count==ordered.count&&sequenceMin>=0&&sequenceMax-sequenceMin+1==(long long)ordered.count)[ordered sortUsingComparator:^NSComparisonResult(PVXHLSSegment*a,PVXHLSSegment*b){long long x=[sequenceByLocal[local[a.URI]] longLongValue],y=[sequenceByLocal[local[b.URI]] longLongValue];return x==y?NSOrderedSame:(x<y?NSOrderedAscending:NSOrderedDescending);}];
 NSString *text=[best localizedTextWithSegments:ordered localURLs:local];NSData *out=[text dataUsingEncoding:NSUTF8StringEncoding];if(![out writeToFile:output options:NSDataWritingAtomic error:outError])return NO;chmod(output.fileSystemRepresentation,0600);return YES;
}
static BOOL PVXConcatenateTS(NSString *uuid,NSString *output,NSError **outError){NSArray *rows=PVXOrderedHLSFiles(uuid);if(!rows.count){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:30 userInfo:@{NSLocalizedDescriptionKey:@"没有可拼接的 HLS 分片"}];return NO;}NSString *temp=[output stringByAppendingString:@".partial"];[[NSFileManager defaultManager] removeItemAtPath:temp error:nil];NSFileHandle *writer=[NSFileHandle fileHandleForWritingAtPath:temp];if(!writer){[[NSFileManager defaultManager] createFileAtPath:temp contents:nil attributes:@{NSFilePosixPermissions:@0600}];writer=[NSFileHandle fileHandleForWritingAtPath:temp];}if(!writer){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:31 userInfo:@{NSLocalizedDescriptionKey:@"无法创建 TS fallback 文件"}];return NO;}BOOL ok=YES;unsigned long long total=0;for(NSDictionary *row in rows){NSString *path=row[@"path"];if(![path.pathExtension.lowercaseString isEqual:@"ts"]){ok=NO;if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:32 userInfo:@{NSLocalizedDescriptionKey:@"HLS 不是 MPEG-TS 分片，无法使用 AVFoundation fallback"}];break;}NSFileHandle *reader=[NSFileHandle fileHandleForReadingAtPath:path];if(!reader){ok=NO;if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:33 userInfo:@{NSLocalizedDescriptionKey:@"HLS 分片无法读取"}];break;}NSData *head=[reader readDataOfLength:1];if(head.length!=1||((const unsigned char*)head.bytes)[0]!=0x47){[reader closeFile];ok=NO;if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:34 userInfo:@{NSLocalizedDescriptionKey:@"HLS 分片不是有效 MPEG-TS"}];break;}[writer writeData:head];for(;;){NSData *chunk=[reader readDataOfLength:1024*1024];if(!chunk.length)break;[writer writeData:chunk];total+=chunk.length;}[reader closeFile];}if(@available(iOS 13.0,*)){@try{[writer synchronizeAndReturnError:NULL];} @catch(__unused NSException *x){}}[writer closeFile];if(ok&&total>0){[[NSFileManager defaultManager] removeItemAtPath:output error:nil];ok=[[NSFileManager defaultManager] moveItemAtPath:temp toPath:output error:outError];}else{[[NSFileManager defaultManager] removeItemAtPath:temp error:nil];}if(ok)chmod(output.fileSystemRepresentation,0600);return ok;}
static BOOL PVXFFmpegRemux(NSString *input,NSString *output,NSDictionary *task,NSError **outError){
 if(!PVXLoadFFmpegKit()){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:10 userInfo:@{NSLocalizedDescriptionKey:FFmpegLoadError?:@"FFmpegKit 未加载，恢复未执行"}];return NO;}
 SEL execute=NSSelectorFromString(@"executeWithArguments:");if(![FFmpegKitClass respondsToSelector:execute]){if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:11 userInfo:@{NSLocalizedDescriptionKey:@"FFmpegKit 接口不可用"}];return NO;}
 BOOL playlist=[input.pathExtension.lowercaseString isEqual:@"m3u8"];NSMutableArray *args=[NSMutableArray arrayWithObjects:@"-hide_banner",@"-loglevel",@"error",@"-y",nil];NSString *referer=[task[@"headers"] isKindOfClass:NSDictionary.class]?task[@"headers"][@"Referer"]:nil;NSString *ua=[task[@"headers"] isKindOfClass:NSDictionary.class]?task[@"headers"][@"User-Agent"]:nil;NSMutableString *header=[NSMutableString string];if(referer.length)[header appendFormat:@"Referer: %@\r\n",referer];if(ua.length)[header appendFormat:@"User-Agent: %@\r\n",ua];if(header.length)[args addObjectsFromArray:@[@"-headers",header]];if(playlist){[args addObjectsFromArray:@[@"-protocol_whitelist",@"file,crypto,data,http,https",@"-allowed_extensions",@"ALL",@"-fflags",@"+genpts",@"-i",input]];}else{[args addObjectsFromArray:@[@"-f",@"mpegts",@"-i",input]];}[args addObjectsFromArray:@[@"-map",@"0:v:0?",@"-map",@"0:a:0?",@"-c",@"copy",@"-avoid_negative_ts",@"make_zero",@"-max_interleave_delta",@"0",@"-movflags",@"+faststart",output]];
 id session=((id(*)(id,SEL,id))objc_msgSend)(FFmpegKitClass,execute,args);SEL getRC=NSSelectorFromString(@"getReturnCode");id rc=[session respondsToSelector:getRC]?((id(*)(id,SEL))objc_msgSend)(session,getRC):nil;SEL success=NSSelectorFromString(@"isValueSuccess");BOOL ok=rc&&[rc respondsToSelector:success]&&((BOOL(*)(id,SEL))objc_msgSend)(rc,success);struct stat st;if(ok)ok=!lstat(output.fileSystemRepresentation,&st)&&S_ISREG(st.st_mode)&&st.st_size>0;if(!ok){NSString *detail=rc&&[rc respondsToSelector:NSSelectorFromString(@"description")]?[rc description]:@"FFmpegKit remux failed";if(outError)*outError=[NSError errorWithDomain:@"PVXRecovery" code:12 userInfo:@{NSLocalizedDescriptionKey:detail?:@"FFmpegKit remux failed"}];[[NSFileManager defaultManager] removeItemAtPath:output error:nil];}return ok;
}

static void PVXPersistRecoveryResult(id agent,NSString *uuid,NSString *dest,BOOL valid,NSString *failure){NSMutableDictionary *t=[[[agent tasks] objectForKey:uuid] mutableCopy];if(!t)return;struct stat st;PVXDiagnostic([NSString stringWithFormat:@"hls-%@-result",uuid],@{@"event":valid?@"recovery-output-valid":@"recovery-output-invalid",@"failure":failure?:@"",@"path":dest?:@""});if(valid&&!lstat(dest.fileSystemRepresentation,&st)){t[@"state"]=@"ready";t[@"fileComplete"]=@YES;t[@"received"]=@(st.st_size);t[@"total"]=@(st.st_size);t[@"mediaBytes"]=@(st.st_size);[t removeObjectForKey:@"error"];t[@"engine"]=@"PVXHLSManifest+FFmpegKit";t[@"engineVersion"]=@1;}else{t[@"state"]=@"failed";t[@"fileComplete"]=@NO;t[@"error"]=[NSString stringWithFormat:@"HLS 封装失败（输出校验）：%@",failure?:@"输出没有可读视频轨"]; }[[agent tasks] setObject:t forKey:uuid];if(Persist)Persist(agent,@selector(persist:),t);Notify(Signal);}
static void PVXValidateRecoveryFile(id agent,NSString *uuid,NSString *dest){AVURLAsset *asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:dest] options:nil];[asset loadValuesAsynchronouslyForKeys:@[@"tracks",@"duration",@"playable"] completionHandler:^{AVAssetTrack *video=[asset tracksWithMediaType:AVMediaTypeVideo].firstObject;BOOL valid=video&&asset.playable&&CMTimeGetSeconds(asset.duration)>0;NSString *reason=valid?nil:(video?@"AVAsset 无法播放或 duration 无效":@"输出没有视频轨");dispatch_async(dispatch_get_main_queue(),^{if(!valid)[[NSFileManager defaultManager] removeItemAtPath:dest error:nil];PVXPersistRecoveryResult(agent,uuid,dest,valid,reason);});}];}
static void PVXFinishRecovery(id agent,NSString*uuid,NSString*temp,BOOL success,NSError*error){[RecoveryExports removeObjectForKey:uuid];NSString *dest=Path([NSString stringWithFormat:@"media/%@.mp4",uuid]);if(success){[[NSFileManager defaultManager] removeItemAtPath:dest error:nil];if([[NSFileManager defaultManager] moveItemAtPath:temp toPath:dest error:&error]){[[NSFileManager defaultManager] removeItemAtPath:Path([NSString stringWithFormat:@"media/%@.recovery.ts",uuid]) error:nil];PVXValidateRecoveryFile(agent,uuid,dest);return;}}[[NSFileManager defaultManager] removeItemAtPath:temp error:nil];[[NSFileManager defaultManager] removeItemAtPath:Path([NSString stringWithFormat:@"media/%@.recovery.ts",uuid]) error:nil];if(error.localizedDescription.length){PVXPersistRecoveryResult(agent,uuid,dest,NO,error.localizedDescription);}}
static void PVXStartAVFoundationExport(id agent,NSString*uuid,NSString*ts,NSInteger attempt,NSString *previous){
 NSString *temp=Path([NSString stringWithFormat:@"media/%@.recovery.mp4",uuid]);[[NSFileManager defaultManager] removeItemAtPath:temp error:nil];AVURLAsset*asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:ts] options:nil];NSString*preset=attempt==0?AVAssetExportPresetPassthrough:AVAssetExportPresetHighestQuality;AVAssetExportSession*e=[[AVAssetExportSession alloc] initWithAsset:asset presetName:preset];if(!e){NSError*err=[NSError errorWithDomain:@"PVXRecovery" code:1 userInfo:@{NSLocalizedDescriptionKey:@"AVAssetExportSession unavailable"}];PVXFinishRecovery(agent,uuid,temp,NO,err);return;}e.outputURL=[NSURL fileURLWithPath:temp];e.outputFileType=AVFileTypeMPEG4;e.shouldOptimizeForNetworkUse=NO;RecoveryExports[uuid]=e;[e exportAsynchronouslyWithCompletionHandler:^{dispatch_async(dispatch_get_main_queue(),^{if(e.status==AVAssetExportSessionStatusCompleted){PVXFinishRecovery(agent,uuid,temp,YES,nil);return;}if(attempt==0){PVXStartAVFoundationExport(agent,uuid,ts,1,previous);return;}NSString *detail=e.error.localizedDescription?:@"MPEG-TS无法封装为MP4";if(previous.length)detail=[NSString stringWithFormat:@"%@；AVFoundation：%@",previous,detail];NSError*err=[NSError errorWithDomain:@"PVXRecovery" code:2 userInfo:@{NSLocalizedDescriptionKey:detail}];PVXFinishRecovery(agent,uuid,temp,NO,err);});}];
}
static void PVXStartRecoveryExport(id agent,NSDictionary *task,NSString*uuid,NSString*playlist,NSInteger attempt){(void)attempt;NSString *temp=Path([NSString stringWithFormat:@"media/%@.recovery.mp4",uuid]);RecoveryExports[uuid]=@YES;dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSError *ffError=nil;BOOL ok=PVXFFmpegRemux(playlist,temp,task,&ffError);NSString *detail=ffError.localizedDescription?:@"FFmpegKit remux failed";if(ok){dispatch_async(dispatch_get_main_queue(),^{PVXDiagnostic([NSString stringWithFormat:@"hls-%@-backend",uuid],@{@"backend":@"FFmpegKit",@"event":@"remux-success"});PVXFinishRecovery(agent,uuid,temp,YES,nil);});return;}NSString *fallback=Path([NSString stringWithFormat:@"media/%@.recovery.ts",uuid]);NSError *concatError=nil;BOOL concatenated=PVXConcatenateTS(uuid,fallback,&concatError);dispatch_async(dispatch_get_main_queue(),^{if(!concatenated){NSString *failure=[NSString stringWithFormat:@"FFmpegKit：%@；TS fallback：%@",detail,concatError.localizedDescription?:@"不可用"];PVXDiagnostic([NSString stringWithFormat:@"hls-%@-backend",uuid],@{@"backend":@"none",@"event":@"all-backends-failed",@"failure":failure});PVXFinishRecovery(agent,uuid,temp,NO,[NSError errorWithDomain:@"PVXRecovery" code:35 userInfo:@{NSLocalizedDescriptionKey:failure}]);return;}PVXDiagnostic([NSString stringWithFormat:@"hls-%@-backend",uuid],@{@"backend":@"AVFoundation",@"event":@"ts-fallback-built",@"path":fallback,@"ffmpegError":detail});PVXStartAVFoundationExport(agent,uuid,fallback,0,detail);});});}
static id PVXCurrentAgent(void){if(Worker)return Worker;Class app=NSClassFromString(@"UIApplication");SEL shared=NSSelectorFromString(@"sharedApplication");id application=app&&[app respondsToSelector:shared]?((id(*)(id,SEL))objc_msgSend)(app,shared):nil;id delegate=application&&[application respondsToSelector:@selector(delegate)]?((id(*)(id,SEL))objc_msgSend)(application,@selector(delegate)):nil;Class agentClass=NSClassFromString(@"PVAgent");if(delegate&&agentClass&&[delegate isKindOfClass:agentClass])Worker=delegate;return Worker;}
static void PVXRecoverFailedHLS(id agent,NSDictionary*task){NSString*uuid=task[@"id"];if(!ValidID(uuid)||[RecoveryAttempted containsObject:uuid])return;[RecoveryAttempted addObject:uuid];PVXDiagnostic([NSString stringWithFormat:@"hls-%@-start",uuid],@{@"event":@"recovery-started",@"state":task[@"state"]?:@"",@"segmentsDone":task[@"segmentsDone"]?:@0,@"segmentsTotal":task[@"segmentsTotal"]?:@0,@"error":task[@"error"]?:@""});dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSString *playlist=Path([NSString stringWithFormat:@"media/%@.recovery.m3u8",uuid]);NSError *playlistError=nil;if(!PVXBuildLocalHLSPlaylist(uuid,playlist,&playlistError)){dispatch_async(dispatch_get_main_queue(),^{NSMutableDictionary *t=[[[agent tasks] objectForKey:uuid] mutableCopy];if(t){PVXDiagnostic([NSString stringWithFormat:@"hls-%@-playlist",uuid],@{@"event":@"playlist-build-failed",@"error":playlistError.localizedDescription?:@""});t[@"state"]=@"failed";t[@"fileComplete"]=@NO;t[@"error"]=[NSString stringWithFormat:@"HLS 封装失败（清单重建）：%@",playlistError.localizedDescription?:@"无法重建本地清单"];if(Persist)Persist(agent,@selector(persist:),t);if(Notify)Notify(Signal);}});return;}PVXDiagnostic([NSString stringWithFormat:@"hls-%@-playlist",uuid],@{@"event":@"playlist-built",@"path":playlist,@"bytes":@([[[NSFileManager defaultManager]attributesOfItemAtPath:playlist error:nil][NSFileSize] longLongValue])});dispatch_async(dispatch_get_main_queue(),^{PVXStartRecoveryExport(agent,task,uuid,playlist,0);});});}
static void PVXScanFailedHLS(id agent){NSDictionary *tasks=[agent respondsToSelector:@selector(tasks)]?[agent tasks]:nil;if(![tasks isKindOfClass:NSDictionary.class])return;for(NSDictionary*t in tasks.allValues){if(![t isKindOfClass:NSDictionary.class]||![t[@"state"] isEqual:@"failed"]||![t[@"hlsSourceURL"] isKindOfClass:NSString.class])continue;long long done=[t[@"segmentsDone"] longLongValue],total=[t[@"segmentsTotal"] longLongValue];NSString *error=[t[@"error"] isKindOfClass:NSString.class]?t[@"error"]:@"";if(total>0&&done>=total&&([error length]||done==total))PVXRecoverFailedHLS(agent,t);}}
static void Tick(void){id agent=PVXCurrentAgent();if(!agent){PVXBootMark(@"agent-unavailable",@{});return;}if([agent respondsToSelector:@selector(exportReady)]&&[agent respondsToSelector:@selector(workerMode)]&&[agent workerMode])[agent exportReady];PVXScanFailedHLS(agent);}
static BOOL Start(id self, SEL cmd){Worker=self;BOOL result=OldStart?OldStart(self,cmd):NO;Worker=self;PVXBootMark(@"worker-started",@{@"result":@(result)});return result;}

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
    NSDictionary *task = ValidID(uuid) ? [self tasks][uuid] : nil;
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
    NSDictionary *task = ValidID(uuid) ? [self tasks][uuid] : nil;
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
    if (!wasClearing || [self clearingRequest] || [[self tasks] count]) return;
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

static BOOL PVXReplaceMethod(Class cls,SEL sel,IMP replacement,IMP *original){Method m=class_getInstanceMethod(cls,sel);if(!m)return NO;IMP old=method_getImplementation(m);if(original)*original=old;method_setImplementation(m,replacement);return YES;}
#ifndef PVX_STORAGE_MOCK
__attribute__((constructor))
static void Install(void) {
    @autoreleasepool {
        NSString *process=NSProcessInfo.processInfo.arguments.firstObject.lastPathComponent?:@"";
        PVXBootLog(@"constructor-enter");
        PVXBootMark(@"constructor",@{ @"process":process, @"pid":@(getpid()) });
        if (![process isEqualToString:@"PyVideoAgent"]) { PVXBootMark(@"process-rejected",@{ @"process":process }); return; }
        Class c=NSClassFromString(@"PVAgent");
        if(!c){PVXBootMark(@"agent-class-missing",@{});return;}
        RecoveryAttempted=[NSMutableSet set];RecoveryExports=[NSMutableDictionary dictionary];
        Persist=(void *)class_getMethodImplementation(c,@selector(persist:));
        Root=(void *)dlsym(RTLD_DEFAULT,"PVStateDirectory");
        Media=(void *)dlsym(RTLD_DEFAULT,"PVMediaPath");
        Write=(void *)dlsym(RTLD_DEFAULT,"PVWrite");
        Notify=(void *)dlsym(RTLD_DEFAULT,"PVNotify");
        PVXBootMark(@"symbols",@{ @"root":@(Root!=NULL), @"media":@(Media!=NULL), @"write":@(Write!=NULL), @"notify":@(Notify!=NULL) });
        if(!Root||!Media||!Notify){PVXBootLog(@"symbol-lookup-failed");PVXBootMark(@"symbol-lookup-failed",@{});return;}
        BOOL installed=YES;
        installed&=PVXReplaceMethod(c,@selector(pump),(IMP)PVXPumpWithConfiguredLimit,(IMP *)&OldPump);
        installed&=PVXReplaceMethod(NSFileManager.class,@selector(removeItemAtPath:error:),(IMP)Remove,(IMP *)&OldRemove);
        installed&=PVXReplaceMethod(c,NSSelectorFromString(@"finishExport:success:error:assetID:"),(IMP)Finish,(IMP *)&OldFinish);
        installed&=PVXReplaceMethod(c,NSSelectorFromString(@"finishDeletion:"),(IMP)Delete,(IMP *)&OldDelete);
        installed&=PVXReplaceMethod(c,NSSelectorFromString(@"finishClearAll"),(IMP)Clear,(IMP *)&OldClear);
        installed&=PVXReplaceMethod(c,@selector(startWorker),(IMP)Start,(IMP *)&OldStart);
        installed&=PVXReplaceMethod(c,@selector(exportReady),(IMP)Export,(IMP *)&OldExport);
        PVXBootMark(installed?@"method-replace-ok":@"method-replace-failed",@{ @"agent":NSStringFromClass(c)?:@"" });
        if(!installed){PVXBootLog(@"method-replace-failed");return;}
        if(!SafeDirectory(Root())){PVXBootMark(@"root-directory-failed",@{ @"root":Root()?:@"" });return;}
        PVXBootMark(@"installed",@{ @"root":Root()?:@"" });
        dispatch_async(dispatch_get_main_queue(),^{
            notify_register_dispatch(Signal.UTF8String,&NotificationToken,dispatch_get_main_queue(),^(int token){(void)token;Tick();});
            Timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
            dispatch_source_set_timer(Timer,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),2*NSEC_PER_SEC,NSEC_PER_SEC/2);
            dispatch_source_set_event_handler(Timer,^{@autoreleasepool{Tick();}});
            dispatch_resume(Timer);
            Tick();
        });
    }
}
#endif // !PVX_STORAGE_MOCK
#endif // !PVX_STORAGE_IO_TEST

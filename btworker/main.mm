// Independent Magnet/Torrent worker. Objective-C++/iOS 15+.
// The worker owns torrent-inbox/torrent-tasks and invokes the bundled aria2 BT engine.
#import <Foundation/Foundation.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <string.h>
#import <notify.h>
#import <AVFoundation/AVFoundation.h>
#include <dispatch/dispatch.h>
extern char **environ;

typedef NSString *(*PVXRootMapper)(NSString *);
static NSString *PVXMapped(NSString *canonical){
    PVXRootMapper map=(PVXRootMapper)dlsym(RTLD_DEFAULT,"_Z6jbrootP8NSString");
    if(!map){
        NSString *exe=NSProcessInfo.processInfo.arguments.firstObject;
        if(!exe.isAbsolutePath)exe=[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:exe?:@""];
        NSString *lib=[[exe stringByDeletingLastPathComponent] stringByAppendingPathComponent:@".jbroot/usr/lib/libroothide.dylib"];
        void *handle=dlopen(lib.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
        if(handle)map=(PVXRootMapper)dlsym(handle,"_Z6jbrootP8NSString");
    }
    NSString *mapped=map?map(canonical):nil;
    return [mapped isKindOfClass:NSString.class]&&mapped.isAbsolutePath?mapped:nil;
}
static NSString *PVXRoot(NSString *override){
    NSString *configured=override.length?override:NSProcessInfo.processInfo.environment[@"PVX_STATE_ROOT"];
    if(configured.length)return configured.isAbsolutePath?configured.stringByStandardizingPath:nil;
    return PVXMapped(@"/var/mobile/Library/Application Support/com.crctdd.pyvideo");
}
static BOOL PVXID(NSString *s){return s.length==36&&[[NSUUID alloc]initWithUUIDString:s]!=nil;}
static BOOL PVXWrite(NSString *path,NSDictionary *value){NSData *d=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];if(!d)return NO;NSString *tmp=[path stringByAppendingFormat:@".write-%@",NSUUID.UUID.UUIDString];if(![d writeToFile:tmp options:NSDataWritingAtomic error:nil])return NO;chmod(tmp.fileSystemRepresentation,0600);BOOL ok=rename(tmp.fileSystemRepresentation,path.fileSystemRepresentation)==0;if(!ok)unlink(tmp.fileSystemRepresentation);return ok;}
static NSDictionary *PVXRead(NSString *path){NSData *d=[NSData dataWithContentsOfFile:path options:0 error:nil];if(!d)return nil;return [NSPropertyListSerialization propertyListWithData:d options:NSPropertyListImmutable format:nil error:nil];}
static void PVXEnsure(NSString *p){[[NSFileManager defaultManager]createDirectoryAtPath:p withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];}
static NSString *PVXAria2(void){
    NSString *env=NSProcessInfo.processInfo.environment[@"PVX_ARIA2_PATH"];
    if(env.length&&[NSFileManager.defaultManager isExecutableFileAtPath:env])return env;
    NSString *exe=NSProcessInfo.processInfo.arguments.firstObject;
    if(!exe.isAbsolutePath)exe=[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:exe?:@""];
    NSString *sibling=[[exe stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"PyVideoAria2c"];
    if([NSFileManager.defaultManager isExecutableFileAtPath:sibling])return sibling;
    NSString *mapped=PVXMapped(@"/Applications/PyVideoAgent.app/PyVideoAria2c");
    return [NSFileManager.defaultManager isExecutableFileAtPath:mapped]?mapped:nil;
}
static int PVXRun(NSArray<NSString*> *args){if(!args.count)return -1;char **argv=(char **)calloc(args.count+1,sizeof(char*));if(!argv)return -ENOMEM;for(NSUInteger i=0;i<args.count;i++)argv[i]=(char *)[args[i] UTF8String];pid_t pid=0;int rc=posix_spawn(&pid,[args[0] fileSystemRepresentation],NULL,NULL,argv,environ);free(argv);if(rc)return -rc;int st=0;while(waitpid(pid,&st,0)<0&&errno==EINTR){}return WIFEXITED(st)?WEXITSTATUS(st):128+WTERMSIG(st);}
static NSString *PVXFindTorrent(NSString *dir){NSDirectoryEnumerator *en=[NSFileManager.defaultManager enumeratorAtPath:dir];for(NSString *n in en){if([n.pathExtension.lowercaseString isEqual:@"torrent"]){NSString *p=[dir stringByAppendingPathComponent:n];struct stat st;if(!lstat(p.fileSystemRepresentation,&st)&&S_ISREG(st.st_mode)&&st.st_size>0)return p;}}return nil;}
static BOOL PVXPlayable(NSString *path){AVURLAsset *asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];dispatch_semaphore_t gate=dispatch_semaphore_create(0);__block BOOL ok=NO;[asset loadValuesAsynchronouslyForKeys:@[@"tracks",@"playable"] completionHandler:^{ok=asset.playable&&[asset tracksWithMediaType:AVMediaTypeVideo].count>0;dispatch_semaphore_signal(gate);}];dispatch_semaphore_wait(gate,dispatch_time(DISPATCH_TIME_NOW,20LL*NSEC_PER_SEC));return ok;}
static NSString *PVXFindVideo(NSString *dir){NSString *best=nil;long long size=0;NSDirectoryEnumerator *en=[NSFileManager.defaultManager enumeratorAtPath:dir];for(NSString *n in en){if(![n.pathExtension.lowercaseString isEqual:@"mp4"])continue;NSString *p=[dir stringByAppendingPathComponent:n];struct stat st;if(!lstat(p.fileSystemRepresentation,&st)&&S_ISREG(st.st_mode)&&st.st_size>size){size=st.st_size;best=p;}}return best;}
static void PVXUpdateState(NSString *root,NSString *uuid,NSDictionary *patch){if(!PVXID(uuid))return;NSString *path=[root stringByAppendingPathComponent:[NSString stringWithFormat:@"torrent-tasks/%@.plist",uuid]];NSDictionary *old=PVXRead(path);if(!old)return;NSMutableDictionary *next=[old mutableCopy];[next addEntriesFromDictionary:patch];next[@"updated"]=@(NSDate.date.timeIntervalSince1970);PVXWrite(path,next);}
static void PVXConsumeControls(NSString *root){NSString *dir=[root stringByAppendingPathComponent:@"torrent-control"];for(NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]){if(![name.pathExtension.lowercaseString isEqual:@"plist"])continue;NSString *path=[dir stringByAppendingPathComponent:name];NSDictionary *cmd=PVXRead(path);NSString *target=cmd[@"target"],*action=cmd[@"action"];if(!PVXID(target)||![action isKindOfClass:NSString.class]){[[NSFileManager defaultManager]removeItemAtPath:path error:nil];continue;}if([action isEqual:@"delete"]){[[NSFileManager defaultManager]removeItemAtPath:[root stringByAppendingPathComponent:[NSString stringWithFormat:@"media/%@.mp4",target]] error:nil];[[NSFileManager defaultManager]removeItemAtPath:[root stringByAppendingPathComponent:[NSString stringWithFormat:@"torrent-cache/%@",target]] error:nil];[[NSFileManager defaultManager]removeItemAtPath:[root stringByAppendingPathComponent:[NSString stringWithFormat:@"torrent-inbox/%@.plist",target]] error:nil];PVXUpdateState(root,target,@{ @"state":@"deleted", @"phase":@"deleted", @"fileComplete":@NO });}else if([action isEqual:@"pause"]){PVXUpdateState(root,target,@{ @"state":@"paused", @"phase":@"paused" });}else if([action isEqual:@"resume"]||[action isEqual:@"retry"]){PVXUpdateState(root,target,@{ @"state":@"queued", @"phase":@"metadata", @"error":@"" });}[[NSFileManager defaultManager]removeItemAtPath:path error:nil];}}

static void PVXRunTask(NSDictionary *request,NSString *root){NSString *uuid=request[@"id"],*magnet=request[@"magnet"],*tasks=[root stringByAppendingPathComponent:@"torrent-tasks"],*cache=[root stringByAppendingPathComponent:[NSString stringWithFormat:@"torrent-cache/%@",uuid]],*outdir=[cache stringByAppendingPathComponent:@"output"],*statePath=[tasks stringByAppendingPathComponent:[uuid stringByAppendingString:@".plist"]];PVXEnsure(tasks);PVXEnsure(cache);PVXEnsure(outdir);NSMutableDictionary *state=[@{ @"id":uuid, @"kind":@"video", @"backend":@"torrent", @"sourceKind":@"magnet", @"magnet":magnet?:@"", @"infoHash":request[@"infoHash"]?:@"", @"page":request[@"page"]?:@"", @"title":request[@"title"]?:@"磁力任务", @"created":request[@"created"]?:@(NSDate.date.timeIntervalSince1970), @"updated":@(NSDate.date.timeIntervalSince1970), @"state":@"downloading", @"phase":@"metadata", @"received":@0, @"total":@(-1) } mutableCopy];if(!PVXWrite(statePath,state))return;
 NSString *aria=PVXAria2();if(!aria){state[@"state"]=@"failed";state[@"error"]=@"未安装BitTorrent引擎";PVXWrite(statePath,state);return;}
 NSString *session=[cache stringByAppendingPathComponent:@"aria2.session"];NSArray *run=@[aria,@"--bt-save-metadata=true",@"--bt-load-saved-metadata=true",@"--enable-dht=true",@"--enable-dht6=true",@"--enable-peer-exchange=true",@"--seed-time=0",@"--file-allocation=none",@"--continue=true",@"--auto-file-renaming=false",@"--allow-overwrite=true",@"--timeout=15",@"--connect-timeout=10",@"--bt-stop-timeout=600",@"--max-tries=3",@"--retry-wait=5",@"--console-log-level=warn",@"--summary-interval=0",[NSString stringWithFormat:@"--dir=%@",outdir],[NSString stringWithFormat:@"--save-session=%@",session],magnet?:@""];int rc=PVXRun(run);NSString *torrent=PVXFindTorrent(cache);if(torrent){state[@"torrentPath"]=torrent;state[@"metadataState"]=@"ready";}state[@"phase"]=@"pieces";if(rc!=0)state[@"engineExit"]=@(rc);PVXWrite(statePath,state);NSString *video=PVXFindVideo(outdir);if(!video){state[@"state"]=@"failed";state[@"error"]=rc!=0?[NSString stringWithFormat:@"BitTorrent下载未完成（aria2 exit %d）",rc]:@"Torrent内没有MP4文件";PVXWrite(statePath,state);return;}
if(!PVXPlayable(video)){state[@"state"]=@"failed";state[@"phase"]=@"validating";state[@"error"]=@"Torrent视频无法播放或不是完整MP4";PVXWrite(statePath,state);return;}
 NSString *media=[root stringByAppendingPathComponent:[NSString stringWithFormat:@"media/%@.mp4",uuid]];PVXEnsure(media.stringByDeletingLastPathComponent);[[NSFileManager defaultManager]removeItemAtPath:media error:nil];if(![[NSFileManager defaultManager]copyItemAtPath:video toPath:media error:nil]){state[@"state"]=@"failed";state[@"error"]=@"无法发布Torrent视频文件";PVXWrite(statePath,state);return;}struct stat st;lstat(media.fileSystemRepresentation,&st);state[@"received"]=@(st.st_size);state[@"total"]=@(st.st_size);state[@"extension"]=@"mp4";state[@"mime"]=@"video/mp4";state[@"state"]=@"ready";state[@"phase"]=@"complete";state[@"fileComplete"]=@YES;PVXWrite(statePath,state);notify_post("com.crctdd.pyvideo.queue");}
static void PVXScan(NSString *root){NSString *inbox=[root stringByAppendingPathComponent:@"torrent-inbox"],*tasks=[root stringByAppendingPathComponent:@"torrent-tasks"];PVXEnsure(inbox);PVXEnsure(tasks);PVXConsumeControls(root);for(NSString *n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:inbox error:nil]){if(![n.pathExtension isEqual:@"plist"])continue;NSString *uuid=n.stringByDeletingPathExtension;if(!PVXID(uuid))continue;NSString *taskPath=[tasks stringByAppendingPathComponent:n];NSDictionary *existing=[NSFileManager.defaultManager fileExistsAtPath:taskPath]?PVXRead(taskPath):nil;if(existing&&! [existing[@"state"] isEqual:@"queued"])continue;if(existing)[[NSFileManager defaultManager]removeItemAtPath:taskPath error:nil];NSDictionary *r=PVXRead([inbox stringByAppendingPathComponent:n]);if(![r[@"id"] isEqual:uuid]||![r[@"backend"] isEqual:@"torrent"]||![r[@"sourceKind"] isEqual:@"magnet"]||![r[@"magnet"] hasPrefix:@"magnet:?"])continue;PVXRunTask(r,root);}}
int main(int argc,char **argv){@autoreleasepool{BOOL worker=NO;NSString *override=nil;for(int i=1;i<argc;i++){if(!strcmp(argv[i],"--worker"))worker=YES;else if(!strcmp(argv[i],"--root")&&i+1<argc&&!override)override=[NSString stringWithUTF8String:argv[++i]];else{fprintf(stderr,"usage: PyVideoBTWorker --worker [--root /absolute/path]\n");return 64;}}if(!worker){fprintf(stderr,"PyVideoBTWorker: --worker required\n");return 64;}if(geteuid()==0&&!override)return 78;NSString *root=PVXRoot(override);if(!root.length){fprintf(stderr,"PyVideoBTWorker: root mapping failed\n");return 78;}PVXEnsure(root);for(NSString *d in @[@"torrent-inbox",@"torrent-tasks",@"torrent-cache",@"torrent-control",@"media"])PVXEnsure([root stringByAppendingPathComponent:d]);NSString *lockPath=[root stringByAppendingPathComponent:@".torrent-worker.lock"];int lock=open(lockPath.fileSystemRepresentation,O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0600);struct stat st;if(lock<0||fstat(lock,&st)||!S_ISREG(st.st_mode)||st.st_uid!=geteuid()||flock(lock,LOCK_EX|LOCK_NB)){if(lock>=0)close(lock);return 78;}fchmod(lock,0600);while(1){@autoreleasepool{PVXScan(root);}sleep(2);}close(lock);return 0;}}

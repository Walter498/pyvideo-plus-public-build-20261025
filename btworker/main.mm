// Single-owner Torrent worker. All engine paths are physical, never shell aliases.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <notify.h>
#include <dispatch/dispatch.h>
#include <mach-o/dyld.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/file.h>
#include <poll.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include "Metadata.hpp"
extern char **environ;
static volatile sig_atomic_t stopping=0;
static void PVXSignal(int sig){stopping=1;}
static NSString *PVXExecutable(){uint32_t n=0;_NSGetExecutablePath(nullptr,&n);char *p=(char *)calloc(n+1,1);if(!p)return nil;NSString *s=nil;if(!_NSGetExecutablePath(p,&n)){char resolved[PATH_MAX];if(realpath(p,resolved))s=@(resolved);}free(p);return s;}
typedef NSString *(*PVXRootMapper)(NSString *);
static NSString *PVXMapped(NSString *canonical){
    PVXRootMapper map=(PVXRootMapper)dlsym(RTLD_DEFAULT,"_Z6jbrootP8NSString");
    if(!map){NSString *lib=[[PVXExecutable() stringByDeletingLastPathComponent]stringByAppendingPathComponent:@".jbroot/usr/lib/libroothide.dylib"];void *h=dlopen(lib.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);if(h)map=(PVXRootMapper)dlsym(h,"_Z6jbrootP8NSString");}
    NSString *p=map?map(canonical):nil;return p.isAbsolutePath?p:nil;
}
static BOOL PVXID(id s){return [s isKindOfClass:NSString.class]&&[s length]==36&&[[NSUUID alloc]initWithUUIDString:s]!=nil;}
static NSString *PVXJoin(NSString *root,NSString *sub){return [root stringByAppendingPathComponent:sub];}
static BOOL PVXDir(NSString *p){struct stat st;if(lstat(p.fileSystemRepresentation,&st)==0)return S_ISDIR(st.st_mode)&&st.st_uid==geteuid()&&(st.st_mode&0022)==0;return errno==ENOENT && mkdir(p.fileSystemRepresentation,0700)==0;}
static BOOL PVXRegular(NSString *p,off_t *length){struct stat s;if(lstat(p.fileSystemRepresentation,&s)||!S_ISREG(s.st_mode)||s.st_nlink!=1||s.st_uid!=geteuid())return NO;if(length)*length=s.st_size;return YES;}
static BOOL PVXSyncDir(NSString *p){int fd=open(p.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return NO;BOOL ok=fsync(fd)==0;close(fd);return ok;}
static BOOL PVXWrite(NSString *path,NSDictionary *value){
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];if(!data)return NO;
    NSString *tmp=[path stringByAppendingString:@".new"];int fd=open(tmp.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0){unlink(tmp.fileSystemRepresentation);fd=open(tmp.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);}if(fd<0)return NO;
    NSUInteger done=0;while(done<data.length){ssize_t n=write(fd,(const char *)data.bytes+done,data.length-done);if(n<0&&errno==EINTR)continue;if(n<=0)break;done+=(NSUInteger)n;}
    BOOL ok=done==data.length&&fsync(fd)==0;close(fd);if(ok)ok=rename(tmp.fileSystemRepresentation,path.fileSystemRepresentation)==0;if(!ok)unlink(tmp.fileSystemRepresentation);return ok&&PVXSyncDir(path.stringByDeletingLastPathComponent);
}
static NSData *PVXData(NSString *path,NSUInteger cap){int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return nil;struct stat s;if(fstat(fd,&s)||!S_ISREG(s.st_mode)||s.st_nlink!=1||s.st_uid!=geteuid()||s.st_size<0||(unsigned long long)s.st_size>cap){close(fd);return nil;}NSMutableData *d=[NSMutableData dataWithLength:(NSUInteger)s.st_size];NSUInteger at=0;while(at<d.length){ssize_t n=read(fd,(char *)d.mutableBytes+at,d.length-at);if(n<0&&errno==EINTR)continue;if(n<=0)break;at+=(NSUInteger)n;}close(fd);return at==d.length?d:nil;}
static NSDictionary *PVXRead(NSString *path){NSData *d=PVXData(path,128*1024);id value=d?[NSPropertyListSerialization propertyListWithData:d options:NSPropertyListImmutable format:nil error:nil]:nil;return [value isKindOfClass:NSDictionary.class]?value:nil;}
static NSArray *PVXNames(NSString *dir){return [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(compare:)];}
static double PVXNow(){return NSProcessInfo.processInfo.systemUptime;}
static BOOL PVXTreeSafe(NSString *dir){
    if(!PVXDir(dir))return NO;NSDirectoryEnumerator *en=[NSFileManager.defaultManager enumeratorAtPath:dir];NSUInteger count=0;
    for(NSString *name in en){if(++count>30000)return NO;struct stat s;if(lstat(PVXJoin(dir,name).fileSystemRepresentation,&s)||s.st_uid!=geteuid()||(!S_ISDIR(s.st_mode)&&(!S_ISREG(s.st_mode)||s.st_nlink!=1)))return NO;}return YES;
}
// Supervisor survives worker crashes, owns the inherited flock, and reaps its engine.
// Only async-signal-safe C calls are used in forked children before exec.
struct PVXChild {pid_t pid=0;int life=-1,log=-1;};
static PVXChild PVXSpawn(NSArray<NSString *> *args,int lock){
    PVXChild result;char **av=(char **)calloc(args.count+1,sizeof(char *));if(!av)return result;for(NSUInteger i=0;i<args.count;i++)av[i]=(char *)[args[i] UTF8String];
    int life[2],logs[2];if(pipe(life)){free(av);return result;}if(pipe(logs)){close(life[0]);close(life[1]);free(av);return result;}
    pid_t supervisor=fork();
    if(supervisor==0){
        close(life[1]);fcntl(logs[0],F_SETFL,O_NONBLOCK);signal(SIGINT,PVXSignal);signal(SIGTERM,PVXSignal);signal(SIGPIPE,SIG_IGN);
        pid_t engine=fork();
        if(engine==0){close(logs[0]);setpgid(0,0);signal(SIGINT,SIG_DFL);signal(SIGTERM,SIG_DFL);signal(SIGPIPE,SIG_DFL);dup2(logs[1],STDOUT_FILENO);dup2(logs[1],STDERR_FILENO);int nullfd=open("/dev/null",O_RDONLY);if(nullfd>=0){dup2(nullfd,STDIN_FILENO);close(nullfd);}close(life[0]);close(logs[1]);close(lock);execve(av[0],av,environ);_exit(127);}
        close(logs[1]);if(engine<0)_exit(127);setpgid(engine,engine);int status=0,ticks=0;BOOL sent=NO;
        while(1){char discard[4096];for(unsigned i=0;i<16;i++)if(read(logs[0],discard,sizeof(discard))<=0)break;pid_t reaped=waitpid(engine,&status,WNOHANG);if(reaped==engine)break;if(reaped<0&&errno!=EINTR)_exit(127);
            struct pollfd p={life[0],POLLIN|POLLHUP,0};int rc=poll(sent?nullptr:&p,sent?0:1,100);
            if(sent||stopping||(rc>0&&(p.revents&(POLLIN|POLLHUP|POLLERR)))){if(!sent){if(kill(-engine,SIGINT)<0)kill(engine,SIGINT);sent=YES;}if(++ticks>=80&&kill(-engine,SIGKILL)<0)kill(engine,SIGKILL);}
        }close(life[0]);close(lock);_exit(WIFEXITED(status)?WEXITSTATUS(status):128+WTERMSIG(status));
    }
    free(av);close(life[0]);close(logs[1]);if(supervisor<0){close(life[1]);close(logs[0]);return result;}
    fcntl(life[1],F_SETFD,FD_CLOEXEC);fcntl(logs[0],F_SETFD,FD_CLOEXEC);fcntl(logs[0],F_SETFL,O_NONBLOCK);result.pid=supervisor;result.life=life[1];result.log=logs[0];return result;
}
#include <math.h>
#include "Runtime.hpp"
struct PVXWorker {
    NSString *root,*aria;int lock;
    NSString *active=nil,*token=nil,*stage=nil,*pending=nil;
    NSDictionary *metadata=nil;PVXChild child;
    double started=0,lastProgress=0,lastSave=0;long long received=0;NSMutableData *logBuffer=[NSMutableData data];
    NSString *task(NSString *id){return PVXJoin(root,[@"torrent-tasks/" stringByAppendingFormat:@"%@.plist",id]);}
    NSString *cache(NSString *id){return PVXJoin(root,[@"torrent-cache/" stringByAppendingString:id]);}
    NSString *output(NSString *id){return PVXJoin(cache(id),@"output");}
    NSString *media(NSString *id){return PVXJoin(root,[@"media/" stringByAppendingFormat:@"%@.mp4",id]);}
    NSDictionary *state(NSString *id){NSDictionary *s=PVXRead(task(id));return PVXState(s,id)?s:nil;}
    BOOL update(NSString *id,NSDictionary *patch){NSMutableDictionary *s=[state(id) mutableCopy];if(!s)return NO;[s addEntriesFromDictionary:patch];s[@"updated"]=@(NSDate.date.timeIntervalSince1970);return PVXWrite(task(id),s);}
    void fail(NSString *id,NSString *code){update(id,@{@"state":@"failed",@"phase":@"failed",@"error":code,@"fileComplete":@NO});}
    void clean(NSString *id){[NSFileManager.defaultManager removeItemAtPath:cache(id) error:nil];unlink(media(id).fileSystemRepresentation);unlink([media(id) stringByAppendingString:@".publishing"].fileSystemRepresentation);unlink(PVXJoin(root,[@"torrent-inbox/" stringByAppendingFormat:@"%@.plist",id]).fileSystemRepresentation);PVXSyncDir(PVXJoin(root,@"media"));PVXSyncDir(PVXJoin(root,@"torrent-cache"));if(!PVXExists(cache(id))&&!PVXExists(media(id))&&[state(id)[@"state"] isEqual:@"deleting"])update(id,@{@"state":@"deleted",@"phase":@"deleted"});}
    void stop(NSString *reason){pending=reason;if(child.life>=0){close(child.life);child.life=-1;}if(child.pid>0)kill(child.pid,SIGINT);}
    void controls(){
        NSString *dir=PVXJoin(root,@"torrent-control");
        for(NSString *name in PVXNames(dir)){
            if([name hasPrefix:@"."]||![name.pathExtension isEqual:@"plist"]||!PVXID(name.stringByDeletingPathExtension))continue;NSString *path=PVXJoin(dir,name);NSDictionary *c=PVXRead(path);NSString *id=c[@"target"],*action=c[@"action"];
            if(PVXID(c[@"id"])&&[name.stringByDeletingPathExtension isEqual:c[@"id"]]&&(c.count==3||(c.count==4&&[c[@"created"] isKindOfClass:NSNumber.class]&&isfinite([c[@"created"] doubleValue])))&&PVXID(id)&&[action isKindOfClass:NSString.class]){
                NSDictionary *s=state(id);BOOL deleted=[s[@"state"] isEqual:@"deleting"]||[s[@"state"] isEqual:@"deleted"]||[s[@"state"] isEqual:@"cancelled"];BOOL running=[active isEqual:id];
                if([action isEqual:@"delete"]){
                    NSDictionary *dead=@{@"id":id,@"kind":@"video",@"backend":@"torrent",@"state":@"deleting",@"phase":@"deleting",@"fileComplete":@NO,@"token":NSUUID.UUID.UUIDString,@"updated":@(NSDate.date.timeIntervalSince1970)};
                    if(!PVXWrite(task(id),dead))continue;
                    if(running&&child.pid)stop(@"delete");else clean(id);
                }else if(s&&!deleted&&([action isEqual:@"pause"]||[action isEqual:@"resume"]||[action isEqual:@"retry"])){
                    if([s[@"state"] isEqual:@"ready"]&&![action isEqual:@"retry"]){unlink(path.fileSystemRepresentation);continue;}
                    BOOL pause=[action isEqual:@"pause"];NSString *next=pause?(running&&child.pid?@"pausing":@"paused"):@"queued";
                    if(!update(id,@{@"state":next,@"phase":next,@"token":NSUUID.UUID.UUIDString,@"error":@"",@"fileComplete":@NO}))continue;
                    if(running&&child.pid)stop(pause?@"pause":@"restart");
                }
            }
            unlink(path.fileSystemRepresentation);
        }
    }
    BOOL current(){NSDictionary *s=state(active);return !pending && [s[@"token"] isEqual:token]&&[s[@"state"] isEqual:@"downloading"]&&!stopping;}
    void ingest(){
        NSString *inbox=PVXJoin(root,@"torrent-inbox");for(NSString *name in PVXNames(inbox)){
            NSString *id=name.stringByDeletingPathExtension;if(![name.pathExtension isEqual:@"plist"]||!PVXID(id))continue;
            NSString *path=PVXJoin(inbox,name);if(PVXExists(task(id))){unlink(path.fileSystemRepresentation);continue;}
            NSDictionary *r=PVXRead(path);NSString *magnet=r[@"magnet"];
            if(!PVXRequest(r,id)){unlink(path.fileSystemRepresentation);continue;}
            if(!PVXDir(cache(id))||!PVXDir(output(id)))continue;
            NSString *title=[r[@"title"] isKindOfClass:NSString.class]?r[@"title"]:@"磁力任务";if(title.length>512)title=[title substringToIndex:512];
            NSDictionary *s=@{@"id":id,@"kind":@"video",@"backend":@"torrent",@"sourceKind":@"magnet",@"title":title,@"infoHash":PVXMagnetHash(magnet),@"sourceKey":r[@"sourceKey"]?:[@"btih:" stringByAppendingString:PVXMagnetHash(magnet)],@"created":[r[@"created"] isKindOfClass:NSNumber.class]?r[@"created"]:@(NSDate.date.timeIntervalSince1970),@"updated":@(NSDate.date.timeIntervalSince1970),@"state":@"queued",@"phase":@"queued",@"received":@0,@"total":@(-1),@"fileComplete":@NO,@"token":NSUUID.UUID.UUIDString};
            // Private request is durable before public queue admission. Never expose URLs in status.
            if(PVXWrite(PVXJoin(cache(id),@"request.plist"),r)&&PVXWrite(task(id),s))unlink(path.fileSystemRepresentation);
        }
    }
    NSDictionary *loadMetadata(NSString *id){NSString *hash=state(id)[@"infoHash"];if(![hash isKindOfClass:NSString.class])return nil;return PVXMetadata(PVXData(PVXJoin(output(id),[hash stringByAppendingString:@".torrent"]),16*1024*1024),hash);}
    NSArray *arguments(NSString *id,BOOL meta){
        BOOL local=[NSProcessInfo.processInfo.environment[@"PVX_BT_TEST_LOCAL"] isEqual:@"1"];
        NSMutableArray *a=[NSMutableArray arrayWithArray:@[aria,[NSString stringWithFormat:@"--stop-with-process=%d",getpid()],@"--no-conf=true",@"--enable-color=false",@"--human-readable=false",@"--show-console-readout=true",@"--summary-interval=1",@"--console-log-level=notice",@"--download-result=hide",@"--enable-rpc=false",@"--seed-time=0",@"--seed-ratio=0.0",@"--file-allocation=none",@"--continue=true",@"--auto-file-renaming=false",@"--allow-overwrite=false",@"--check-integrity=true",@"--max-concurrent-downloads=1",@"--bt-max-peers=40",@"--max-overall-download-limit=16M",@"--max-overall-upload-limit=256K",@"--max-connection-per-server=2",@"--connect-timeout=15",@"--timeout=30",@"--max-tries=3",@"--retry-wait=5",@"--bt-stop-timeout=180",@"--auto-save-interval=5",@"--disk-cache=8M",@"--enable-dht6=false",@"--enable-peer-exchange=true",@"--bt-enable-lpd=false",@"--follow-torrent=false",@"--bt-remove-unselected-file=false",[NSString stringWithFormat:@"--enable-dht=%@",local?@"false":@"true"],[NSString stringWithFormat:@"--dht-file-path=%@",PVXJoin(cache(id),@"dht.dat")],[NSString stringWithFormat:@"--dht-file-path6=%@",PVXJoin(cache(id),@"dht6.dat")],[NSString stringWithFormat:@"--dir=%@",output(id)]]];
        if(meta){[a addObjectsFromArray:@[@"--bt-metadata-only=true",@"--bt-save-metadata=true",@"--bt-load-saved-metadata=false",PVXRead(PVXJoin(cache(id),@"request.plist"))[@"magnet"]?:@""]];}
        else [a addObjectsFromArray:@[[NSString stringWithFormat:@"--select-file=%@",metadata[@"index"]],@"--bt-metadata-only=false",PVXJoin(output(id),[state(id)[@"infoHash"] stringByAppendingString:@".torrent"])]];
        return a;
    }
    BOOL freeSpace(unsigned long long needed){struct statvfs fs;if(statvfs(root.fileSystemRepresentation,&fs))return NO;return (unsigned long long)fs.f_bavail*fs.f_frsize>needed+128ULL*1024*1024;}
    void launch(BOOL meta){
        stage=meta?@"metadata":@"pieces";received=meta?0:[state(active)[@"received"] longLongValue];[logBuffer setLength:0];started=lastProgress=lastSave=PVXNow();
        if(!PVXTreeSafe(cache(active))){fail(active,@"unsafe_cache");active=nil;return;}
        // Selected boundary pieces may allocate neighbour files; reserve the whole capped torrent.
        unsigned long long need=meta?16*1024*1024:[metadata[@"storage"] unsignedLongLongValue]+[metadata[@"length"] unsignedLongLongValue];
        if(!freeSpace(need)){fail(active,@"insufficient_space");active=nil;return;}
        if(!update(active,@{@"state":@"downloading",@"phase":stage,@"received":@(received),@"total":meta?@(-1):metadata[@"length"],@"fileComplete":@NO,@"error":@""})){active=nil;return;}
        if(!meta&&!update(active,@{@"selectedFile":metadata[@"path"],@"selectedFileName":[metadata[@"path"] lastPathComponent],@"metadataState":@"ready",@"metadataProgress":@1})){active=nil;return;}
        setenv("HOME",cache(active).fileSystemRepresentation,1);
        setenv("XDG_CACHE_HOME",cache(active).fileSystemRepresentation,1);
        child=PVXSpawn(arguments(active,meta),lock);if(!child.pid){fail(active,@"engine_start_failed");active=nil;}
    }
    AVURLAsset *asset=nil;NSMutableDictionary *validation=nil;
    void clear(){active=nil;token=nil;pending=nil;stage=nil;metadata=nil;asset=nil;validation=nil;}
    void recover(){
        for(NSString *name in PVXNames(PVXJoin(root,@"torrent-tasks"))){
            NSString *id=name.stringByDeletingPathExtension;if(![name.pathExtension isEqual:@"plist"]||!PVXID(id))continue;
            NSDictionary *s=state(id);if(!s){fprintf(stderr,"torrent-worker: corrupt state %s retained\n",name.UTF8String);continue;}
            NSString *status=s[@"state"];
            if([status isEqual:@"deleting"]||[status isEqual:@"deleted"]||[status isEqual:@"cancelled"]){clean(id);continue;}
            if([status isEqual:@"pausing"])update(id,@{@"state":@"paused",@"phase":@"paused"});
            if([status isEqual:@"downloading"])update(id,@{@"state":@"queued",@"phase":@"recovery",@"token":NSUUID.UUID.UUIDString,@"fileComplete":@NO});
            // Paused and failed remain untouched. A previously published ready is never inferred from bytes.
            if([status isEqual:@"ready"]){off_t n=0;if(!PVXRegular(media(id),&n)||n!=[s[@"total"] longLongValue])fail(id,@"published_file_missing");}
        }
    }
    void choose(){
        if(active||stopping)return;
        for(NSString *name in PVXNames(PVXJoin(root,@"torrent-tasks"))){
            NSString *id=name.stringByDeletingPathExtension;if(![name.pathExtension isEqual:@"plist"]||!PVXID(id))continue;
            NSDictionary *s=state(id);if(![s[@"state"] isEqual:@"queued"])continue;
            if(!PVXTreeSafe(cache(id))||!PVXDir(output(id))){fail(id,@"unsafe_cache");continue;}
            NSDictionary *r=PVXRead(PVXJoin(cache(id),@"request.plist"));if(!PVXRequest(r,id)||![PVXMagnetHash(r[@"magnet"]) isEqual:s[@"infoHash"]]){fail(id,@"invalid_private_request");continue;}
            active=id;token=s[@"token"];pending=nil;metadata=loadMetadata(id);
            NSString *metaPath=PVXJoin(output(id),[s[@"infoHash"] stringByAppendingString:@".torrent"]);
            if(!metadata&&PVXExists(metaPath)){fail(id,@"invalid_metadata");clear();continue;}
            launch(metadata==nil);return;
        }
    }
    void drain(){
        if(child.log<0)return;char b[4096];
        // Drain with a bounded budget so noisy engines cannot starve control handling.
        for(unsigned i=0;i<32;i++){ssize_t n=read(child.log,b,sizeof(b));if(n<=0)break;}
    }
    void progress(){
        if(!current()||![stage isEqual:@"pieces"])return;
        NSString *sidecar=PVXJoin(output(active),[metadata[@"name"] stringByAppendingString:@".aria2"]);
        NSDictionary *v=PVXVerified(PVXData(sidecar,16*1024*1024),metadata,state(active)[@"infoHash"]);
        if(v){long long n=[v[@"received"] longLongValue];if(n!=received){received=n;lastProgress=PVXNow();}update(active,v);}
    }
    BOOL noSidecars(){
        if(!PVXTreeSafe(output(active)))return NO;
        NSString *expected=[metadata[@"name"] stringByAppendingString:@".aria2"];
        for(NSString *name in [NSFileManager.defaultManager enumeratorAtPath:output(active)]){
            if(![name.pathExtension isEqual:@"aria2"])continue;
            if(![name isEqual:expected])return NO;
            // aria2 retains its control file after a selective multi-file
            // download. Only verified coverage of the selected file is final.
            NSDictionary *v=PVXVerified(PVXData(PVXJoin(output(active),name),16*1024*1024),metadata,state(active)[@"infoHash"]);
            if(!v||[v[@"received"] longLongValue]!=[metadata[@"length"] longLongValue]||![v[@"piecesDone"] isEqual:v[@"piecesTotal"]])return NO;
        }
        return YES;
    }
    void validate(){
        NSString *path=PVXJoin(output(active),metadata[@"path"]);off_t n=0;
        if(!noSidecars()||!PVXRegular(path,&n)||n!=[metadata[@"length"] longLongValue]){fail(active,@"incomplete_output");clear();return;}
        stage=@"validating";started=PVXNow();update(active,@{@"phase":stage});
        asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
        validation=[NSMutableDictionary dictionary];NSMutableDictionary *box=validation;AVURLAsset *a=asset;
        [a loadValuesAsynchronouslyForKeys:@[@"playable",@"tracks",@"duration"] completionHandler:^{@autoreleasepool{
            BOOL ok=YES;for(NSString *key in @[@"playable",@"tracks",@"duration"])if([a statusOfValueForKey:key error:nil]!=AVKeyValueStatusLoaded)ok=NO;
            double width=0,height=0,duration=0;
            if(ok){AVAssetTrack *track=[a tracksWithMediaType:AVMediaTypeVideo].firstObject;CGRect rect=CGRectApplyAffineTransform((CGRect){CGPointZero,track.naturalSize},track.preferredTransform);width=fabs(rect.size.width);height=fabs(rect.size.height);duration=CMTimeGetSeconds(a.duration);ok=a.playable&&track&&isfinite(width)&&isfinite(height)&&width>0&&height>0&&width<=32768&&height<=32768&&isfinite(duration)&&duration>0;}
            @synchronized(box){box[@"result"]=@{@"ok":@(ok),@"width":@(width),@"height":@(height),@"duration":@(duration)};}
        }}];
    }
    void publish(NSDictionary *v){
        // Same-volume rename avoids a large blocking copy. Sync bytes before exposing the final path.
        NSString *src=PVXJoin(output(active),metadata[@"path"]);off_t size=0;
        if(!current()){if(stopping&&[state(active)[@"state"] isEqual:@"downloading"])update(active,@{@"state":@"queued",@"phase":@"recovery",@"fileComplete":@NO});clear();return;}
        if(!noSidecars()||!PVXRegular(src,&size)||size!=[metadata[@"length"] longLongValue]){fail(active,@"publication_precondition");clear();return;}
        int fd=open(src.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);BOOL ok=fd>=0&&fsync(fd)==0;if(fd>=0)close(fd);
        if(stopping){update(active,@{@"state":@"queued",@"phase":@"recovery",@"fileComplete":@NO});clear();return;}
        // Commit boundary: a graceful shutdown arriving after this point lets
        // the verified rename + durable ready record finish before exiting.
        if(ok)ok=rename(src.fileSystemRepresentation,media(active).fileSystemRepresentation)==0;
        if(ok)ok=PVXSyncDir(src.stringByDeletingLastPathComponent)&&PVXSyncDir(PVXJoin(root,@"media"));
        if(ok){unsigned long long pl=[metadata[@"pieceLength"] unsignedLongLongValue],off=[metadata[@"offset"] unsignedLongLongValue],len=[metadata[@"length"] unsignedLongLongValue];NSNumber *pieces=@((off+len+pl-1)/pl-off/pl);
            ok=update(active,@{@"state":@"ready",@"phase":@"ready",@"fileComplete":@YES,@"received":@(size),@"total":@(size),@"sizeBytes":@(size),@"width":v[@"width"],@"height":v[@"height"],@"duration":v[@"duration"],@"progress":@1,@"piecesDone":pieces,@"piecesTotal":pieces,@"metadataProgress":@1,@"metadataState":@"ready",@"extension":@"mp4",@"uti":@"public.mpeg-4",@"error":@""});}
        if(!ok)fail(active,@"publication_failed");else notify_post("com.crctdd.pyvideo.changed");clear();
    }
    void tick(){
        if(!active)return;
        if(stopping&&!pending)stop(@"shutdown");
        if(child.pid){
            drain();double now=PVXNow();if(now-lastSave>=1){progress();lastSave=now;}
            BOOL local=[NSProcessInfo.processInfo.environment[@"PVX_BT_TEST_LOCAL"] isEqual:@"1"];
            double limit=[stage isEqual:@"metadata"]?(local?90:180):(local?300:86400);
            if(!pending&&(now-started>limit||now-lastProgress>(local?90:300)))stop(@"timeout");
            if(!pending&&now-lastSave<0.05&&!freeSpace(0))stop(@"disk_full");
            int status=0;pid_t p=waitpid(child.pid,&status,WNOHANG);if(!p||(p<0&&errno==EINTR))return;
            if(child.life>=0)close(child.life);drain();if(child.log>=0)close(child.log);child=PVXChild();
            if(pending){NSString *reason=pending;if([state(active)[@"state"] isEqual:@"pausing"])update(active,@{@"state":@"paused",@"phase":@"paused"});if([reason isEqual:@"delete"])clean(active);else if([reason isEqual:@"shutdown"]){if([state(active)[@"state"] isEqual:@"downloading"])update(active,@{@"state":@"queued",@"phase":@"recovery",@"fileComplete":@NO});}else if([reason isEqual:@"timeout"]||[reason isEqual:@"disk_full"])fail(active,reason);clear();return;}
            if(!current()){clear();return;}
            if(p<0||!WIFEXITED(status)||WEXITSTATUS(status)!=0){fail(active,@"engine_failed");clear();return;}
            if([stage isEqual:@"metadata"]){metadata=loadMetadata(active);if(!metadata){fail(active,@"invalid_metadata");clear();return;}launch(NO);}else validate();
        }else if([stage isEqual:@"validating"]){
            if(pending||!current()){[asset cancelLoading];if([pending isEqual:@"delete"])clean(active);else if(stopping&&[state(active)[@"state"] isEqual:@"downloading"])update(active,@{@"state":@"queued",@"phase":@"recovery"});clear();return;}
            NSDictionary *v=nil;@synchronized(validation){v=validation[@"result"];}
            if(v){if([v[@"ok"] boolValue])publish(v);else{fail(active,@"unplayable_video");clear();}}
            else if(PVXNow()-started>30){[asset cancelLoading];fail(active,@"validation_timeout");clear();}
        }
    }
};

int main(int argc,char **argv){@autoreleasepool{
    NSString *override=nil;for(int i=1;i<argc;i++){if(!strcmp(argv[i],"--worker"))continue;if(!strcmp(argv[i],"--root")&&i+1<argc)override=@(argv[++i]);else{fprintf(stderr,"usage: PyVideoTorrentWorker [--root PHYSICAL_PATH]\n");return 64;}}
    NSString *configured=override?:NSProcessInfo.processInfo.environment[@"PVX_STATE_ROOT"];
    NSString *root=configured.length?configured:PVXMapped(@"/var/mobile/Library/Application Support/com.crctdd.pyvideo");
    if(!root.isAbsolutePath||!PVXDir(root)){fprintf(stderr,"torrent-worker: private physical root required\n");return 73;}
    char resolved[PATH_MAX];if(!realpath(root.fileSystemRepresentation,resolved))return 73;root=@(resolved);
    for(NSString *sub in @[@"torrent-inbox",@"torrent-tasks",@"torrent-control",@"torrent-cache",@"media"])if(!PVXDir(PVXJoin(root,sub)))return 73;
    NSString *aria=NSProcessInfo.processInfo.environment[@"PVX_ARIA2_PATH"];
    if(!aria.length){aria=PVXJoin(PVXExecutable().stringByDeletingLastPathComponent,@"PyVideoAria2c");if(access(aria.fileSystemRepresentation,X_OK))aria=PVXMapped(@"/Applications/PyVideoAgent.app/PyVideoAria2c");}
    struct stat executableStat;BOOL executableSafe=aria.isAbsolutePath&&lstat(aria.fileSystemRepresentation,&executableStat)==0&&S_ISREG(executableStat.st_mode)&&(executableStat.st_uid==0||executableStat.st_uid==geteuid())&&(executableStat.st_mode&0022)==0;
    if(!executableSafe||access(aria.fileSystemRepresentation,X_OK)){fprintf(stderr,"torrent-worker: physical aria2 executable unavailable\n");return 69;}
    NSString *lockPath=PVXJoin(root,@".torrent-worker.lock");int lock=open(lockPath.fileSystemRepresentation,O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0600);struct stat ls;
    if(lock<0)return 73;if(fstat(lock,&ls)||!S_ISREG(ls.st_mode)||ls.st_nlink!=1||ls.st_uid!=geteuid()){close(lock);return 73;}
    BOOL owned=NO;for(unsigned attempt=0;attempt<110;attempt++){if(flock(lock,LOCK_EX|LOCK_NB)==0){owned=YES;break;}if(errno!=EWOULDBLOCK&&errno!=EAGAIN)break;poll(nullptr,0,100);}if(!owned){close(lock);return 75;}
    signal(SIGINT,PVXSignal);signal(SIGTERM,PVXSignal);signal(SIGPIPE,SIG_IGN);
    PVXWorker worker;worker.root=root;worker.aria=aria;worker.lock=lock;worker.recover();
    while(!stopping||worker.active){@autoreleasepool{worker.controls();if(!stopping)worker.ingest();worker.tick();if(!stopping)worker.choose();}poll(nullptr,0,100);}
    close(lock);return 0;
}}

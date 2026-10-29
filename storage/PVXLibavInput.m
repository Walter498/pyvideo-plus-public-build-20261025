#import "PVXLibavInput.h"
#import <sys/stat.h>
#import <unistd.h>
#import <limits.h>
#import <string.h>
#import <fcntl.h>
#import <errno.h>
#import <stdlib.h>

static id PVXInputFail(NSError **error,NSString *reason);
static BOOL PVXRepairRepeatedAudioPESFile(NSString *source,NSString *destination,BOOL *changed,NSError **error);

@interface PVXFileProtocolInput : NSObject
@property(nonatomic,copy) NSString *root;
@property(nonatomic,copy) NSString *token;
@property(nonatomic,strong) NSMutableDictionary *names;
@property(nonatomic,strong) NSMutableSet *active;
@property(nonatomic,strong) NSMutableArray *created;
@property(nonatomic,strong) NSMutableArray *resourceReport;
- (NSString *)map:(NSURL *)url key:(BOOL)key depth:(NSUInteger)depth error:(NSError **)error;
@end
static NSDictionary *PVXLastInputReport;
static uint64_t PVXLastAudioDTS;
NSDictionary *PVXLibavInputLastReport(void) { @synchronized([NSObject class]) { return [PVXLastInputReport copy]; } }
static id PVXInputFail(NSError **error,NSString *reason) {
    if(error)*error=[NSError errorWithDomain:@"PVXLibavInput" code:1 userInfo:@{NSLocalizedDescriptionKey:reason}];
    return nil;
}

static NSUInteger PVXPTS(const unsigned char *p) {
    return (((NSUInteger)((p[0]>>1)&7))<<30)|((NSUInteger)p[1]<<22)|
        (((NSUInteger)((p[2]>>1)&0x7f))<<15)|((NSUInteger)p[3]<<7)|
        ((NSUInteger)((p[4]>>1)&0x7f));
}

// The original arm64e Agent rejects non-increasing DTS. Some VOD TS sources
// repeat one AAC PES at a segment start. Repair only that exact local input
// defect in the private alias tree; never mutate the cached source file and
// never weaken the Agent's muxer validation.
static NSUInteger PVXPTS(const unsigned char *p);
static BOOL PVXRepairRepeatedAudioPESInner(NSString *source,NSString *destination,BOOL *changed,NSError **error) {
    // Keep headers local: this repair's implementation is intentionally isolated.
    #include <stdio.h>
    #include <stdlib.h>
    #include <errno.h>
    #include <fcntl.h>
    if(changed)*changed=NO;
    if(error)*error=nil;
    const char *sourcePath=source.fileSystemRepresentation;
    const char *destinationPath=destination.fileSystemRepresentation;
    FILE *in=fopen(sourcePath,"rb"),*out=NULL;
    unsigned char *input=NULL,*output=NULL;
    const size_t capacity=188*8192; // 1.47 MiB per buffer, no per-packet objects.
    NSString *failure=nil;
    int systemError=0;
    BOOL created=NO,changedAny=NO,applicable=NO,ok=YES;
    unsigned int audio=0xffff;
    __block BOOL inPES=NO,curHasPTS=NO,headerPending=NO;
    BOOL droppingPES=NO;
    __block uint64_t prevLast=0,curPTS=0,lastAudioDTS=PVXLastAudioDTS;
    __block NSUInteger prevFrames=0,curFrames=0,curRate=0,accLen=0;
    __block unsigned char acc[8192];
    void (^endPES)(void)=^{
        if(!inPES)return;
        // An absent PTS is unknown, not timestamp zero. Never publish an
        // inferred zero-based DTS or use it as a duplicate comparison anchor.
        if(curHasPTS){
            if(curFrames&&curRate){uint64_t step=(uint64_t)1024*90000/curRate;prevLast=curPTS+(uint64_t)(curFrames-1)*step;prevFrames=curFrames;}
            else {prevLast=curPTS;prevFrames=0;}
            lastAudioDTS=prevLast;
        }
        inPES=NO;accLen=0;
    };
    if(!in){failure=@"Cannot open TS repair source";systemError=errno;ok=NO;}
    if(ok){
        // Explicit large stdio buffers also cover the occasional short read.
        setvbuf(in,NULL,_IOFBF,capacity);
        input=malloc(capacity);output=malloc(capacity);
        if(!input||!output){failure=@"Cannot allocate TS repair buffers";systemError=ENOMEM;ok=NO;}
    }
    while(ok){
        size_t length=fread(input,1,capacity,in);
        if(ferror(in)){failure=@"Cannot read TS repair source";systemError=errno;ok=NO;break;}
        if(!length)break;
        if(!applicable){
            if(input[0]!=0x47){
                // Non-TS media is a supported no-op, not a failed TS scan.
                if([source.pathExtension.lowercaseString isEqualToString:@"ts"]){failure=@"Invalid TS sync byte";ok=NO;}
                break;
            }
            applicable=YES;
            // Exclusive creation prevents truncating the source, including an
            // existing hard-link alias. Only delete files we actually created.
            int fd=open(destinationPath,O_WRONLY|O_CREAT|O_EXCL,0600);
            if(fd<0){failure=@"Cannot create private TS repair output";systemError=errno;ok=NO;break;}
            created=YES;
            out=fdopen(fd,"wb");
            if(!out){systemError=errno;close(fd);failure=@"Cannot open TS repair output stream";ok=NO;break;}
            setvbuf(out,NULL,_IOFBF,capacity);
        }
        if(length%188){failure=@"Truncated TS packet during repair scan";ok=NO;break;}
        size_t outputLength=0;
        for(size_t offset=0;offset<length;offset+=188){
            const unsigned char *q=input+offset;
            if(q[0]!=0x47){failure=@"Invalid TS sync byte during repair scan";ok=NO;break;}
            unsigned int pid=((q[1]&31)<<8)|q[2],afc=(q[3]>>4)&3;
            BOOL payload=afc==1||afc==3,start=(q[1]&64)!=0;
            NSUInteger off=4;
            if(afc==3){if(q[4]>183){failure=@"Invalid TS adaptation field during repair scan";ok=NO;break;}off+=1+q[4];}
            if(afc==0||afc==2||off==188)payload=NO;
            if(payload&&start&&audio==0xffff&&off+4<=188&&q[off]==0&&q[off+1]==0&&q[off+2]==1&&q[off+3]>=0xc0&&q[off+3]<=0xdf)audio=pid;
            if(payload&&pid==audio&&start){
                endPES();droppingPES=NO;
                BOOL pesHeader=off+9<=188&&q[off]==0&&q[off+1]==0&&q[off+2]==1&&q[off+3]>=0xc0&&q[off+3]<=0xdf&&(q[off+6]&0xc0)==0x80;
                unsigned int ptsFlags=pesHeader?(q[off+7]>>6):0;
                BOOL hasPTS=pesHeader&&(ptsFlags==2||ptsFlags==3)&&q[off+8]>=5&&off+14<=188;
                if(hasPTS){const unsigned char *p=q+off+9;hasPTS=(p[0]>>4)==ptsFlags&&(p[0]&1)&&(p[2]&1)&&(p[4]&1);}
                uint64_t pts=hasPTS?PVXPTS(q+off+9):0;
                BOOL dup=hasPTS&&((prevFrames>0)?(pts<=prevLast+960):(lastAudioDTS>0&&pts<=lastAudioDTS+960));
                if(dup){changedAny=YES;droppingPES=YES;}
                else {curPTS=pts;curHasPTS=hasPTS;curFrames=0;curRate=0;inPES=YES;accLen=0;headerPending=YES;}
            }
            // A duplicate includes ALL following packets on this PID, not just
            // its start packet. Other PIDs (video/PSI/etc.) remain byte-exact.
            if(pid==audio&&droppingPES)continue;
            if(payload&&pid==audio&&inPES){
                NSUInteger n=188-off;const unsigned char *b=q+off;
                if(accLen+n<=sizeof(acc)){memcpy(acc+accLen,b,n);accLen+=n;}
                if(headerPending&&accLen>=9){NSUInteger h=9+acc[8];if(h<=accLen){memmove(acc,acc+h,accLen-h);accLen-=h;headerPending=NO;}}
                NSUInteger pos=0;
                while(!headerPending&&accLen-pos>=7){const unsigned char *f=acc+pos;if(f[0]!=0xff||(f[1]&0xf6)!=0xf0)break;NSUInteger idx=(f[2]>>2)&15;static const NSUInteger rates[]={96000,88200,64000,48000,44100,32000,24000,22050,16000,12000,11025,8000,7350};if(idx>=13)break;NSUInteger fl=(((NSUInteger)f[3]&3)<<11)|((NSUInteger)f[4]<<3)|((f[5]>>5)&7);if(fl<7||pos+fl>accLen)break;if(!curFrames)curRate=rates[idx];curFrames++;pos+=fl;}
                if(pos){memmove(acc,acc+pos,accLen-pos);accLen-=pos;}
            }
            memcpy(output+outputLength,q,188);outputLength+=188;
        }
        if(ok&&outputLength&&fwrite(output,1,outputLength,out)!=outputLength){failure=@"Cannot write TS repair output";systemError=errno;ok=NO;}
    }
    if(ok&&applicable)endPES();
    if(in&&fclose(in)!=0&&ok){failure=@"Cannot close TS repair source";systemError=errno;ok=NO;}
    if(out&&fclose(out)!=0&&ok){failure=@"Cannot flush or close TS repair output";systemError=errno;ok=NO;}
    free(input);free(output);
    if(ok&&applicable)PVXLastAudioDTS=lastAudioDTS; // Commit only a complete scan.
    if(!ok||!changedAny){
        if(created)unlink(destinationPath);
        if(!ok&&error){
            NSMutableDictionary *info=[@{NSLocalizedDescriptionKey:failure?:@"TS repair scan failed"} mutableCopy];
            if(systemError)info[NSUnderlyingErrorKey]=[NSError errorWithDomain:NSPOSIXErrorDomain code:systemError userInfo:nil];
            *error=[NSError errorWithDomain:@"PVXLibavInput" code:2 userInfo:info];
        }
        // NO + nil error: unchanged/not applicable. NO + error: fatal; callers
        // MUST propagate it, never move/link the unscanned original as fallback.
        return NO;
    }
    if(changed)*changed=YES;
    return YES;
}
static BOOL PVXRepairRepeatedAudioPESFile(NSString *source,NSString *destination,BOOL *changed,NSError **error) {
    // One pool per file, never one pool (or NSData allocation) per TS packet.
    @autoreleasepool {
        return PVXRepairRepeatedAudioPESInner(source,destination,changed,error);
    }
}

@implementation PVXFileProtocolInput
- (NSString *)map:(NSURL *)url key:(BOOL)key depth:(NSUInteger)depth error:(NSError **)error {
    char real[PATH_MAX];struct stat st;
    if(depth>12||!url.isFileURL||!realpath(url.fileSystemRepresentation,real)||
       lstat(url.fileSystemRepresentation,&st)||!S_ISREG(st.st_mode)||st.st_size<=0)
        return PVXInputFail(error,@"Native input requires existing nonsymlink local files");
    NSString *path=[NSString stringWithUTF8String:real];
    if(![path hasPrefix:[self.root stringByAppendingString:@"/"]])
        return PVXInputFail(error,@"Native input resource escapes task cache");
    NSString *cursor=url.path.stringByStandardizingPath;
    while(cursor.length>self.root.length){struct stat ancestor;
        if(lstat(cursor.fileSystemRepresentation,&ancestor)||S_ISLNK(ancestor.st_mode))
            return PVXInputFail(error,@"Symlink in native input path");
        cursor=cursor.stringByDeletingLastPathComponent;
    }
    NSString *identity=[path stringByAppendingString:key?@":key":@":media"];
    if([self.active containsObject:path])return PVXInputFail(error,@"Cyclic native playlist");
    if(self.names[identity])return self.names[identity];
    BOOL playlist=[path.pathExtension.lowercaseString isEqual:@"m3u8"];
    NSFileHandle *reader=[NSFileHandle fileHandleForReadingAtPath:path];
    NSData *prefix=[reader readDataOfLength:16];[reader closeFile];
    const unsigned char *bytes=prefix.bytes;
    NSString *ext=key?@"key":@"ts";
    if(playlist)ext=@"m3u8";
    else if(!key&&prefix.length>=8&&(!memcmp(bytes+4,"ftyp",4)||!memcmp(bytes+4,"moov",4)))ext=@"mp4";
    else if(!key&&prefix.length>=8&&(!memcmp(bytes+4,"styp",4)||!memcmp(bytes+4,"moof",4)))ext=@"m4s";
    else if(!key&&[@[@"mp4",@"m4s",@"aac",@"ac3"] containsObject:path.pathExtension.lowercaseString])ext=path.pathExtension.lowercaseString;
    NSString *leaf=[NSString stringWithFormat:@"pvx-input-%@-%lu.%@",self.token,(unsigned long)self.names.count,ext];
    self.names[identity]=leaf;
    NSString *destination=[self.root stringByAppendingPathComponent:leaf];
    if(!playlist){
        if(key&&st.st_size!=16)return PVXInputFail(error,@"Native AES key must be exactly 16 bytes");
        BOOL repaired=NO;NSError *repairError=nil;
        NSDictionary *side=[NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingString:@".plist"]]?:@{};
        NSMutableDictionary *entry=[@{@"file":path.lastPathComponent?:@"",@"bytes":@(st.st_size),
            @"declaredSize":side[@"size"]?:@0,@"declaredSHA256":side[@"sha256"]?:@"",@"key":@(key)} mutableCopy];
        if(!key&&PVXRepairRepeatedAudioPESFile(path,destination,&repaired,&repairError)){
            entry[@"repaired"]=@YES;entry[@"output"]=destination.lastPathComponent?:@"";
            [self.resourceReport addObject:entry];[self.created addObject:destination];return leaf;
        }
        if(repairError){if(error)*error=repairError;return nil;}
        if(repaired)return PVXInputFail(error, @"Cannot publish repaired private TS input");
        entry[@"repaired"]=@NO;[self.resourceReport addObject:entry];
        unlink(destination.fileSystemRepresentation);
        if(link(path.fileSystemRepresentation,destination.fileSystemRepresentation))
            return PVXInputFail(error,@"Cannot hard-link private native input resource");
        [self.created addObject:destination];return leaf;
    }
    if(st.st_size>2*1024*1024)return PVXInputFail(error,@"Native playlist exceeds 2 MiB");
    [self.active addObject:path];
    NSString *text=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:error];
    if(!text)return nil;
    NSMutableArray *lines=[NSMutableArray array];
    NSRegularExpression *pattern=[NSRegularExpression regularExpressionWithPattern:@"URI=\"([^\"]+)\"" options:0 error:NULL];
    for(NSString *line in [text componentsSeparatedByString:@"\n"]){
        if(!line.length){[lines addObject:line];continue;}
        if(![line hasPrefix:@"#"]){
            NSURL *child=[NSURL URLWithString:line relativeToURL:url].absoluteURL;
            NSString *mapped=[self map:child key:NO depth:depth+1 error:error];
            if(!mapped)return nil;
            [lines addObject:mapped];continue;
        }
        NSMutableString *rewritten=[line mutableCopy];
        NSArray *matches=[pattern matchesInString:line options:0 range:NSMakeRange(0,line.length)];
        for(NSTextCheckingResult *match in matches.reverseObjectEnumerator){
            NSRange value=[match rangeAtIndex:1];NSURL *child=[NSURL URLWithString:[line substringWithRange:value] relativeToURL:url].absoluteURL;
            NSString *mapped=[self map:child key:[line hasPrefix:@"#EXT-X-KEY:"] depth:depth+1 error:error];
            if(!mapped)return nil;[rewritten replaceCharactersInRange:value withString:mapped];
        }
        [lines addObject:rewritten];
    }
    NSString *result=[lines componentsJoinedByString:@"\n"];
    if(![result writeToFile:destination atomically:YES encoding:NSUTF8StringEncoding error:error])return nil;
    chmod(destination.fileSystemRepresentation,0600);[self.created addObject:destination];
    [self.active removeObject:path];return leaf;
}
@end
NSURL *PVXLibavInput(NSURL *closedPlaylist,NSError **error) {
    if(error)*error=nil;char root[PATH_MAX];
    if(!closedPlaylist.isFileURL||!realpath(closedPlaylist.path.stringByDeletingLastPathComponent.fileSystemRepresentation,root))
        return PVXInputFail(error,@"Native input cache missing");
    PVXFileProtocolInput *job=[PVXFileProtocolInput new];
    job.root=[NSString stringWithUTF8String:root];job.token=NSUUID.UUID.UUIDString;
    for(NSString *old in [[NSFileManager defaultManager]contentsOfDirectoryAtPath:job.root error:NULL])if([old hasPrefix:@"pvx-input-"])unlink([job.root stringByAppendingPathComponent:old].fileSystemRepresentation);
    job.names=[NSMutableDictionary dictionary];job.active=[NSMutableSet set];job.created=[NSMutableArray array];job.resourceReport=[NSMutableArray array];
    NSString *leaf=[job map:closedPlaylist key:NO depth:0 error:error];
    NSDictionary *report=@{@"resourceCount":@(job.resourceReport.count),@"repairedCount":@([[job.resourceReport filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"repaired == YES"]] count]),@"resources":job.resourceReport,@"nativePlaylist":leaf?:@"",@"root":job.root?:@""};
    @synchronized([NSObject class]) { PVXLastAudioDTS=0;PVXLastInputReport=report; }
    if(!leaf){for(NSString *path in job.created)unlink(path.fileSystemRepresentation);return nil;}
    return [NSURL fileURLWithPath:[job.root stringByAppendingPathComponent:leaf]];
}

NSURL *PVXLibavInputContinuousTS(NSURL *playlist,BOOL (^cancelled)(void),void (^progress)(NSUInteger,NSUInteger,unsigned long long),NSError **error) {
    if(error)*error=nil;
    if(!playlist.isFileURL)return PVXInputFail(error,@"Continuous TS requires local input");
    NSString *leaf=playlist.lastPathComponent;
    NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:@"^pvx-input-([A-Fa-f0-9-]{36})-[0-9]+\\.m3u8$" options:0 error:NULL];
    NSTextCheckingResult *match=[re firstMatchInString:leaf options:0 range:NSMakeRange(0,leaf.length)];
    if(!match)return PVXInputFail(error,@"Continuous TS requires nonce-owned native playlist");
    NSString *token=[leaf substringWithRange:[match rangeAtIndex:1]],*root=playlist.path.stringByDeletingLastPathComponent;
    NSString *text=[NSString stringWithContentsOfURL:playlist encoding:NSUTF8StringEncoding error:error];if(!text)return nil;
    NSMutableArray *paths=[NSMutableArray array];unsigned long long expected=0;BOOL ended=NO,pending=NO;
    for(NSString *raw in [text componentsSeparatedByString:@"\n"]){
        NSString *line=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(!line.length)continue;
        if(ended)return PVXInputFail(error,@"Trailing content after ENDLIST");
        if([line isEqual:@"#EXT-X-ENDLIST"]){ended=YES;continue;}
        if([line hasPrefix:@"#EXTINF:"]){if(pending)return PVXInputFail(error,@"Missing TS after EXTINF");pending=YES;continue;}
        if([line hasPrefix:@"#"]){
            if([line containsString:@"URI="]||[line hasPrefix:@"#EXT-X-KEY"]||[line hasPrefix:@"#EXT-X-MAP"]||[line hasPrefix:@"#EXT-X-BYTERANGE"]||[line hasPrefix:@"#EXT-X-DISCONTINUITY"]||[line hasPrefix:@"#EXT-X-GAP"]||[line hasPrefix:@"#EXT-X-STREAM-INF"]||[line hasPrefix:@"#EXT-X-I-FRAMES-ONLY"])
                return PVXInputFail(error,@"Continuous TS not applicable to keys/maps/ranges/discontinuities/master");
            continue;
        }
        if(!pending||![line isEqual:line.lastPathComponent]||![line hasPrefix:[NSString stringWithFormat:@"pvx-input-%@-",token]]||![line.pathExtension isEqual:@"ts"])
            return PVXInputFail(error,@"Continuous TS resource must be a nonce-owned relative TS leaf");
        pending=NO;NSString *path=[root stringByAppendingPathComponent:line];struct stat st;
        if(lstat(path.fileSystemRepresentation,&st)||!S_ISREG(st.st_mode)||st.st_size<=0||st.st_size%188)
            return PVXInputFail(error,@"Continuous TS requires complete 188-byte packets");
        expected+=(unsigned long long)st.st_size;[paths addObject:path];
    }
    if(!ended||pending||!paths.count)return PVXInputFail(error,@"Continuous TS requires complete finite playlist");
    NSDictionary *space=[[NSFileManager defaultManager]attributesOfFileSystemForPath:root error:error];
    if(!space)return nil;
    if([space[NSFileSystemFreeSize] unsignedLongLongValue]<expected+64*1024*1024)
        return PVXInputFail(error,@"Insufficient storage for private continuous TS staging");
    NSString *output=[root stringByAppendingPathComponent:[NSString stringWithFormat:@"pvx-input-%@-continuous.ts",token]];
    int fd=open(output.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if(fd<0)return PVXInputFail(error,@"Cannot exclusively create continuous TS staging");
    const size_t capacity=188*4096;unsigned char *buffer=malloc(capacity);BOOL ok=buffer!=NULL;unsigned long long bytes=0;NSUInteger done=0;
    if(progress)progress(0,paths.count,0);
    for(NSString *path in paths){
        if(!ok)break;
        int in=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);if(in<0){ok=NO;break;}
        struct stat before,after;off_t consumed=0;
        if(fstat(in,&before)||!S_ISREG(before.st_mode)){close(in);ok=NO;break;}
        for(;;){
            if(cancelled&&cancelled()){ok=NO;break;}
            ssize_t n=read(in,buffer,capacity);if(n<0&&errno==EINTR)continue;if(n<0){ok=NO;break;}if(!n)break;
            if(n%188){ok=NO;break;}
            for(ssize_t k=0;k<n;k+=188)if(buffer[k]!=0x47){ok=NO;break;}
            if(!ok)break;
            ssize_t pos=0;while(pos<n){ssize_t w=write(fd,buffer+pos,(size_t)(n-pos));if(w<0&&errno==EINTR)continue;if(w<=0){ok=NO;break;}pos+=w;}
            if(!ok)break;consumed+=n;bytes+=(unsigned long long)n;
        }
        if(fstat(in,&after)||consumed!=before.st_size||before.st_size!=after.st_size||before.st_mtime!=after.st_mtime)ok=NO;
        close(in);if(!ok)break;done++;if(progress)progress(done,paths.count,bytes);
    }
    if(buffer)free(buffer);
    if(ok&&fsync(fd))ok=NO;if(close(fd))ok=NO;
    if(!ok||bytes!=expected){unlink(output.fileSystemRepresentation);return PVXInputFail(error,(cancelled&&cancelled())?@"Continuous TS cancelled":@"Continuous TS copy failed or resource changed");}
    return [NSURL fileURLWithPath:output];
}

void PVXLibavInputCleanup(NSURL *nativePlaylist) {
    if(!nativePlaylist.isFileURL)return;
    NSString *leaf=nativePlaylist.lastPathComponent;
    NSRegularExpression *pattern=[NSRegularExpression regularExpressionWithPattern:@"^pvx-input-([A-Fa-f0-9-]{36})-[0-9]+\\.m3u8$" options:0 error:NULL];
    NSTextCheckingResult *match=[pattern firstMatchInString:leaf options:0 range:NSMakeRange(0,leaf.length)];
    if(!match)return;
    NSString *token=[leaf substringWithRange:[match rangeAtIndex:1]];
    if(![[NSUUID alloc]initWithUUIDString:token])return;
    NSString *prefix=[NSString stringWithFormat:@"pvx-input-%@-",token];
    NSString *root=nativePlaylist.path.stringByDeletingLastPathComponent;
    for(NSString *name in [[NSFileManager defaultManager]contentsOfDirectoryAtPath:root error:NULL]) {
        if([name hasPrefix:prefix])unlink([root stringByAppendingPathComponent:name].fileSystemRepresentation);
    }
}

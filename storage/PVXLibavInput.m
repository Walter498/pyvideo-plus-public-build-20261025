#import "PVXLibavInput.h"
#import <sys/stat.h>
#import <unistd.h>
#import <limits.h>
#import <string.h>

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
static BOOL PVXADTS(const unsigned char *p,NSUInteger available,NSUInteger *length,NSUInteger *rate) {
    if(available<7||p[0]!=0xff||(p[1]&0xf6)!=0xf0)return NO;
    static const NSUInteger rates[]={96000,88200,64000,48000,44100,32000,24000,22050,16000,12000,11025,8000,7350};
    NSUInteger index=(p[2]>>2)&15;if(index>=sizeof(rates)/sizeof(rates[0])||!rates[index])return NO;
    NSUInteger n=(((NSUInteger)p[3]&3)<<11)|((NSUInteger)p[4]<<3)|((p[5]>>5)&7);
    NSUInteger header=(p[1]&1)?7:9;if(n<header||n>available)return NO;
    if(length)*length=n;if(rate)*rate=rates[index];return YES;
}
static BOOL PVXRepairRepeatedAudioPESInner(NSString *source,NSString *destination,BOOL *changed,NSError **error) {
    (void)error;if(changed)*changed=NO;
    NSData *input=[NSData dataWithContentsOfFile:source options:0 error:error];
    if(!input.length||input.length%188)return NO;
    NSMutableData *output=[input mutableCopy];const unsigned char *bytes=input.bytes;NSUInteger packetCount=input.length/188;
    unsigned int audioPID=0xffff;__block NSMutableData *pes=[NSMutableData data];__block NSMutableData *map=[NSMutableData data];NSMutableArray *records=[NSMutableArray array];
    void (^flush)(void)=^{if(pes.length)[records addObject:[@{ @"data":[pes mutableCopy],@"map":[map mutableCopy] } mutableCopy]];pes=[NSMutableData data];map=[NSMutableData data];};
    for(NSUInteger n=0;n<packetCount;n++){
        const unsigned char *p=bytes+n*188;if(p[0]!=0x47){flush();return NO;}
        unsigned int pid=((p[1]&31)<<8)|p[2];unsigned int afc=(p[3]>>4)&3;BOOL payload=afc==1||afc==3;BOOL start=(p[1]&64)!=0;NSUInteger off=4;
        if(afc==3){if(p[4]>183){flush();return NO;}off+=1+p[4];}if(afc==0||afc==2)payload=NO;
        if(payload&&start&&off+4<=188&&p[off]==0&&p[off+1]==0&&p[off+2]==1&&p[off+3]>=0xc0&&p[off+3]<=0xdf&&audioPID==0xffff)audioPID=pid;
        if(pid!=audioPID||!payload)continue;
        if(start){flush();}
        NSUInteger length=188-off;[pes appendBytes:p+off length:length];
        for(NSUInteger i=0;i<length;i++){uint32_t at=(uint32_t)(n*188+off+i);[map appendBytes:&at length:sizeof(at)];}
    }
    flush();if(audioPID==0xffff||records.count<2)return NO;
    uint64_t previousLast=0;BOOL havePrevious=NO;NSUInteger repaired=0;
    for(NSMutableDictionary *record in records){
        NSMutableData *d=record[@"data"];const unsigned char *b=d.bytes;if(d.length<14||b[0]!=0||b[1]!=0||b[2]!=1)continue;
        NSUInteger header=9+b[8];NSUInteger declared=((NSUInteger)b[4]<<8)|b[5];NSUInteger end=declared?MIN(d.length,6+declared):d.length;
        if(header>=end)continue;NSUInteger pos=header,count=0,frameLen=0,rate=0;uint64_t first=0;
        while(pos+7<=end){NSUInteger nlen=0,nrate=0;if(!PVXADTS(b+pos,end-pos,&nlen,&nrate))break;if(!count)frameLen=nlen,rate=nrate;count++;pos+=nlen;}
        if(!count||!rate)continue;first=(b[7]&0x80)?PVXPTS(b+9):0;uint64_t step=(uint64_t)1024*90000/rate;uint64_t last=first+(uint64_t)(count-1)*step;
        if(havePrevious&&first<=previousLast&&count>1){
            unsigned char *m=d.mutableBytes;memmove(m+header,m+header+frameLen,end-header-frameLen);memset(m+end-frameLen,0xff,frameLen);
            unsigned char flags=m[7];
            if(flags&0x80){uint64_t t=PVXPTS(m+9)+step;m[9]=(unsigned char)(0x20|(((t>>30)&7)<<1)|1);m[10]=(t>>22)&0xff;m[11]=(unsigned char)((((t>>15)&0x7f)<<1)|1);m[12]=(t>>7)&0xff;m[13]=(unsigned char)(((t&0x7f)<<1)|1);}
            if((flags&0xc0)==0xc0){uint64_t t=PVXPTS(m+14)+step;m[14]=(unsigned char)(0x10|(((t>>30)&7)<<1)|1);m[15]=(t>>22)&0xff;m[16]=(unsigned char)((((t>>15)&0x7f)<<1)|1);m[17]=(t>>7)&0xff;m[18]=(unsigned char)(((t&0x7f)<<1)|1);}
            if(declared>=frameLen){NSUInteger newLen=declared-frameLen;m[4]=(newLen>>8)&255;m[5]=newLen&255;}
            record[@"repaired"]=[@YES copy];repaired++;count--;last=first+(uint64_t)(count-1)*step;
        }
        previousLast=last;havePrevious=YES;
    }
    if(!repaired)return NO;
    for(NSMutableDictionary *record in records){if(![record[@"repaired"] boolValue])continue;NSMutableData *d=record[@"data"],*locations=record[@"map"];const uint32_t *loc=locations.bytes;const unsigned char *val=d.bytes;for(NSUInteger i=0;i<MIN(d.length,locations.length/sizeof(uint32_t));i++)[(NSMutableData*)output replaceBytesInRange:NSMakeRange(loc[i],1) withBytes:val+i];}
    if(![output writeToFile:destination options:NSDataWritingAtomic error:error])return NO;
    chmod(destination.fileSystemRepresentation,0600);if(changed)*changed=YES;return YES;
}
static BOOL PVXRepairRepeatedAudioPESFile(NSString *source,NSString *destination,BOOL *changed,NSError **error) {
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
        BOOL repaired=NO;
        NSDictionary *side=[NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingString:@".plist"]]?:@{};
        NSMutableDictionary *entry=[@{@"file":path.lastPathComponent?:@"",@"bytes":@(st.st_size),
            @"declaredSize":side[@"size"]?:@0,@"declaredSHA256":side[@"sha256"]?:@"",@"key":@(key)} mutableCopy];
        if(!key&&PVXRepairRepeatedAudioPESFile(path,destination,&repaired,error)){
            entry[@"repaired"]=@YES;entry[@"output"]=destination.lastPathComponent?:@"";
            [self.resourceReport addObject:entry];[self.created addObject:destination];return leaf;
        }
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
            if(!mapped)return nil;[lines addObject:mapped];continue;
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
    job.names=[NSMutableDictionary dictionary];job.active=[NSMutableSet set];job.created=[NSMutableArray array];job.resourceReport=[NSMutableArray array];
    NSString *leaf=[job map:closedPlaylist key:NO depth:0 error:error];
    NSDictionary *report=@{@"resourceCount":@(job.resourceReport.count),@"repairedCount":@([[job.resourceReport filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"repaired == YES"]] count]),@"resources":job.resourceReport,@"nativePlaylist":leaf?:@"",@"root":job.root?:@""};
    @synchronized([NSObject class]) { PVXLastInputReport=report; }
    if(!leaf){for(NSString *path in job.created)unlink(path.fileSystemRepresentation);return nil;}
    return [NSURL fileURLWithPath:[job.root stringByAppendingPathComponent:leaf]];
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

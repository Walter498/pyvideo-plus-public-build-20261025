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
- (NSString *)map:(NSURL *)url key:(BOOL)key depth:(NSUInteger)depth error:(NSError **)error;
@end
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
static NSData *PVXRepairRepeatedAudioPES(NSData *input, BOOL *changed, NSError **error) {
    if (changed) *changed=NO;
    if (!input.length || input.length%188 || ((const unsigned char *)input.bytes)[0]!=0x47) return nil;
    const unsigned char *bytes=input.bytes; NSUInteger packets=input.length/188;
    typedef struct { uint64_t previousPTS; BOOL havePTS,drop; } State;
    State state[8192]; memset(state,0,sizeof(state));
    NSMutableData *output=[NSMutableData dataWithCapacity:input.length];
    for(NSUInteger n=0;n<packets;n++) {
        const unsigned char *packet=bytes+n*188;
        if(packet[0]!=0x47)return nil;
        unsigned int pid=((packet[1]&0x1f)<<8)|packet[2];
        unsigned int adaptation=(packet[3]>>4)&3; BOOL payload=adaptation==1||adaptation==3; BOOL start=(packet[1]&0x40)!=0; NSUInteger offset=4;
        if(adaptation==3) { if(packet[4]>183)return nil; offset+=1+packet[4]; }
        if(adaptation==0||adaptation==2)payload=NO;
        if(start)state[pid].drop=NO;
        if(payload&&start&&offset+14<=188&&packet[offset]==0&&packet[offset+1]==0&&packet[offset+2]==1) {
            unsigned char stream=packet[offset+3];
            if(stream>=0xc0&&stream<=0xdf) {
                unsigned char flags=packet[offset+7];
                if(((flags>>6)&2)&&offset+14<=188) {
                    uint64_t pts=PVXPTS(packet+offset+9);
                    if(state[pid].havePTS&&pts<=state[pid].previousPTS) { state[pid].drop=YES;if(changed)*changed=YES; }
                    else { state[pid].previousPTS=pts;state[pid].havePTS=YES; }
                }
            }
        }
        if(state[pid].drop)continue;
        [output appendBytes:packet length:188];
    }
    if(changed&&!*changed)return nil;
    return output;
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
        NSData *source=[NSData dataWithContentsOfFile:path options:0 error:error];
        BOOL repaired=NO;NSData *fixed=(!key&&source)?PVXRepairRepeatedAudioPES(source,&repaired,error):nil;
        if(repaired) {
            if(![fixed writeToFile:destination options:NSDataWritingAtomic error:error])return nil;
            chmod(destination.fileSystemRepresentation,0600);[self.created addObject:destination];return leaf;
        }
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
    job.names=[NSMutableDictionary dictionary];job.active=[NSMutableSet set];job.created=[NSMutableArray array];
    NSString *leaf=[job map:closedPlaylist key:NO depth:0 error:error];
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

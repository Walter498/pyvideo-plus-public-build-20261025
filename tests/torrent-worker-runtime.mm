// Host Foundation tests; production worker is included to exercise the exact helpers.
#define main PVXTorrentWorkerMain
#include "../btworker/main.mm"
#undef main
#include <assert.h>
static NSData *enc(id value){
    NSMutableData *d=[NSMutableData data];
    if([value isKindOfClass:NSString.class])value=[value dataUsingEncoding:NSUTF8StringEncoding];
    if([value isKindOfClass:NSData.class]){[d appendData:[[NSString stringWithFormat:@"%lu:",(unsigned long)[value length]] dataUsingEncoding:NSUTF8StringEncoding]];[d appendData:value];}
    else if([value isKindOfClass:NSNumber.class])[d appendData:[[NSString stringWithFormat:@"i%@e",value] dataUsingEncoding:NSUTF8StringEncoding]];
    else if([value isKindOfClass:NSArray.class]){[d appendBytes:"l" length:1];for(id v in value)[d appendData:enc(v)];[d appendBytes:"e" length:1];}
    else{[d appendBytes:"d" length:1];for(NSString *k in [[value allKeys] sortedArrayUsingSelector:@selector(compare:)]){[d appendData:enc(k)];[d appendData:enc(value[k])];}[d appendBytes:"e" length:1];}
    return d;
}
static NSString *sha(NSData *d){unsigned char digest[20];CC_SHA1(d.bytes,(CC_LONG)d.length,digest);NSMutableString *s=[NSMutableString string];for(unsigned i=0;i<20;i++)[s appendFormat:@"%02x",digest[i]];return s;}
static NSDictionary *meta(NSDictionary *info){return PVXMetadata(enc(@{@"info":info}),sha(enc(info)));}
static void put(NSMutableData *d,NSUInteger at,uint64_t n,unsigned bytes){unsigned char *b=(unsigned char *)d.mutableBytes;for(unsigned i=0;i<bytes;i++){b[at+bytes-1-i]=n&255;n>>=8;}}
int main(){@autoreleasepool{
    NSMutableDictionary *info=[@{@"name":@"movie.mp4",@"length":@8,@"piece length":@4,@"pieces":[NSMutableData dataWithLength:40]} mutableCopy];
    NSDictionary *m=meta(info);assert(m&&[m[@"length"] intValue]==8&&[m[@"index"] intValue]==1);
    NSString *h=sha(enc(info));assert(!PVXMetadata(enc(@{@"info":info}),@"0000000000000000000000000000000000000000"));
    assert([PVXMagnetHash([@"magnet:?xt=urn:btih:" stringByAppendingString:h]) isEqual:h]);
    assert(!PVXMagnetHash(@"magnet:?xt=urn:btih:invalid"));
    assert(!PVXComponent([@"../evil.mp4" dataUsingEncoding:NSUTF8StringEncoding]));
    info[@"name.utf-8"]=@"other.mp4";assert(!meta(info));[info removeObjectForKey:@"name.utf-8"];
    info[@"attr"]=@"l";assert(!meta(info));[info removeObjectForKey:@"attr"];
    info[@"name"]=@"..";assert(!meta(info));info[@"name"]=@"movie.mp4";
    info[@"length"]=@(LLONG_MAX);assert(!meta(info));info[@"length"]=@8;
    NSMutableData *bits=[NSMutableData dataWithLength:59];put(bits,0,1,2);put(bits,2,1,4);put(bits,6,20,4);
    unsigned char digest[20];NSData *encoded=enc(info);CC_SHA1(encoded.bytes,(CC_LONG)encoded.length,digest);memcpy((char *)bits.mutableBytes+10,digest,20);
    put(bits,30,4,4);put(bits,34,8,8);put(bits,50,1,4);put(bits,54,128,1);
    NSDictionary *p=PVXVerified(bits,m,h);assert([p[@"received"] intValue]==4&&[p[@"piecesDone"] intValue]==1);
    put(bits,54,192,1);assert([PVXVerified(bits,m,h)[@"received"] intValue]==8);
    put(bits,50,0xffffffff,4);assert(!PVXVerified(bits,m,h));
    NSDictionary *multi=@{@"name":@"bundle",@"files":@[@{@"length":@3,@"path":@[@"extra.bin"]},@{@"length":@5,@"path":@[@"small.mp4"]},@{@"length":@8,@"path":@[@"large.mp4"]}],@"piece length":@4,@"pieces":[NSMutableData dataWithLength:80]};
    NSDictionary *selected=meta(multi);assert([selected[@"index"] intValue]==3&&[selected[@"offset"] intValue]==8&&[selected[@"path"] isEqual:@"bundle/large.mp4"]);
    NSString *id=NSUUID.UUID.UUIDString;NSDictionary *r=@{@"id":id,@"kind":@"video",@"backend":@"torrent",@"sourceKind":@"magnet",@"magnet":[@"magnet:?xt=urn:btih:" stringByAppendingString:h],@"infoHash":h};assert(PVXRequest(r,id));assert(!PVXRequest(r,NSUUID.UUID.UUIDString));
    NSMutableDictionary *caseRequest=[r mutableCopy];caseRequest[@"magnet"]=[@"MAGNET:?XT=urn%3Abtih%3A" stringByAppendingString:h];caseRequest[@"page"]=[@"https://example.test/" stringByPaddingToLength:12000 withString:@"a" startingAtIndex:0];assert(PVXRequest(caseRequest,id));
    caseRequest[@"magnet"]=[caseRequest[@"magnet"] stringByAppendingFormat:@"&dn=%@",[@"x" stringByPaddingToLength:20000 withString:@"x" startingAtIndex:0]];assert(PVXRequest(caseRequest,id));
    NSString *temp=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];assert(PVXDir(temp));NSString *file=PVXJoin(temp,@"state.plist");assert(PVXWrite(file,r));assert([PVXRead(file) isEqual:r]);
    NSString *link=PVXJoin(temp,@"link");assert(symlink(file.fileSystemRepresentation,link.fileSystemRepresentation)==0);assert(!PVXRead(link));assert(!PVXTreeSafe(temp));unlink(link.fileSystemRepresentation);assert(PVXTreeSafe(temp));
    // A retained selective-download sidecar is allowed only with exact verified coverage.
    assert(PVXDir(PVXJoin(temp,@"torrent-cache")));assert(PVXDir(PVXJoin(temp,@"torrent-tasks")));
    PVXWorker w;w.root=temp;w.active=id;w.metadata=m;
    assert(PVXDir(w.cache(id)));assert(PVXDir(w.output(id)));
    NSMutableDictionary *snapshot=[r mutableCopy];snapshot[@"state"]=@"downloading";snapshot[@"token"]=NSUUID.UUID.UUIDString;
    assert(PVXWrite(w.task(id),snapshot));put(bits,50,1,4);put(bits,54,128,1);
    NSString *sidecar=PVXJoin(w.output(id),@"movie.mp4.aria2");assert([bits writeToFile:sidecar atomically:YES]);assert(!w.noSidecars());
    put(bits,54,192,1);assert([bits writeToFile:sidecar atomically:YES]);assert(w.noSidecars());
    NSString *unknown=PVXJoin(w.output(id),@"unknown.aria2");assert([bits writeToFile:unknown atomically:YES]);assert(!w.noSidecars());unlink(unknown.fileSystemRepresentation);
    // Nonzero and signal termination must remain nonzero through the supervisor.
    int lock=open(PVXJoin(temp,@"lock").fileSystemRepresentation,O_CREAT|O_RDWR,0600);assert(lock>=0);
    PVXChild child=PVXSpawn(@[@"/bin/sh",@"-c",@"exit 9"],lock);assert(child.pid>0);int status=0;assert(waitpid(child.pid,&status,0)==child.pid);assert(WIFEXITED(status)&&WEXITSTATUS(status)==9);close(child.life);close(child.log);
    child=PVXSpawn(@[@"/bin/sh",@"-c",@"kill -TERM $$"],lock);assert(waitpid(child.pid,&status,0)==child.pid);assert(WIFEXITED(status)&&WEXITSTATUS(status)!=0);close(child.life);close(child.log);
    child=PVXSpawn(@[@"/bin/sh",@"-c",@"exec sleep 30"],lock);assert(child.pid>0);close(child.life);child.life=-1;
    double deadline=PVXNow()+12;pid_t ended=0;while(PVXNow()<deadline){ended=waitpid(child.pid,&status,WNOHANG);if(ended==child.pid)break;poll(nullptr,0,20);}assert(ended==child.pid);assert(!WIFEXITED(status)||WEXITSTATUS(status)!=0);close(child.log);close(lock);
    [NSFileManager.defaultManager removeItemAtPath:temp error:nil];puts("PASS metadata/hash/schema/verified-bitfield/symlink/atomic-write/supervisor-exit tests");
}}

// Strict, bounded bencode reader. Included by main.mm (no extra link unit).
#import <CommonCrypto/CommonDigest.h>
#import "../src/PVXMagnet.h"
#include <limits.h>
struct PVXBencode {
    NSData *data; NSUInteger pos=0, nodes=0, infoStart=0, infoEnd=0;
    id parse(unsigned depth=0) {
        if(depth>32 || ++nodes>200000 || pos>=data.length) return nil;
        const unsigned char *b=(const unsigned char *)data.bytes;
        unsigned char c=b[pos++];
        if(c=='i') {
            NSUInteger start=pos; while(pos<data.length && b[pos]!='e') pos++;
            if(pos==data.length || pos==start || pos-start>20) return nil;
            NSString *s=[[NSString alloc] initWithBytes:b+start length:pos-start encoding:NSASCIIStringEncoding]; pos++;
            if(!s || [s hasPrefix:@"-0"] || (s.length>1 && [s hasPrefix:@"0"])) return nil;
            const char *p=s.UTF8String; char *end=nullptr; errno=0; long long n=strtoll(p,&end,10);
            if(errno || !end || *end || !(p[0]=='-' || (p[0]>='0'&&p[0]<='9'))) return nil;
            return @(n);
        }
        if(c=='l' || c=='d') {
            NSMutableArray *a=[NSMutableArray array]; NSMutableDictionary *d=[NSMutableDictionary dictionary]; NSData *previous=nil;
            while(pos<data.length && b[pos]!='e') {
                id key=nil;
                if(c=='d') {
                    key=parse(depth+1); if(![key isKindOfClass:NSData.class]) return nil;
                    if(previous) {NSUInteger n=MIN(previous.length,[key length]); int cmp=memcmp(previous.bytes,[key bytes],n); if(cmp>0 || (cmp==0 && previous.length>=[key length]))return nil;}
                    previous=key;
                }
                NSUInteger start=pos; id value=parse(depth+1); if(!value)return nil;
                if(c=='d') { d[key]=value; if(depth==0 && [key isEqual:[@"info" dataUsingEncoding:NSUTF8StringEncoding]]){infoStart=start;infoEnd=pos;} }
                else [a addObject:value];
            }
            if(pos>=data.length)return nil; pos++; return c=='d'?(id)d:(id)a;
        }
        if(c<'0'||c>'9')return nil;
        NSUInteger n=c-'0'; BOOL zero=n==0;
        while(pos<data.length && b[pos]!=':') {if(zero||b[pos]<'0'||b[pos]>'9'||n>16*1024*1024)return nil;n=n*10+b[pos++]-'0';}
        if(pos>=data.length || b[pos++]!=':' || n>data.length-pos)return nil;
        NSData *s=[data subdataWithRange:NSMakeRange(pos,n)];pos+=n;return s;
    }
};
static id PVXB(id d,NSString *key){return [d isKindOfClass:NSDictionary.class]?d[[key dataUsingEncoding:NSUTF8StringEncoding]]:nil;}
static NSString *PVXComponent(id raw){
    if(![raw isKindOfClass:NSData.class])return nil;
    NSString *s=[[NSString alloc]initWithData:raw encoding:NSUTF8StringEncoding];
    if(!s.length || s.length>240 || [s isEqual:@"."] || [s isEqual:@".."] || [s rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\:\0"]].location!=NSNotFound)return nil;
    for(NSUInteger i=0;i<s.length;i++)if([s characterAtIndex:i]<32)return nil;
    return s;
}
static NSString *PVXMagnetHash(NSString *magnet){return PVXMagnetInfoHash(magnet);}
static NSDictionary *PVXMetadata(NSData *data,NSString *hash){
    if(!data.length || data.length>16*1024*1024)return nil;
    PVXBencode parser;parser.data=data;id top=parser.parse();id info=PVXB(top,@"info");
    if(!info || PVXB(info,@"name.utf-8") || PVXB(info,@"attr") || PVXB(info,@"symlink path") || parser.pos!=data.length || parser.infoEnd<=parser.infoStart)return nil;
    unsigned char digest[CC_SHA1_DIGEST_LENGTH]; CC_SHA1((const char *)data.bytes+parser.infoStart,(CC_LONG)(parser.infoEnd-parser.infoStart),digest);
    NSMutableString *actual=[NSMutableString string];for(unsigned i=0;i<sizeof(digest);i++)[actual appendFormat:@"%02x",digest[i]];if(![actual isEqual:hash])return nil;
    NSString *name=PVXComponent(PVXB(info,@"name"));if(!name)return nil;
    id files=PVXB(info,@"files");if(files && ![files isKindOfClass:NSArray.class])return nil;
    if(!files)files=@[info]; if(![files count] || [files count]>10000)return nil;
    NSMutableSet *paths=[NSMutableSet set];long long total=0,best=0,bestOffset=0;NSUInteger index=0,bestIndex=0;NSString *bestPath=nil;
    for(id f in files){index++;id length=PVXB(f,@"length");if(![length isKindOfClass:NSNumber.class])return nil;long long n=[length longLongValue];if(n<0||n>64LL*1024*1024*1024 || total>64LL*1024*1024*1024-n)return nil;total+=n;
        if(PVXB(f,@"symlink path") || PVXB(f,@"attr") || PVXB(f,@"path.utf-8"))return nil;
        NSMutableArray *parts=[NSMutableArray arrayWithObject:name];
        if(PVXB(info,@"files")){id p=PVXB(f,@"path");if(![p isKindOfClass:NSArray.class]||![p count]||[p count]>32)return nil;for(id raw in p){NSString *s=PVXComponent(raw);if(!s)return nil;[parts addObject:s];}}
        NSString *path=[NSString pathWithComponents:parts];if([path lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>1024)return nil;NSString *fold=path.precomposedStringWithCanonicalMapping.lowercaseString;if([paths containsObject:fold])return nil;[paths addObject:fold];
        if([path.pathExtension.lowercaseString isEqual:@"mp4"]&&n>best){best=n;bestOffset=total-n;bestPath=path;bestIndex=index;}
    }
    for(NSString *p in paths){NSString *parent=p.stringByDeletingLastPathComponent;while(parent.length && ![parent isEqual:@"."]){if([paths containsObject:parent])return nil;parent=parent.stringByDeletingLastPathComponent;}}
    id piece=PVXB(info,@"piece length"),pieces=PVXB(info,@"pieces");long long pl=[piece isKindOfClass:NSNumber.class]?[piece longLongValue]:0;
    if(pl<=0||pl>64*1024*1024||![pieces isKindOfClass:NSData.class]||[pieces length]!=(NSUInteger)((total+pl-1)/pl)*20||!bestPath||best>16LL*1024*1024*1024)return nil;
    return @{@"path":bestPath,@"length":@(best),@"index":@(bestIndex),@"storage":@(total),@"offset":@(bestOffset),@"pieceLength":@(pl),@"name":name};
}

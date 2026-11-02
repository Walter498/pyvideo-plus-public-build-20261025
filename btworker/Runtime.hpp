// Helpers for the single-owner runtime. No network or pathname interpretation here.
static BOOL PVXExists(NSString *p){struct stat s;return lstat(p.fileSystemRepresentation,&s)==0 || errno!=ENOENT;}
static BOOL PVXHash(id h){return [h isKindOfClass:NSString.class]&&[h length]==40&&[h rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;}
static BOOL PVXText(id s,NSUInteger cap){return [s isKindOfClass:NSString.class]&&[s length]<=cap;}
static BOOL PVXRequest(NSDictionary *r,NSString *ident){
    if(r.count>16 || ![r[@"id"] isEqual:ident] || ![r[@"kind"] isEqual:@"video"] || ![r[@"backend"] isEqual:@"torrent"] || ![r[@"sourceKind"] isEqual:@"magnet"])return NO;
    NSString *m=r[@"magnet"];if(!PVXText(m,32768)||![m.lowercaseString hasPrefix:@"magnet:?"])return NO;
    NSString *hash=PVXMagnetHash(m);if(!hash)return NO;
    if(r[@"infoHash"]&&(!PVXText(r[@"infoHash"],40)||![r[@"infoHash"] isEqual:hash]))return NO;
    for(NSString *k in @[@"title",@"page",@"sourceKey"])if(r[k]&&!PVXText(r[k],[k isEqual:@"page"]?16384:1024))return NO;
    id created=r[@"created"];return !created||([created isKindOfClass:NSNumber.class]&&isfinite([created doubleValue])&&[created doubleValue]>=0);
}
static BOOL PVXState(NSDictionary *s,NSString *ident){
    if(!s || ![s[@"id"] isEqual:ident]||![s[@"kind"] isEqual:@"video"]||![s[@"backend"] isEqual:@"torrent"])return NO;
    if(![@[@"queued",@"downloading",@"pausing",@"paused",@"failed",@"ready",@"deleting",@"deleted",@"cancelled"] containsObject:s[@"state"]?:@""])return NO;
    if([s[@"state"] isEqual:@"deleting"]||[s[@"state"] isEqual:@"deleted"]||[s[@"state"] isEqual:@"cancelled"])return YES;
    for(NSString *k in @[@"received",@"total",@"created",@"updated",@"width",@"height",@"progress",@"piecesDone",@"piecesTotal"]){id n=s[k];if(n&&(![n isKindOfClass:NSNumber.class]||!isfinite([n doubleValue])))return NO;}
    if(s[@"received"]&&([s[@"received"] longLongValue]<0||[s[@"received"] unsignedLongLongValue]>16ULL*1024*1024*1024))return NO;
    if([s[@"state"] isEqual:@"ready"]&&(![s[@"total"] isKindOfClass:NSNumber.class]||[s[@"total"] longLongValue]<=0))return NO;
    return PVXHash(s[@"infoHash"])&&PVXID(s[@"token"]);
}
// aria2 1.x DefaultBtProgressInfoFile: network-endian v1 + complete-piece bitfield.
// Only fully verified pieces count; in-flight blocks and sparse file lengths do not.
static uint64_t PVXBE(const unsigned char *p,unsigned n){uint64_t v=0;for(unsigned i=0;i<n;i++)v=(v<<8)|p[i];return v;}
static NSDictionary *PVXVerified(NSData *d,NSDictionary *m,NSString *hash){
    if(d.length<58)return nil;const unsigned char *b=(const unsigned char *)d.bytes;
    if(PVXBE(b,2)!=1||PVXBE(b+2,4)!=1||PVXBE(b+6,4)!=20)return nil;
    NSMutableString *h=[NSMutableString string];for(unsigned i=0;i<20;i++)[h appendFormat:@"%02x",b[10+i]];if(![h isEqual:hash])return nil;
    uint64_t pl=PVXBE(b+30,4),total=PVXBE(b+34,8),bytes=PVXBE(b+50,4);
    if(pl!=[m[@"pieceLength"] unsignedLongLongValue]||total!=[m[@"storage"] unsignedLongLongValue]||!pl)return nil;
    uint64_t pieces=(total+pl-1)/pl;if(bytes!=(pieces+7)/8 || bytes>d.length-58)return nil;
    uint64_t start=[m[@"offset"] unsignedLongLongValue],end=start+[m[@"length"] unsignedLongLongValue],verified=0,done=0,count=0;
    for(uint64_t i=start/pl;i<(end+pl-1)/pl;i++){count++;if(b[54+i/8]&(128>>(i%8))){done++;verified+=MIN(end,(i+1)*pl)-MAX(start,i*pl);}}
    return @{@"received":@(verified),@"piecesDone":@(done),@"piecesTotal":@(count),@"progress":@((double)verified/[m[@"length"] doubleValue])};
}

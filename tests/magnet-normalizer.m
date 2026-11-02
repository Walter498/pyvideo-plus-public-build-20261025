#import <Foundation/Foundation.h>
#import "../src/PVXMagnet.h"
#include <stdlib.h>
static NSUInteger checks;
static void Check(BOOL ok, NSString *label) {
    if(!ok){NSLog(@"FAIL %@",label);exit(1);} checks++;
}
int main(void) { @autoreleasepool {
    NSString *hash=@"0102030405060708090a0b0c0d0e0f1011121314";
    Check([PVXMagnetInfoHash([@"magnet:?xt=urn:btih:" stringByAppendingString:hash]) isEqual:hash],@"hex");
    Check([PVXMagnetInfoHash(@"MAGNET:?xt=urn%3Abtih%3A0102030405060708090A0B0C0D0E0F1011121314") isEqual:hash],@"encoded xt and uppercase hex");
    Check([PVXMagnetInfoHash(@"magnet:?%78%74=urn%3Abtih%3AAEBAGBAFAYDQQCIKBMGA2DQPCAIREEYU") isEqual:hash],@"encoded key and base32");
    Check([PVXMagnetInfoHash(@"magnet:?xt=urn:btih:aebagbafaydqqcikbmga2dqpcaireeyu") isEqual:hash],@"lowercase base32");
    Check([PVXMagnetInfoHash(@"magnet:?xt=urn:btih:AEBAGBAFAYDQQCIKBMGA2DQPCAIREEYU&xt=urn:btih:0102030405060708090a0b0c0d0e0f1011121314") isEqual:hash],@"equivalent duplicate xt");
    for(id invalid in @[@42,NSNull.null,@"",@"https://x.test/a.torrent",@"magnet:?dn=nohash",@"magnet:?xt=urn:btih:bad",@"magnet:?xt=urn:btih:0102030405060708090a0b0c0d0e0f1011121314&xt=urn:btih:ffffffffffffffffffffffffffffffffffffffff",@"magnet:?xt=urn:btih:0102030405060708090a0b0c0d0e0f1011121314&xt=urn:btih:bad",@"magnet:?xt=urn:btih:00000000000000000000000000000000",@"magnet:?xt=urn:btih:0102030405060708090a0b0c0d0e0f1011121314&dn=%00",@"magnet:?xt=urn:btih:0102030405060708090a0b0c0d0e0f1011121314&dn=%0a",@"magnet:?xt=urn:btih:0102030405060708090a0b0c0d0e0f1011121314\n",@"magnet:?xt=urn:btih:0102030405060708090a0b0c0d0e0f1011121314#fragment",@"magnet:?xt=urn:btih:0102030405060708090a0b0c0d0e0f1011121314&dn=%ZZ"])
        Check(PVXMagnetInfoHash(invalid)==nil,@"reject malformed, conflicting or control input");
    NSMutableString *longURI=[@"magnet:?xt=urn:btih:0102030405060708090a0b0c0d0e0f1011121314&dn=" mutableCopy];
    while(longURI.length<=32768)[longURI appendString:@"a"];
    Check(!PVXMagnetInfoHash(longURI),@"reject excessive length");
    Check(PVXTorrentURL(@"https://example.test/file.TORRENT?x=1#fragment"),@"torrent URL recognized independently of query");
    Check(!PVXTorrentURL(@"https://example.test/file.mp4?x=.torrent"),@"query does not change media extension");
    NSString *engine=PVXMagnetEngineURI(@"MAGNET:?XT=urn%3Abtih%3A0102030405060708090A0B0C0D0E0F1011121314&TR=https%3A%2F%2Ftracker.test%2Fa%3Fsig%3DA%2BB");
    Check([engine isEqual:@"magnet:?xt=urn:btih:0102030405060708090a0b0c0d0e0f1011121314&tr=https%3A%2F%2Ftracker.test%2Fa%3Fsig%3DA%2BB"],@"engine routing canonicalizes case without changing encoded tracker tokens");
    NSLog(@"PASS %lu native Foundation magnet assertions",(unsigned long)checks);
    return 0;
}}

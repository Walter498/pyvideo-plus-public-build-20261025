#pragma once
#import <Foundation/Foundation.h>
// A single strict parser for page collection, import, and queue submission.
static inline NSString *PVXMagnetInfoHash(id value) {
 if (![value isKindOfClass:NSString.class] || [value length]>32768 || ![[value lowercaseString] hasPrefix:@"magnet:?"]) return nil;
 NSString *decoded=[value stringByRemovingPercentEncoding];
 if (!decoded || [decoded rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound) return nil;
 NSURLComponents *c=[NSURLComponents componentsWithString:value];
 if (!c || c.fragment || c.host.length) return nil;
 NSString *result=nil;
 for (NSURLQueryItem *item in c.queryItems) {
  if (![item.name.lowercaseString isEqual:@"xt"]) continue;
  NSString *xt=item.value.lowercaseString;
  if (![xt hasPrefix:@"urn:btih:"]) continue;
  NSString *h=[xt substringFromIndex:9];
  if (h.length==32) {
   NSString *alphabet=@"abcdefghijklmnopqrstuvwxyz234567"; unsigned int bits=0,acc=0; NSMutableString *hex=[NSMutableString string];
   for (NSUInteger i=0;i<h.length;i++) { NSRange r=[alphabet rangeOfString:[h substringWithRange:NSMakeRange(i,1)]]; if(r.location==NSNotFound)return nil; acc=(acc<<5)|(unsigned int)r.location;bits+=5;if(bits>=8){bits-=8;[hex appendFormat:@"%02x",(acc>>bits)&255];} }
   h=hex;
  }
  if (h.length!=40 || [h rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location!=NSNotFound) return nil;
  if (result && ![result isEqual:h]) return nil;
  result=h;
 }
 return result;
}
static inline BOOL PVXTorrentURL(id value) {
 if (![value isKindOfClass:NSString.class])return NO;
 return [[[[NSURLComponents componentsWithString:value] path] pathExtension].lowercaseString isEqual:@"torrent"];
}

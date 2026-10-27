#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdio.h>
#import <stdlib.h>
#import "PVXNativeRemux.h"
#if defined(EXPORT_MAIN_REMUX)
__attribute__((visibility("default")))
int PVRemuxHLSWithCancel(const char *a,const char *b,char *c,size_t n,int (*f)(void *),void *p) {
    (void)a;(void)b;(void)c;(void)n;(void)f;(void)p;
    abort(); // production must refuse before calling without verified shared lock
}
#endif
int main(int argc, char **argv) { @autoreleasepool {
    if (argc > 2 && !dlopen(argv[2], RTLD_NOW | RTLD_GLOBAL)) return 2;
    NSDictionary *d; NSString *error;
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    BOOL ok = PVXNativeRemuxHLSWithCancellation(@"fake",path,nil,&d,&error);
    NSString *expected = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"resolve";
    if (ok || ![d[@"stage"] isEqual:expected] || [d[@"nativeCalled"] boolValue] || !error.length) {
        NSLog(@"Unexpected %@ %@", d, error); return 1;
    }
    if (argc > 2 && ![error containsString:@"不属于当前主镜像"]) return 3;
    puts("PASS missing/foreign owner/production lock-contract rejection");
} return 0; }

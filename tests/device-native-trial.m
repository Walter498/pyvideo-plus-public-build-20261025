#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <unistd.h>
#import "PVXHLSLocalizer.h"
#import "PVXLibavInput.h"
#import "PVXNativeRemux.h"
#import "PVXAgentIdentity.h"
#import "PVXMediaValidator.h"
// Only activated in an isolated COPY of the hash-pinned Agent. Never enter
// original main, never read/write the production task database or publish ready.
__attribute__((constructor)) static void Trial(void) {
    const char *root=getenv("PVX_NATIVE_TRIAL");if(!root)return;
    @autoreleasepool {
        NSString *dir=[NSString stringWithUTF8String:root];
        NSError *error=nil;PVXHLSLocalizer *localizer=[PVXHLSLocalizer new];
        NSString *src=[NSString stringWithUTF8String:getenv("PVX_TRIAL_SOURCE")?:""];NSDictionary *task=src.length?@{@"hlsSourceURL":src}:@{};NSURL *playlist=[localizer localizeTask:task cacheDirectory:[NSURL fileURLWithPath:dir] error:&error];
        if(playlist)playlist=PVXLibavInput(playlist,&error);
        NSDictionary *diagnostic=nil;NSString *failure=nil;
        NSString *output=[dir stringByAppendingPathComponent:@"native-trial.mp4"];
        BOOL success=playlist&&PVXNativeRemuxHLSWithCancellation(playlist.path,output,nil,&diagnostic,&failure);
        __block BOOL validated=NO;__block NSDictionary *validation=nil;
        if(success){PVXValidateMediaFile(output,[localizer.summary[@"expectedDuration"] doubleValue],NO,^(BOOL ok,NSDictionary *d){validated=ok;validation=d;});while(!validation){[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];}}
        success=success&&validated;
        const struct mach_header *expected=PVXAgentExecutableHeader();
        NSMutableDictionary *report=[@{@"pid":@(getpid()),@"success":@(success),
            @"image0Type":@(_dyld_get_image_header(0)->filetype),
            @"image0Name":[NSString stringWithUTF8String:_dyld_get_image_name(0)],
            @"identifiedAgent":@(expected!=NULL),@"summary":localizer.summary?:@{},
            @"diagnostic":diagnostic?:@{},@"validation":validation?:@{},@"error":failure?:error.localizedDescription?:@"",
            @"output":output,@"inputReport":PVXLibavInputLastReport()?:@{},@"scope":@"isolated-copy-original-iOS-libav-no-task-publication"} mutableCopy];
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL];
        [json writeToFile:[dir stringByAppendingPathComponent:@"trial-report.json"] atomically:YES];
        if(playlist){}
        _exit(success?0:42);
    }
}

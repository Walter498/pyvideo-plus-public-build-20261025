#import <Foundation/Foundation.h>
#import "PVXHLSLocalizer.h"
#include <stdio.h>

// Thin offline adapter only: all selection, cache lookup and rewriting is production code.
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "usage: hls-e2e-cli task.json cache-directory\n");
            return 2;
        }
        NSError *error = nil;
        NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]
                                            options:0 error:&error];
        id task = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
        if (![task isKindOfClass:NSDictionary.class]) {
            fprintf(stderr, "Invalid task JSON: %s\n", (error.description ?: @"expected object").UTF8String);
            return 2;
        }
        PVXHLSLocalizer *localizer = [PVXHLSLocalizer new];
        __block NSUInteger networkAttempts = 0;
        localizer.keyFetchBlock = ^NSData *(NSURLRequest *request, NSError **fetchError) {
            (void)request;
            networkAttempts++;
            if (fetchError) *fetchError = [NSError errorWithDomain:@"PVXHLSE2EOffline" code:1
                userInfo:@{NSLocalizedDescriptionKey: @"Network forbidden: key must be cached"}];
            return nil;
        };
        NSURL *result = [localizer localizeTask:task cacheDirectory:
            [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]] isDirectory:YES] error:&error];
        NSDictionary *report = @{@"summary": localizer.summary,
                                  @"networkAttempts": @(networkAttempts)};
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL];
        if (json) fprintf(stderr, "%s\n", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
        if (!result || error || networkAttempts) {
            fprintf(stderr, "Production localizer failed: %s\n", (error.description ?: @"offline violation").UTF8String);
            return 1;
        }
        // A path, not an encoded URL: subprocess argv preserves spaces; never shell-split it.
        puts(result.path.fileSystemRepresentation);
        return 0;
    }
}

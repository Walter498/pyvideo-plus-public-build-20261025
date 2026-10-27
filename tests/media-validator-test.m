#import <Foundation/Foundation.h>
#import "../storage/PVXMediaValidator.h"
#import <math.h>
#import <stdlib.h>

static NSArray<NSDictionary *> *cases;
static NSString *fixtureRoot;
static NSUInteger caseIndex;
static NSUInteger callbacks;
static NSUInteger failures;

static void RunNext(void) {
    if (caseIndex == cases.count) {
        // Keep the main queue alive briefly to catch stray duplicate completions.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (callbacks != cases.count) failures += 1;
            printf("%s production media validator: %lu cases, %lu callbacks, %lu failures\n",
                   failures ? "FAIL" : "PASS", (unsigned long)cases.count,
                   (unsigned long)callbacks, (unsigned long)failures);
            exit(failures ? 1 : 0);
        });
        return;
    }
    NSDictionary *test = cases[caseIndex++];
    NSString *file = [fixtureRoot stringByAppendingPathComponent:test[@"file"]];
    __block NSUInteger calls = 0;
    PVXValidateMediaFile(file, [test[@"duration"] doubleValue], [test[@"audio"] boolValue],
        ^(BOOL valid, NSDictionary *details) {
            calls += 1;
            callbacks += 1;
            if (calls != 1) { failures += 1; return; }
            BOOL pass = [NSThread isMainThread] && valid == [test[@"valid"] boolValue];
            NSString *reason = test[@"reason"];
            if (reason && ![reason isEqual:details[@"reason"]]) pass = NO;
            if (valid) {
                pass = pass && [details[@"videoFramesDecoded"] unsignedIntegerValue] == 3 &&
                    ![details[@"fullDecode"] boolValue];
                if ([test[@"audio"] boolValue]) pass = pass && [details[@"audioSampleDecoded"] boolValue];
            }
            if (!pass) failures += 1;
            printf("%s %s: %s\n", pass ? "PASS" : "FAIL", [test[@"name"] UTF8String],
                   [[details description] UTF8String]);
            RunNext();
        });
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) { fprintf(stderr, "usage: media-validator-test FIXTURE_DIRECTORY\n"); return 2; }
        fixtureRoot = [NSString stringWithUTF8String:argv[1]];
        cases = @[
            @{@"name": @"h264-aac", @"file": @"valid.mp4", @"duration": @4, @"audio": @YES, @"valid": @YES},
            @{@"name": @"duration-disabled", @"file": @"valid.mp4", @"duration": @0, @"audio": @YES, @"valid": @YES},
            @{@"name": @"two-second-tolerance", @"file": @"valid.mp4", @"duration": @5.5, @"audio": @YES, @"valid": @YES},
            @{@"name": @"audio-delay", @"file": @"delayed-audio.mp4", @"duration": @4, @"audio": @YES, @"valid": @YES},
            @{@"name": @"optional-audio", @"file": @"video-only.mp4", @"duration": @4, @"audio": @NO, @"valid": @YES},
            @{@"name": @"missing-audio", @"file": @"video-only.mp4", @"duration": @4, @"audio": @YES, @"valid": @NO, @"reason": @"missing_audio"},
            @{@"name": @"missing-video", @"file": @"audio-only.mp4", @"duration": @4, @"audio": @YES, @"valid": @NO, @"reason": @"missing_video"},
            @{@"name": @"duration-mismatch", @"file": @"valid.mp4", @"duration": @40, @"audio": @YES, @"valid": @NO, @"reason": @"duration_mismatch"},
            @{@"name": @"truncated-header", @"file": @"truncated.mp4", @"duration": @0, @"audio": @NO, @"valid": @NO},
            @{@"name": @"truncated-tail", @"file": @"truncated-tail.mp4", @"duration": @4, @"audio": @YES, @"valid": @NO},
            @{@"name": @"empty", @"file": @"empty.mp4", @"duration": @0, @"audio": @NO, @"valid": @NO, @"reason": @"not_regular_nonempty_file"},
            @{@"name": @"symlink", @"file": @"symlink.mp4", @"duration": @0, @"audio": @NO, @"valid": @NO, @"reason": @"not_regular_nonempty_file"},
            @{@"name": @"directory", @"file": @".", @"duration": @0, @"audio": @NO, @"valid": @NO, @"reason": @"not_regular_nonempty_file"},
            @{@"name": @"absent", @"file": @"absent.mp4", @"duration": @0, @"audio": @NO, @"valid": @NO, @"reason": @"not_regular_nonempty_file"},
            @{@"name": @"garbage", @"file": @"not-media.mp4", @"duration": @0, @"audio": @NO, @"valid": @NO},
            @{@"name": @"nonfinite-expected", @"file": @"valid.mp4", @"duration": @(NAN), @"audio": @NO, @"valid": @NO, @"reason": @"invalid_expected_duration"}
        ];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            fprintf(stderr, "FAIL test watchdog: missing completion\n"); exit(1);
        });
        dispatch_async(dispatch_get_main_queue(), ^{ RunNext(); });
    }
    dispatch_main();
}

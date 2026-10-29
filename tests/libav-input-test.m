#import <Foundation/Foundation.h>
#import "PVXLibavInput.h"
#include <stdlib.h>

// Compile/link the production translation unit, never a copied implementation.
static NSString *root;
static NSUInteger checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { NSLog(@"FAIL %@", (__VA_ARGS__)); exit(1); } } while (0)
static NSString *Path(NSString *name) { return [root stringByAppendingPathComponent:name]; }
static void Text(NSString *name, NSString *text) {
    CHECK([text writeToFile:Path(name) atomically:YES encoding:NSUTF8StringEncoding error:NULL], @"write manifest");
}
static NSSet *Generated(void) {
    NSMutableSet *names = [NSMutableSet set];
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:NULL])
        if ([name hasPrefix:@"pvx-input-"]) [names addObject:name];
    return names;
}
static NSDictionary *Snapshot(void) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:NULL])
        if (![name hasPrefix:@"pvx-input-"]) result[name] = [NSData dataWithContentsOfFile:Path(name)];
    return result;
}
static NSString *Manifest(NSString *tag, NSString *second) {
    return [NSString stringWithFormat:@"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n%@#EXTINF:1,\na.ts\n#EXTINF:1,\n%@\n#EXT-X-ENDLIST\n", tag, second];
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        CHECK(argc == 4, @"usage: binary fixture-directory case retained-output.ts");
        NSString *fixture = [NSString stringWithUTF8String:argv[1]];
        NSString *mode = [NSString stringWithUTF8String:argv[2]];
        root = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"PVX input 测试 " stringByAppendingString:NSUUID.UUID.UUIDString]];
        CHECK([[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL], @"create cache");
        root = root.stringByResolvingSymlinksInPath;
        for (NSString *name in @[@"a.ts", @"b.ts"])
            CHECK([[NSFileManager defaultManager] copyItemAtPath:[fixture stringByAppendingPathComponent:name] toPath:Path(name) error:NULL], @"copy real AAC fixture");
        NSString *tag = @{@"encrypted":@"#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x00000000000000000000000000000001\n", @"map":@"#EXT-X-MAP:URI=\"init.bin\"\n", @"range":@"#EXT-X-BYTERANGE:188@0\n"}[mode] ?: @"";
        Text(@"index.m3u8", Manifest(tag, @"b.ts"));
        if ([mode isEqual:@"encrypted"]) {
            CHECK([[NSData dataWithBytes:"0123456789abcdef" length:16] writeToFile:Path(@"key.bin") atomically:YES], @"key");
            for (NSString *name in @[@"a", @"b"]) {
                NSData *encrypted = [NSData dataWithContentsOfFile:[fixture stringByAppendingPathComponent:[name stringByAppendingString:@".enc"]]];
                CHECK(encrypted.length && [encrypted writeToFile:Path([name stringByAppendingString:@".ts"]) atomically:YES], @"real AES ciphertext");
            }
        } else if ([mode isEqual:@"map"]) {
            CHECK([[NSData dataWithContentsOfFile:Path(@"a.ts")] writeToFile:Path(@"init.bin") atomically:YES], @"MAP resource");
        } else if ([mode isEqual:@"discontinuity"]) {
            Text(@"index.m3u8", [Manifest(@"", @"b.ts") stringByReplacingOccurrencesOfString:@"#EXTINF:1,\nb.ts" withString:@"#EXT-X-DISCONTINUITY\n#EXTINF:1,\nb.ts"]);
        } else if ([mode isEqual:@"missing"]) {
            Text(@"index.m3u8", Manifest(@"", @"missing.ts"));
        }
        NSDictionary *before = Snapshot();
        NSError *error = nil;
        NSURL *native = PVXLibavInput([NSURL fileURLWithPath:Path(@"index.m3u8")], &error);
        if ([mode isEqual:@"missing"]) {
            CHECK(!native && error.localizedDescription.length, @"mapping failure has NSError");
            CHECK(Generated().count == 0, @"mapping failure leaks no aliases or partial files");
        } else {
            CHECK(native && !error && [native.pathExtension isEqual:@"m3u8"], @"ordinary input still returns m3u8, never automatically continuous TS");
            NSString *manifest = [NSString stringWithContentsOfURL:native encoding:NSUTF8StringEncoding error:NULL];
            CHECK([manifest containsString:@"#EXTINF:"], @"ordinary native manifest retained");
            BOOL barrier = [@[@"encrypted", @"map", @"range", @"discontinuity"] containsObject:mode];
            if (barrier) {
                NSString *expected = @{@"encrypted":@"#EXT-X-KEY:", @"map":@"#EXT-X-MAP:", @"range":@"#EXT-X-BYTERANGE:", @"discontinuity":@"#EXT-X-DISCONTINUITY"}[mode];
                CHECK([manifest containsString:expected], @"semantic barrier retained");
            }
            if ([@[@"retry-missing", @"retry-corrupt"] containsObject:mode]) {
                // Remove the second private alias only, leaving one readable input.
                NSMutableArray *leaves = [NSMutableArray array];
                for (NSString *line in [manifest componentsSeparatedByString:@"\n"])
                    if (line.length && ![line hasPrefix:@"#"]) [leaves addObject:line];
                CHECK(leaves.count == 2, @"two native leaves");
                NSData *original = [NSData dataWithContentsOfFile:Path(leaves[1])];
                CHECK([[NSFileManager defaultManager] removeItemAtPath:Path(leaves[1]) error:NULL], @"inject retry read failure");
                if ([mode isEqual:@"retry-corrupt"]) {
                    // Never edit a hard link in place: replace only the private alias.
                    NSMutableData *corrupt = [original mutableCopy];
                    ((unsigned char *)corrupt.mutableBytes)[0] = 0;
                    CHECK([corrupt writeToFile:Path(leaves[1]) atomically:YES], @"replace private alias with invalid TS sync byte");
                }
            }
            NSSet *aliases = Generated();
            __block NSUInteger callbacks = 0, lastDone = 0;
            __block unsigned long long lastBytes = 0;
            __block BOOL observedCancel = NO;
            BOOL immediate = [mode isEqual:@"cancel-before"];
            BOOL during = [mode isEqual:@"cancel-during"];
            error = nil;
            NSURL *continuous = PVXLibavInputContinuousTS(native, ^BOOL{
                BOOL stop = immediate || (during && lastBytes > 0);
                if (stop) observedCancel = YES;
                return stop;
            }, ^(NSUInteger done, NSUInteger total, unsigned long long bytes) {
                CHECK(done <= total && done >= lastDone && bytes >= lastBytes, @"monotonic bounded progress");
                callbacks++; lastDone = done; lastBytes = bytes;
            }, &error);
            if (barrier || immediate || during || [@[@"retry-missing", @"retry-corrupt"] containsObject:mode]) {
                CHECK(!continuous && error.localizedDescription.length, @"unsafe/cancelled/failed retry returns nil and NSError");
                if (immediate || during) CHECK(observedCancel, @"cancellation predicate actually observed");
                if (during || [mode isEqual:@"retry-corrupt"])
                    CHECK(callbacks && lastBytes, @"cancel/read failure occurs after actual bytes, not only preflight");
                CHECK([aliases isEqual:Generated()], [NSString stringWithFormat:@"retry failure leaked/removed files: %@", Generated()]);
            } else {
                CHECK(continuous && !error && [continuous.pathExtension isEqual:@"ts"], @"explicit retry returns direct TS, no one-segment m3u8 wrapper");
                CHECK([continuous.path.stringByDeletingLastPathComponent isEqual:root], @"retry remains in cache");
                NSData *bytes = [NSData dataWithContentsOfURL:continuous];
                CHECK(bytes.length >= 188 && ((const unsigned char *)bytes.bytes)[0] == 0x47 && bytes.length % 188 == 0, @"physical TS packets");
                CHECK([bytes writeToFile:[NSString stringWithUTF8String:argv[3]] atomically:YES], @"retain production TS for independent probe/decode");
                CHECK(callbacks && lastDone == 2 && lastBytes > 0, @"complete progress reports both segments and bytes");
            }
            CHECK([before isEqual:Snapshot()], @"all source bytes unchanged before cleanup");
            NSString *foreign = [NSString stringWithFormat:@"pvx-input-%@-0.ts", NSUUID.UUID.UUIDString];
            Text(foreign, @"foreign nonce sentinel");
            // API contract: always clean with ORIGINAL m3u8, including retry TS.
            PVXLibavInputCleanup(native);
            CHECK([[NSFileManager defaultManager] fileExistsAtPath:Path(foreign)], @"cleanup preserves foreign nonce");
            NSMutableSet *remaining = [Generated() mutableCopy]; [remaining removeObject:foreign];
            CHECK(remaining.count == 0, [NSString stringWithFormat:@"nonce cleanup leaked aliases/continuous TS: %@", remaining]);
            PVXLibavInputCleanup(native); // idempotent
        }
        CHECK([before isEqual:Snapshot()], @"success/failure/cancel/cleanup never changes source bytes");
        [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
        NSLog(@"PASS %@: %lu checks", mode, (unsigned long)checks);
    }
    return 0;
}

#import <Foundation/Foundation.h>
#import "PVXHLSLocalizer.h"
#import "PVXHLSManifest.h"
#include <math.h>
#include <unistd.h>
#include <stdlib.h>
#include <limits.h>

static NSUInteger checks = 0;
#define CHECK(condition, message) do { \
    checks++; \
    if (!(condition)) { \
        NSLog(@"FAIL %s:%d %@", __FILE__, __LINE__, (message)); \
        abort(); \
    } \
} while (0)

static NSString *cache;
static PVXHLSLocalizer *localizer;
static NSString * const source = @"https://cdn.example/path/index.m3u8";

static NSString *File(NSString *name) {
    return [cache stringByAppendingPathComponent:name];
}

static void Bytes(NSString *name, NSUInteger length) {
    CHECK([[NSMutableData dataWithLength:length] writeToFile:File(name) atomically:YES], @"write bytes");
}

static void Text(NSString *name, NSString *text) {
    CHECK([text writeToFile:File(name) atomically:YES encoding:NSUTF8StringEncoding error:NULL], @"write text");
}

static void Sidecar(NSString *name, NSString *uri, NSDictionary *extra) {
    NSMutableDictionary *meta = [@{@"responseURL": uri} mutableCopy];
    [meta addEntriesFromDictionary:extra ?: @{}];
    CHECK([meta writeToFile:[File(name) stringByAppendingString:@".plist"] atomically:YES], @"write sidecar");
}

static void Fresh(void) {
    if (cache) [[NSFileManager defaultManager] removeItemAtPath:cache error:NULL];
    cache = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"PVX HLS test " stringByAppendingString:NSUUID.UUID.UUIDString]];
    CHECK([[NSFileManager defaultManager] createDirectoryAtPath:cache
        withIntermediateDirectories:YES attributes:nil error:NULL], @"create cache");
    cache=cache.stringByResolvingSymlinksInPath;
    localizer = [PVXHLSLocalizer new];
}

static NSDictionary *Task(NSString *text) {
    return @{@"hlsSourceURL": source, @"hlsPlaylistText": text};
}

static NSURL *Build(NSDictionary *task) {
    NSError *error = nil;
    NSURL *result = [localizer localizeTask:task cacheDirectory:[NSURL fileURLWithPath:cache] error:&error];
    CHECK(result != nil && error == nil, error.description ?: @"expected successful closure");
    CHECK(localizer.summary.count == 6, @"successful summary has six nonsecret fields");
    return result;
}

static NSString *Read(NSURL *url) {
    NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:NULL];
    CHECK(text != nil, @"read output");
    return text;
}

static void Failure(NSDictionary *task, NSInteger code) {
    NSError *error = nil;
    NSURL *result = [localizer localizeTask:task cacheDirectory:[NSURL fileURLWithPath:cache] error:&error];
    CHECK(result == nil && error != nil && error.localizedDescription.length > 0, @"detailed error required");
    CHECK(!code || ([error.domain isEqual:PVXHLSLocalizerErrorDomain] && error.code == code), error.description);
    CHECK(localizer.summary.count == 0, @"failure clears previous summary");
}

static void ClosedResource(NSString *uri) {
    NSURL *url = [NSURL URLWithString:uri];
    CHECK(url.isFileURL, @"only file URI reaches native remux input");
    char actual[PATH_MAX],root[PATH_MAX];
    CHECK(realpath(url.path.fileSystemRepresentation,actual)&&realpath(cache.fileSystemRepresentation,root),@"physical paths exist");
    NSString *actualPath=[NSString stringWithUTF8String:actual];
    NSString *rootPath=[NSString stringWithUTF8String:root];
    NSString *boundaryMessage=[NSString stringWithFormat:@"resource %@ inside root %@",actualPath,rootPath];
    CHECK([actualPath hasPrefix:[rootPath stringByAppendingString:@"/"]],boundaryMessage);
    CHECK([[NSFileManager defaultManager] fileExistsAtPath:url.path], @"resource exists");
}

static void Closed(NSURL *url) {
    NSError *error = nil;
    PVXHLSManifest *m = [PVXHLSManifest parseText:Read(url) baseURL:url error:&error];
    CHECK(m != nil, error.description);
    if (m.master) {
        for (PVXHLSVariant *variant in m.variants) {
            ClosedResource(variant.URI);
            Closed([NSURL URLWithString:variant.URI]);
        }
        for (PVXHLSEntry *audio in m.audioRenditions) {
            ClosedResource(audio.URI);
            Closed([NSURL URLWithString:audio.URI]);
        }
    } else {
        for (PVXHLSSegment *segment in m.segments) {
            ClosedResource(segment.URI);
            if (segment.key.URI) ClosedResource(segment.key.URI);
            if (segment.map.URI) ClosedResource(segment.map.URI);
        }
    }
}

static void SourceOrder(void) {
    Fresh();
    Bytes(@"a random.jpeg", 32);
    Bytes(@"z opaque.cache", 32);
    Sidecar(@"a random.jpeg", @"https://cdn.example/path/seg99.ts", nil);
    Sidecar(@"z opaque.cache", @"https://cdn.example/path/seg1.ts", nil);
    NSString *original = @"#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXT-X-MEDIA-SEQUENCE:77\n"
        @"#EXTINF:1.23456789,first\nseg99.ts\n#EXTINF:3.5,second\nseg1.ts\n#EXT-X-ENDLIST\n";
    Text(@"playlist-hash.txt", original);
    Text(@"local-0.m3u8", @"#EXTM3U\n#EXTINF:10,wrong\nmissing.ts\n#EXT-X-ENDLIST\n");
    NSURL *result = Build(@{@"hlsSourceURL": source});
    NSString *out = Read(result);
    CHECK([out containsString:@"#EXTINF:1.23456789,first"], @"preserve literal duration/title");
    CHECK([out rangeOfString:@"a%20random.jpeg"].location < [out rangeOfString:@"z%20opaque.cache"].location,
        @"manifest order wins over numeric suffix and directory order");
    CHECK(fabs([localizer.summary[@"expectedDuration"] doubleValue] - 4.73456789) < 1e-9, @"true duration sum");
    CHECK([localizer.summary[@"segmentCount"] integerValue] == 2, @"segment count");
    CHECK([localizer.summary[@"sourceKind"] isEqual:@"source-media"], @"source precedence");
    Closed(result);
    Failure(Task([original stringByReplacingOccurrencesOfString:@"seg1.ts" withString:@"absent.ts"]),
        PVXHLSLocalizerMissingResource);
    Failure(Task(@"#EXTM3U\n#EXTINF:2,\nseg1.ts\n"), PVXHLSLocalizerUnsupportedManifest);
    Failure(Task(@"#EXTM3U\nseg1.ts\n#EXT-X-ENDLIST\n"), PVXHLSLocalizerInvalidInput);
}

static void LocalKeys(void) {
    Fresh();
    Bytes(@"piece one", 32);
    Bytes(@"piece two", 32);
    Bytes(@"key one", 16);
    Bytes(@"key two", 16);
    Bytes(@"init map", 32);
    NSString *local = @"#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:123\n"
        @"#EXT-X-KEY:METHOD=AES-128,URI=\"key%20one\",IV=0x7B\n"
        @"#EXT-X-MAP:URI=\"init%20map\"\n#EXTINF:2.25,\npiece%20one\n"
        @"#EXT-X-KEY:METHOD=AES-128,URI=\"key%20two\"\n"
        @"#EXTINF:2.75,\npiece%20two\n#EXT-X-ENDLIST\n";
    Text(@"local-0.m3u8", local);
    NSURL *result = Build(@{});
    PVXHLSManifest *m = [PVXHLSManifest parseText:Read(result) baseURL:result error:NULL];
    CHECK(m.segments[0].sequence == 123 && m.segments[1].sequence == 124, @"original implicit sequence IV");
    CHECK([m.segments[0].key.IV isEqual:@"0x7B"] && !m.segments[1].key.IV, @"explicit/implicit IV preserved");
    CHECK([localizer.summary[@"keyCount"] integerValue] == 2, @"key rotation count");
    Closed(result);
    Bytes(@"key two", 15);
    Failure(@{}, PVXHLSLocalizerInvalidKey);
    Bytes(@"key two", 17);
    Failure(@{}, PVXHLSLocalizerInvalidKey);
    Text(@"local-0.m3u8", [local stringByReplacingOccurrencesOfString:@"AES-128" withString:@"SAMPLE-AES"]);
    Failure(@{}, PVXHLSLocalizerUnsupportedManifest);
    Text(@"local-0.m3u8", [local stringByReplacingOccurrencesOfString:@"IV=0x7B" withString:@"KEYFORMAT=\"com.drm\""]);
    Failure(@{}, PVXHLSLocalizerUnsupportedManifest);
}

static void Ranges(void) {
    Fresh();
    Bytes(@"slice opaque", 5);
    Bytes(@"map opaque", 4);
    Sidecar(@"slice opaque", @"https://cdn.example/path/shared.bin", @{@"range": @"bytes=100-104"});
    Sidecar(@"map opaque", @"https://cdn.example/path/init.bin", @{@"contentRange": @"bytes 20-23/100"});
    NSString *text = @"#EXTM3U\n#EXT-X-MAP:URI=\"init.bin\",BYTERANGE=\"4@20\"\n"
        @"#EXTINF:1.5,\n#EXT-X-BYTERANGE:5@100\nshared.bin\n#EXT-X-ENDLIST\n";
    NSURL *result = Build(Task(text));
    NSString *out = Read(result);
    CHECK([out containsString:@"BYTERANGE=\"4@0\""] && [out containsString:@"#EXT-X-BYTERANGE:5@0"],
        @"MAP and segment slices never apply original offset twice");
    Closed(result);
    Sidecar(@"slice opaque", @"https://cdn.example/path/shared.bin", nil);
    Build(Task(text)); // Exact length and insufficient original offset proves slicing.
    Bytes(@"slice opaque", 105);
    out = Read(Build(Task(text)));
    CHECK([out containsString:@"#EXT-X-BYTERANGE:5@100"], @"full resource retains offset");
    Bytes(@"slice opaque", 7);
    Failure(Task(text), PVXHLSLocalizerInvalidRange);
    Bytes(@"slice opaque", 5);
    Sidecar(@"slice opaque", @"https://cdn.example/path/shared.bin", @{@"range": @"bytes=99-103"});
    Failure(Task(text), PVXHLSLocalizerInvalidRange);
    Bytes(@"whole", 20);
    Sidecar(@"whole", @"https://cdn.example/path/whole.bin", nil);
    text = @"#EXTM3U\n#EXTINF:1,\n#EXT-X-BYTERANGE:5@2\nwhole.bin\n"
        @"#EXTINF:2,\n#EXT-X-BYTERANGE:5\nwhole.bin\n#EXT-X-ENDLIST\n";
    out = Read(Build(Task(text)));
    CHECK([out containsString:@"#EXT-X-BYTERANGE:5@7"], @"implicit range becomes explicit local offset");
    Failure(Task([text stringByReplacingOccurrencesOfString:@"5@2" withString:@"5"]), PVXHLSLocalizerInvalidRange);
}

static void MasterAudio(void) {
    Fresh();
    NSString *master = @"#EXTM3U\n#EXT-X-VERSION:6\n"
        @"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"English\",DEFAULT=YES,URI=\"a/list.m3u8\"\n"
        @"#EXT-X-STREAM-INF:BANDWIDTH=2000,RESOLUTION=1280x720,AUDIO=\"audio\"\nv/list.m3u8\n";
    Text(@"playlist-hash.txt", master);
    Text(@"video opaque", @"#EXTM3U\n#EXTINF:4.25,\nseg.dat\n#EXT-X-ENDLIST\n");
    Text(@"audio opaque", @"#EXTM3U\n#EXTINF:2.125,\none.dat\n#EXTINF:2.125,\ntwo.dat\n#EXT-X-ENDLIST\n");
    Sidecar(@"video opaque", @"https://cdn.example/path/v/list.m3u8", nil);
    Sidecar(@"audio opaque", @"https://cdn.example/path/a/list.m3u8", nil);
    Bytes(@"video data", 32);
    Bytes(@"audio one", 32);
    Bytes(@"audio two", 32);
    Sidecar(@"video data", @"https://cdn.example/path/v/seg.dat", nil);
    Sidecar(@"audio one", @"https://cdn.example/path/a/one.dat", nil);
    Sidecar(@"audio two", @"https://cdn.example/path/a/two.dat", nil);
    NSURL *result = Build(@{@"hlsSourceURL": source});
    Closed(result);
    CHECK([localizer.summary[@"requireAudio"] boolValue], @"master declares required audio");
    CHECK([localizer.summary[@"trackCount"] integerValue] == 2, @"both selected tracks closed");
    CHECK([localizer.summary[@"segmentCount"] integerValue] == 3, @"all track segments counted");
    CHECK([localizer.summary[@"expectedDuration"] doubleValue] == 4.25, @"duration is video not sum of audio+video");
    CHECK([localizer.summary[@"sourceKind"] isEqual:@"source-master"], @"master source kind");
    [[NSFileManager defaultManager] removeItemAtPath:File(@"audio two") error:NULL];
    Failure(@{@"hlsSourceURL": source}, PVXHLSLocalizerMissingResource);
}

static void PathsAndAmbiguity(void) {
    Fresh();
    Bytes(@"part", 32);
    NSString *text = @"#EXTM3U\n#EXTINF:3,\npart\n#EXT-X-ENDLIST\n";
    Text(@"local-0.m3u8", text);
    Closed(Build(@{})); // Direct local files need no sidecar.
    NSString *outside = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    CHECK([[NSMutableData dataWithLength:16] writeToFile:outside atomically:YES], @"outside fixture");
    NSString *escape = [NSString stringWithFormat:@"#EXTM3U\n#EXTINF:3,\n%@\n#EXT-X-ENDLIST\n",
        [NSURL fileURLWithPath:outside].absoluteString];
    Text(@"local-0.m3u8", escape);
    Failure(@{}, PVXHLSLocalizerUnsafePath);
    CHECK(symlink(outside.fileSystemRepresentation, File(@"link").fileSystemRepresentation) == 0, @"symlink fixture");
    Text(@"local-0.m3u8", [text stringByReplacingOccurrencesOfString:@"\npart\n" withString:@"\nlink\n"]);
    Failure(@{}, PVXHLSLocalizerUnsafePath);
    CHECK(symlink(File(@"part").fileSystemRepresentation, File(@"inside-link").fileSystemRepresentation) == 0,
        @"internal symlink fixture");
    Text(@"local-0.m3u8", [text stringByReplacingOccurrencesOfString:@"\npart\n" withString:@"\ninside-link\n"]);
    Failure(@{}, PVXHLSLocalizerUnsafePath);
    [[NSFileManager defaultManager] removeItemAtPath:outside error:NULL];
    Bytes(@"part", 0);
    Text(@"local-0.m3u8", text);
    Failure(@{}, PVXHLSLocalizerUnsafePath);
    Bytes(@"part", 32);
    Sidecar(@"part", @"https://cdn.example/path/part", nil);
    Bytes(@"duplicate", 32);
    Sidecar(@"duplicate", @"https://cdn.example/path/part", nil);
    Failure(Task(text), PVXHLSLocalizerAmbiguousResource);
    // Different hosts with the same basename must never use basename fallback.
    Sidecar(@"duplicate", @"https://other.example/path/part", nil);
    Failure(Task([text stringByReplacingOccurrencesOfString:@"\npart\n" withString:@"\nhttps://third.example/path/part\n"]),
        PVXHLSLocalizerMissingResource);
}

static NSHTTPCookie *Cookie(NSString *name, NSString *domain, NSString *path, BOOL secure) {
    NSMutableDictionary *properties = [@{NSHTTPCookieName: name, NSHTTPCookieValue: @"value",
        NSHTTPCookieDomain: domain, NSHTTPCookiePath: path} mutableCopy];
    if (secure) properties[NSHTTPCookieSecure] = @"TRUE";
    return [NSHTTPCookie cookieWithProperties:properties];
}

static void FetchKeys(void) {
    Fresh();
    Bytes(@"part", 32);
    Sidecar(@"part", @"https://cdn.example/path/part", nil);
    NSString *text = @"#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:18\n"
        @"#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXTINF:3,\npart\n#EXT-X-ENDLIST\n";
    NSMutableDictionary *task = [Task(text) mutableCopy];
    task[@"headers"] = @{@"Authorization": @"test", @"Cookie": @"unscoped=never", @"User-Agent": @"offline-test"};
    task[@"cookies"] = @[Cookie(@"valid", @"cdn.example", @"/path", YES),
        Cookie(@"wrongHost", @"evil.example", @"/", NO), Cookie(@"wrongPath", @"cdn.example", @"/path-other", NO)];
    __block NSUInteger requests = 0;
    localizer.keyFetchBlock = ^NSData *(NSURLRequest *request, NSError **error) {
        requests++;
        NSString *cookies = [request valueForHTTPHeaderField:@"Cookie"];
        CHECK([cookies containsString:@"valid=value"] && ![cookies containsString:@"wrong"] &&
            ![cookies containsString:@"unscoped"], @"domain/path-scoped cookies only");
        CHECK([[request valueForHTTPHeaderField:@"Authorization"] isEqual:@"test"], @"same-origin header");
        return [NSMutableData dataWithLength:16];
    };
    Closed(Build(task));
    CHECK(requests == 1 && [localizer.summary[@"keyCount"] integerValue] == 1, @"one missing key fetched");
    Build(task);
    CHECK(requests == 1, @"downloaded key sidecar persists across calls");
    text = [text stringByReplacingOccurrencesOfString:@"key.bin" withString:@"https://keys.example/new.bin"];
    task[@"hlsPlaylistText"] = text;
    localizer.keyFetchBlock = ^NSData *(NSURLRequest *request, NSError **error) {
        CHECK(![request valueForHTTPHeaderField:@"Authorization"] &&
            ![request valueForHTTPHeaderField:@"Cookie"], @"no credential leak to other origin");
        return [NSMutableData dataWithLength:15];
    };
    Failure(task, PVXHLSLocalizerInvalidKey);
    localizer.keyFetchBlock = ^NSData *(NSURLRequest *request, NSError **error) {
        return [NSMutableData dataWithLength:17];
    };
    Failure(task, PVXHLSLocalizerInvalidKey);
    // No secure cookie on plaintext HTTP, even on the correct host/path.
    task[@"hlsPlaylistText"] = [text stringByReplacingOccurrencesOfString:@"https://keys.example/new.bin"
        withString:@"http://cdn.example/path/http-key.bin"];
    localizer.keyFetchBlock = ^NSData *(NSURLRequest *request, NSError **error) {
        CHECK(![request valueForHTTPHeaderField:@"Cookie"], @"secure cookie withheld on HTTP");
        return [NSMutableData dataWithLength:16];
    };
    Build(task);
}

static void LegacyAndUnsupported(void) {
    Fresh();
    Bytes(@"random a", 32);
    Bytes(@"random z", 32);
    Sidecar(@"random a", @"https://cdn.example/segment11.ts", @{@"duration": @2.5});
    Sidecar(@"random z", @"https://cdn.example/segment10.ts", @{@"duration": @1.5});
    Text(@"local-0.m3u8", @"#EXTM3U\n#EXT-X-TARGETDURATION:3\n"
        @"#EXTINF:2.5,eleven\nrandom%20a\n#EXTINF:1.5,ten\nrandom%20z\n#EXT-X-ENDLIST\n");
    NSString *normal = Read(Build(@{}));
    CHECK([normal rangeOfString:@"random%20a"].location < [normal rangeOfString:@"random%20z"].location,
        @"unverified local playlist never reordered");
    NSDictionary *verified = @{@"hlsLegacyRandomOrderVerified": @YES};
    NSString *ordered = Read(Build(verified));
    CHECK([ordered rangeOfString:@"random%20z"].location < [ordered rangeOfString:@"random%20a"].location,
        @"only verified complete legacy mapping reordered");
    CHECK([localizer.summary[@"expectedDuration"] doubleValue] == 4, @"legacy real duration retained");
    Sidecar(@"random z", @"https://cdn.example/segment9.ts", @{@"duration": @1.5});
    Failure(verified, PVXHLSLocalizerMissingResource);
    Sidecar(@"random z", @"https://cdn.example/segment10.ts", nil);
    Failure(verified, PVXHLSLocalizerUnsupportedManifest);
    NSString *simple = @"#EXTM3U\n#EXTINF:1,\nrandom%20a\n#EXT-X-ENDLIST\n";
    Text(@"local-0.m3u8", [simple stringByReplacingOccurrencesOfString:@"#EXTINF:1,"
        withString:@"#EXT-X-GAP\n#EXTINF:1,"]);
    Failure(@{}, PVXHLSLocalizerUnsupportedManifest);
    Text(@"local-0.m3u8", [simple stringByReplacingOccurrencesOfString:@"#EXTINF:1,"
        withString:@"#EXT-X-KEY\n#EXTINF:1,"]);
    Failure(@{}, PVXHLSLocalizerInvalidInput);
    Text(@"local-0.m3u8", [simple stringByReplacingOccurrencesOfString:@"#EXTINF:1,"
        withString:@"#EXT-X-KEY:METHOD=AES-128\n#EXTINF:1,"]);
    Failure(@{}, PVXHLSLocalizerInvalidInput);
    Text(@"local-0.m3u8", [simple stringByReplacingOccurrencesOfString:@"#EXTINF:1,"
        withString:@"#EXT-X-DISCONTINUITY\n#EXTINF:1,"]);
    Closed(Build(@{})); // A genuine manifest discontinuity is retained, never reordered.
    Text(@"local-0.m3u8", [simple stringByReplacingOccurrencesOfString:@"#EXTINF:1,"
        withString:@"#EXT-X-KEY:METHOD=NONE\n#EXTINF:1,"]);
    Closed(Build(@{}));
    Text(@"local-0.m3u8", [simple stringByReplacingOccurrencesOfString:@"#EXTINF:1,"
        withString:@"#EXT-X-PART:URI=\"https://remote/part\"\n#EXTINF:1,"]);
    Failure(@{}, PVXHLSLocalizerUnsupportedManifest);
}

static void RootAdapter(void) {
    Fresh();
    NSString *root = cache;
    cache = [root stringByAppendingPathComponent:@"media/task-1.hls"];
    CHECK([[NSFileManager defaultManager] createDirectoryAtPath:cache withIntermediateDirectories:YES
        attributes:nil error:NULL], @"root adapter fixture");
    Bytes(@"part", 32);
    Text(@"local-0.m3u8", @"#EXTM3U\n#EXTINF:3,\npart\n#EXT-X-ENDLIST\n");
    NSError *error = nil;
    NSURL *result = [localizer localizeTask:@{@"id": @"task-1"}
        rootDirectory:[NSURL fileURLWithPath:root] error:&error];
    CHECK(result != nil && [localizer.summary[@"expectedDuration"] doubleValue] == 3, @"root entry point");
    result = [localizer localizeTask:@{@"id": @"../escape"}
        rootDirectory:[NSURL fileURLWithPath:root] error:&error];
    CHECK(!result && error && !localizer.summary.count, @"invalid root id resets summary");
    [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
    cache = nil;
}

static void CachedRedirectAndPrivateTag(void) {
    Fresh();Bytes(@"segment",188);
    Sidecar(@"segment",@"https://cdn2.example/dir/part.ts",nil);
    Text(@"playlist-root.txt",@"#EXTM3U\n#EXTINF:2,\npart.ts\n#EXT-X-ENDLIST\n");
    Sidecar(@"playlist-root.txt",@"https://cdn2.example/dir/index.m3u8",@{@"url":@"https://origin.example/index.m3u8"});
    Closed(Build(@{@"hlsSourceURL":@"https://origin.example/index.m3u8"}));
    Fresh();Bytes(@"part.ts",188);
    Text(@"local-0.m3u8",@"#EXTM3U\n#EXT-X-TOKEN:opaque-local-metadata\n#EXTINF:2,\npart.ts\n#EXT-X-ENDLIST\n");
    NSURL *result=Build(@{});
    CHECK(![Read(result) containsString:@"#EXT-X-TOKEN"],@"private nonresource token stripped");
    Closed(result);
}

int main(void) {
    @autoreleasepool {
        NSOperationQueue *queue = [NSOperationQueue new];
        [queue addOperationWithBlock:^{
            @autoreleasepool {
                SourceOrder();
                LocalKeys();
                Ranges();
                MasterAudio();
                PathsAndAmbiguity();
                FetchKeys();
                LegacyAndUnsupported();
                RootAdapter();
                CachedRedirectAndPrivateTag();
                NSLog(@"PASS HLS localizer: %lu assertions", (unsigned long)checks);
            }
        }];
        [queue waitUntilAllOperationsAreFinished];
    }
    return 0;
}

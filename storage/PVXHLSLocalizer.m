#import "PVXHLSLocalizer.h"
#import "PVXHLSManifest.h"
#include <sys/stat.h>
#include <stdlib.h>
#include <limits.h>
#include <math.h>

NSString * const PVXHLSLocalizerErrorDomain = @"PVXHLSLocalizer";
static const NSUInteger PVXManifestLimit = 2 * 1024 * 1024;

static id PVXFail(NSError **error, NSInteger code, NSString *message, NSString *resource) {
    if (error) {
        NSMutableDictionary *info = [@{NSLocalizedDescriptionKey: message} mutableCopy];
        if (resource) info[@"resource"] = resource;
        *error = [NSError errorWithDomain:PVXHLSLocalizerErrorDomain code:code userInfo:info];
    }
    return nil;
}

static BOOL PVXUInt(NSString *text, unsigned long long *value) {
    if (![text isKindOfClass:NSString.class] || !text.length) return NO;
    unsigned long long n = 0;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c < '0' || c > '9' || n > (ULLONG_MAX - (c - '0')) / 10) return NO;
        n = n * 10 + c - '0';
    }
    *value = n;
    return YES;
}

static NSDictionary *PVXAttributes(NSString *text) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSUInteger start = 0;
    BOOL quoted = NO;
    for (NSUInteger i = 0; i <= text.length; i++) {
        unichar c = i < text.length ? [text characterAtIndex:i] : ',';
        if (c == '"') quoted = !quoted;
        if (c != ',' || quoted) continue;
        NSString *part = [text substringWithRange:NSMakeRange(start, i - start)];
        NSRange eq = [part rangeOfString:@"="];
        if (eq.location == NSNotFound) return nil;
        NSString *key = [part substringToIndex:eq.location];
        NSString *value = [part substringFromIndex:eq.location + 1];
        if (value.length >= 2 && [value hasPrefix:@"\""] && [value hasSuffix:@"\""]) {
            value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
        }
        if (!key.length || out[key]) return nil;
        out[key] = value;
        start = i + 1;
    }
    return quoted ? nil : out;
}

static NSString *PVXReplaceURI(NSString *line, NSString *uri) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
        @"(?:^|,)URI=\"[^\"]*\"" options:0 error:NULL];
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location == NSNotFound) return nil;
    NSString *attrs = [line substringFromIndex:colon.location + 1];
    NSTextCheckingResult *match = [re firstMatchInString:attrs options:0
        range:NSMakeRange(0, attrs.length)];
    if (!match) return nil;
    NSString *old = [attrs substringWithRange:match.range];
    NSString *replacement = [NSString stringWithFormat:@"%@URI=\"%@\"",
        [old hasPrefix:@","] ? @"," : @"", uri];
    attrs = [attrs stringByReplacingCharactersInRange:match.range withString:replacement];
    return [[line substringToIndex:colon.location + 1] stringByAppendingString:attrs];
}

static NSString *PVXTrim(NSString *line) {
    return [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static BOOL PVXRemote(NSURL *url) {
    return url.host.length && !url.user.length && !url.password.length &&
        ([@"https" isEqual:url.scheme.lowercaseString] ||
         [@"http" isEqual:url.scheme.lowercaseString]);
}

// The data delegate caps transfer while receiving, rather than after buffering.
@interface PVXKeyTransfer : NSObject <NSURLSessionDataDelegate>
@property(nonatomic, strong) NSMutableData *data;
@property(nonatomic, strong) NSError *failure;
@property(nonatomic) BOOL finished;
@property(nonatomic, strong) NSCondition *condition;
@end

@implementation PVXKeyTransfer
- (instancetype)init {
    if ((self = [super init])) _data = [NSMutableData data];
    return self;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
    newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completionHandler {
    self.failure = [NSError errorWithDomain:PVXHLSLocalizerErrorDomain
        code:PVXHLSLocalizerNetworkFailure
        userInfo:@{NSLocalizedDescriptionKey: @"KEY redirect refused"}];
    completionHandler(nil);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response
    completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    NSInteger status = [(NSHTTPURLResponse *)response statusCode];
    BOOL ok = status == 200 && (response.expectedContentLength == 16 ||
                               response.expectedContentLength == NSURLResponseUnknownLength);
    if (!ok) {
        self.failure = [NSError errorWithDomain:PVXHLSLocalizerErrorDomain
            code:PVXHLSLocalizerInvalidKey userInfo:@{NSLocalizedDescriptionKey:
                @"KEY requires HTTP 200 and exactly 16 bytes"}];
    }
    completionHandler(ok ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveData:(NSData *)data {
    if (data.length > 16 - self.data.length) {
        self.failure = [NSError errorWithDomain:PVXHLSLocalizerErrorDomain
            code:PVXHLSLocalizerInvalidKey userInfo:@{NSLocalizedDescriptionKey:
                @"KEY transfer exceeds 16 bytes"}];
        [task cancel];
    } else {
        [self.data appendData:data];
    }
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
    [self.condition lock];
    if (!self.failure) self.failure = error;
    self.finished = YES;
    [self.condition signal];
    [self.condition unlock];
}
@end

@interface PVXHLSClosure : NSObject
@property(nonatomic, copy) NSString *root;
@property(nonatomic, copy) NSDictionary *task;
@property(nonatomic, copy) PVXHLSKeyFetchBlock fetch;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *index;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSURL *> *completed;
@property(nonatomic, strong) NSMutableSet *active;
@property(nonatomic, strong) NSMutableArray<NSString *> *generated;
@property(nonatomic, copy) NSString *token;
@property(nonatomic, strong) NSMutableDictionary *metrics;
@property(nonatomic, strong) NSMutableSet *keys;
@property(nonatomic, copy) NSDictionary *summary;
@property(nonatomic) double mediaDuration;
@property(nonatomic) NSUInteger mediaCount;
- (NSURL *)build:(NSError **)error;
@end

@implementation PVXHLSClosure
- (NSString *)safeFile:(NSString *)path error:(NSError **)error {
    char resolved[PATH_MAX];
    struct stat st;
    if (!path.length || !realpath(path.fileSystemRepresentation, resolved)) {
        return PVXFail(error, PVXHLSLocalizerMissingResource, @"Resource does not exist", path);
    }
    NSString *real = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:resolved
        length:strlen(resolved)];
    NSString *prefix = [self.root stringByAppendingString:@"/"];
    if (![real hasPrefix:prefix] || lstat(path.fileSystemRepresentation, &st) ||
        !S_ISREG(st.st_mode) || S_ISLNK(st.st_mode) || st.st_size <= 0) {
        return PVXFail(error, PVXHLSLocalizerUnsafePath,
            @"Resource must be a nonempty regular file within the task cache (no symlink)", path);
    }
    // Reject symlink ancestors too, even when they point back inside the root.
    NSString *relative = [path stringByStandardizingPath];
    while (relative.length > self.root.length) {
        if (lstat(relative.fileSystemRepresentation, &st) || S_ISLNK(st.st_mode)) {
            return PVXFail(error, PVXHLSLocalizerUnsafePath, @"Symlink in resource path", path);
        }
        relative = relative.stringByDeletingLastPathComponent;
    }
    return real;
}

- (NSData *)manifestData:(NSString *)path error:(NSError **)error {
    NSString *safe = [self safeFile:path error:error];
    if (!safe) return nil;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:safe error:error];
    if ([attrs[NSFileSize] unsignedLongLongValue] > PVXManifestLimit) {
        return PVXFail(error, PVXHLSLocalizerInvalidInput, @"Manifest exceeds 2 MiB", path);
    }
    return [NSData dataWithContentsOfFile:safe options:0 error:error];
}

- (BOOL)scan:(NSError **)error {
    self.index = [NSMutableDictionary dictionary];
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager]
        enumeratorAtURL:[NSURL fileURLWithPath:self.root] includingPropertiesForKeys:nil
        options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
    for (NSURL *url in enumerator) {
        struct stat st;
        if (lstat(url.path.fileSystemRepresentation, &st)) continue;
        if (S_ISLNK(st.st_mode)) { [enumerator skipDescendants]; continue; }
        if (![url.pathExtension isEqual:@"plist"] || !S_ISREG(st.st_mode)) continue;
        if ((unsigned long long)st.st_size > PVXManifestLimit || ![self safeFile:url.path error:NULL]) continue;
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfURL:url];
        if (![meta isKindOfClass:NSDictionary.class]) continue;
        NSString *path = url.path.stringByDeletingPathExtension;
        // Invalid targets remain indexed so resolution reports an unsafe path, not a guess.
        for (NSString *field in @[@"responseURL", @"url", @"source"]) {
            NSString *remote = meta[field];
            if (![remote isKindOfClass:NSString.class] || !PVXRemote([NSURL URLWithString:remote])) continue;
            NSMutableArray *rows = self.index[remote];
            if (!rows) self.index[remote] = rows = [NSMutableArray array];
            NSDictionary *row = @{@"path": path, @"meta": meta};
            if (![rows containsObject:row]) [rows addObject:row];
        }
    }
    return YES;
}

// Evidence describes bytes stored, not a desired request. Only an exact match
// proves a sliced resource. Unknown evidence is rejected instead of double-seeking.
- (NSString *)evidence:(NSDictionary *)meta {
    id headers = meta[@"responseHeaders"];
    if ([headers isKindOfClass:NSDictionary.class]) {
        for (NSString *key in headers) {
            if ([key.lowercaseString isEqual:@"content-range"]) return headers[key];
        }
    }
    return meta[@"Content-Range"] ?: meta[@"contentRange"] ?: meta[@"range"];
}

- (NSString *)localRange:(NSString *)range offset:(unsigned long long)offset
                   path:(NSString *)path meta:(NSDictionary *)meta error:(NSError **)error {
    NSArray *parts = [range componentsSeparatedByString:@"@"];
    unsigned long long length = 0;
    if (parts.count > 2 || !PVXUInt(parts[0], &length) || !length ||
        offset > ULLONG_MAX - length) {
        return PVXFail(error, PVXHLSLocalizerInvalidRange, @"Invalid or overflowing byte range", range);
    }
    unsigned long long size = [[[NSFileManager defaultManager] attributesOfItemAtPath:path
        error:error][NSFileSize] unsignedLongLongValue];
    NSString *evidence = [self evidence:meta];
    if (evidence) {
        if (![evidence isKindOfClass:NSString.class]) {
            return PVXFail(error, PVXHLSLocalizerInvalidRange, @"Malformed range evidence", path);
        }
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
            @"^bytes[ =]([0-9]+)-([0-9]+)(?:/[0-9*]+)?$" options:0 error:NULL];
        NSTextCheckingResult *match = [re firstMatchInString:evidence options:0
            range:NSMakeRange(0, evidence.length)];
        unsigned long long start = 0, end = 0;
        if (!match || !PVXUInt([evidence substringWithRange:[match rangeAtIndex:1]], &start) ||
            !PVXUInt([evidence substringWithRange:[match rangeAtIndex:2]], &end) ||
            end < start || start != offset || end - start != length - 1 || size != length) {
            return PVXFail(error, PVXHLSLocalizerInvalidRange,
                @"Cached Content-Range does not exactly match requested slice", path);
        }
        return [NSString stringWithFormat:@"%llu@0", length];
    }
    if (size >= offset + length) return [NSString stringWithFormat:@"%llu@%llu", length, offset];
    if (size == length) return [NSString stringWithFormat:@"%llu@0", length];
    return PVXFail(error, PVXHLSLocalizerInvalidRange,
        @"Cache is neither complete resource nor exact slice; range is ambiguous", path);
}

- (NSDictionary *)resource:(NSString *)uri range:(NSString *)range
                   offset:(unsigned long long)offset error:(NSError **)error {
    NSURL *url = [NSURL URLWithString:uri];
    NSArray *rows = url.isFileURL ? @[@{@"path": url.path, @"meta": @{}}] : self.index[uri];
    NSMutableArray *matches = [NSMutableArray array];
    NSError *lastError = nil;
    for (NSDictionary *row in rows) {
        NSString *path = [self safeFile:row[@"path"] error:&lastError];
        if (!path) continue;
        NSString *localRange = nil;
        if (range) {
            localRange = [self localRange:range offset:offset path:path meta:row[@"meta"] error:&lastError];
            if (!localRange) continue;
        } else if ([self evidence:row[@"meta"]]) {
            PVXFail(&lastError, PVXHLSLocalizerInvalidRange,
                @"Sliced cache cannot stand in for an unbounded resource", uri);
            continue;
        }
        NSDictionary *match = @{@"path": path, @"meta": row[@"meta"],
            @"uri": [NSURL fileURLWithPath:path].absoluteString, @"range": localRange ?: @""};
        if (![matches containsObject:match]) [matches addObject:match];
    }
    if (matches.count == 1) return matches.firstObject;
    if (matches.count > 1) return PVXFail(error, PVXHLSLocalizerAmbiguousResource,
        @"Multiple cache files match the exact resource URL/range", uri);
    if (lastError) { if (error) *error = lastError; return nil; }
    return PVXFail(error, PVXHLSLocalizerMissingResource, @"No exact local resource mapping", uri);
}

- (NSURLRequest *)keyRequest:(NSURL *)url source:(NSURL *)source {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    BOOL sameOrigin = [url.scheme.lowercaseString isEqual:source.scheme.lowercaseString] &&
        [url.host.lowercaseString isEqual:source.host.lowercaseString] &&
        [(url.port ?: @([url.scheme isEqual:@"https"] ? 443 : 80))
            isEqual:(source.port ?: @([source.scheme isEqual:@"https"] ? 443 : 80))];
    NSDictionary *headers = self.task[@"headers"];
    if ([headers isKindOfClass:NSDictionary.class]) {
        for (NSString *name in headers) {
            if (![name isKindOfClass:NSString.class]) continue;
            NSString *lower = name.lowercaseString;
            if ([@[@"cookie", @"host", @"range", @"connection", @"content-length",
                   @"proxy-authorization"] containsObject:lower]) continue;
            if (!sameOrigin && ![@[@"user-agent", @"accept", @"accept-language"] containsObject:lower]) continue;
            NSString *value = headers[name];
            if (![value isKindOfClass:NSString.class] ||
                [name rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound ||
                [value rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) continue;
            [request setValue:value forHTTPHeaderField:name];
        }
    }
    NSMutableArray *cookies = [NSMutableArray array];
    id supplied = self.task[@"cookies"];
    if ([supplied isKindOfClass:NSArray.class]) {
        for (id item in supplied) {
            NSHTTPCookie *cookie = [item isKindOfClass:NSHTTPCookie.class] ? item :
                ([item isKindOfClass:NSDictionary.class] ? [NSHTTPCookie cookieWithProperties:item] : nil);
            if (!cookie) continue;
            NSString *domain = cookie.domain.lowercaseString;
            NSString *host = url.host.lowercaseString;
            BOOL matches = [host isEqual:domain];
            if ([domain hasPrefix:@"."]) {
                matches = [host isEqual:[domain substringFromIndex:1]] || [host hasSuffix:domain];
            }
            NSString *path = cookie.path.length ? cookie.path : @"/";
            NSString *requestPath = url.path.length ? url.path : @"/";
            BOOL pathMatches = [requestPath isEqual:path] ||
                ([requestPath hasPrefix:path] && ([path hasSuffix:@"/"] ||
                 (requestPath.length > path.length && [requestPath characterAtIndex:path.length] == '/')));
            if (matches && pathMatches && (!cookie.secure || [url.scheme.lowercaseString isEqual:@"https"]) &&
                (!cookie.expiresDate || [cookie.expiresDate timeIntervalSinceNow] > 0)) {
                [cookies addObject:cookie];
            }
        }
    }
    NSDictionary *cookieHeaders = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies];
    for (NSString *name in cookieHeaders) [request setValue:cookieHeaders[name] forHTTPHeaderField:name];
    request.HTTPShouldHandleCookies = NO;
    return request;
}

- (NSData *)downloadKey:(NSURLRequest *)request error:(NSError **)error {
    if (NSThread.isMainThread) return PVXFail(error, PVXHLSLocalizerNetworkFailure,
        @"KEY networking must not block the main thread", request.URL.absoluteString);
    if (self.fetch) return self.fetch(request, error);
    PVXKeyTransfer *transfer = [PVXKeyTransfer new];
    transfer.condition = [NSCondition new];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.HTTPShouldSetCookies = NO;
    config.HTTPCookieStorage = nil;
    config.URLCache = nil;
    config.URLCredentialStorage = nil;
    config.timeoutIntervalForRequest = 15;
    config.timeoutIntervalForResource = 20;
    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 1;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:transfer delegateQueue:queue];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:21];
    [transfer.condition lock];
    [task resume];
    while (!transfer.finished && [transfer.condition waitUntilDate:deadline]) {}
    BOOL finished = transfer.finished;
    NSData *data = finished && !transfer.failure ? [transfer.data copy] : nil;
    NSError *failure = finished ? transfer.failure : nil;
    [transfer.condition unlock];
    [session invalidateAndCancel];
    if (!data) return PVXFail(error, PVXHLSLocalizerNetworkFailure,
        failure.localizedDescription ?: @"KEY download timed out", request.URL.absoluteString);
    return data;
}

- (NSDictionary *)key:(NSString *)uri source:(NSURL *)source error:(NSError **)error {
    NSError *localError = nil;
    NSDictionary *row = [self resource:uri range:nil offset:0 error:&localError];
    if (!row) {
        if (localError.code != PVXHLSLocalizerMissingResource || !PVXRemote(source) ||
            !PVXRemote([NSURL URLWithString:uri])) {
            if (error) *error = localError;
            return nil;
        }
        NSData *data = [self downloadKey:[self keyRequest:[NSURL URLWithString:uri] source:source] error:error];
        if (!data) return nil;
        if (data.length != 16) return PVXFail(error, PVXHLSLocalizerInvalidKey,
            @"AES-128 KEY must contain exactly 16 bytes", uri);
        NSString *path = [self.root stringByAppendingPathComponent:
            [NSString stringWithFormat:@"pvx-key-%@.bin", NSUUID.UUID.UUIDString]];
        if (![data writeToFile:path options:NSDataWritingAtomic error:error]) return nil;
        chmod(path.fileSystemRepresentation, 0600);
        [self.generated addObject:path];
        NSDictionary *metadata = @{@"responseURL": uri};
        NSString *sidecar = [path stringByAppendingString:@".plist"];
        NSData *plist = [NSPropertyListSerialization dataWithPropertyList:metadata
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
        if (!plist || ![plist writeToFile:sidecar options:NSDataWritingAtomic error:error]) return nil;
        chmod(sidecar.fileSystemRepresentation, 0600);
        [self.generated addObject:sidecar];
        row = @{@"path": path, @"meta": metadata, @"uri": [NSURL fileURLWithPath:path].absoluteString};
        self.index[uri] = [NSMutableArray arrayWithObject:row];
    }
    unsigned long long size = [[[NSFileManager defaultManager] attributesOfItemAtPath:row[@"path"]
        error:error][NSFileSize] unsignedLongLongValue];
    if (size != 16) return PVXFail(error, PVXHLSLocalizerInvalidKey,
        @"Cached AES-128 KEY is not exactly 16 bytes", row[@"path"]);
    return row;
}

- (NSURL *)writePlaylist:(NSString *)text error:(NSError **)error {
    NSString *path = [self.root stringByAppendingPathComponent:
        [NSString stringWithFormat:@"pvx-recovery-%@-%lu.m3u8", self.token,
            (unsigned long)self.generated.count]];
    if (![[text dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path
        options:NSDataWritingAtomic error:error]) return nil;
    chmod(path.fileSystemRepresentation, 0600);
    [self.generated addObject:path];
    return [NSURL fileURLWithPath:path];
}

- (NSURL *)resolve:(NSString *)raw base:(NSURL *)base error:(NSError **)error {
    if (![raw isKindOfClass:NSString.class] || !raw.length || !base) {
        return PVXFail(error, PVXHLSLocalizerInvalidInput, @"Missing resource URI/base URL", raw);
    }
    NSURL *url = [NSURL URLWithString:raw relativeToURL:base].absoluteURL;
    if (!(url.isFileURL || PVXRemote(url)) || url.fragment.length) {
        return PVXFail(error, PVXHLSLocalizerInvalidInput, @"Unsupported resource URL", raw);
    }
    return url;
}

- (BOOL)parseRange:(NSString *)range previousURI:(NSString *)previousURI
      previousEnd:(unsigned long long)previousEnd uri:(NSString *)uri
           offset:(unsigned long long *)offset length:(unsigned long long *)length
            error:(NSError **)error {
    NSArray *parts = [range componentsSeparatedByString:@"@"];
    if (parts.count > 2 || !PVXUInt(parts[0], length) || !*length ||
        (parts.count == 2 && !PVXUInt(parts[1], offset)) ||
        (parts.count == 1 && ![previousURI isEqual:uri])) {
        PVXFail(error, PVXHLSLocalizerInvalidRange, @"Invalid/implicit range without same preceding URI", uri);
        return NO;
    }
    if (parts.count == 1) *offset = previousEnd;
    if (*offset > ULLONG_MAX - *length) {
        PVXFail(error, PVXHLSLocalizerInvalidRange, @"Byte range overflows", uri);
        return NO;
    }
    return YES;
}

- (NSString *)legacyText:(NSString *)text base:(NSURL *)base error:(NSError **)error {
    if (![self.task[@"hlsLegacyRandomOrderVerified"] boolValue]) return text;
    if (!base.isFileURL || ![base.lastPathComponent isEqual:@"local-0.m3u8"]) {
        return PVXFail(error, PVXHLSLocalizerUnsupportedManifest,
            @"Legacy reorder requires verified local-0.m3u8 provenance", base.absoluteString);
    }
    PVXHLSManifest *manifest = [PVXHLSManifest parseText:text baseURL:base error:error];
    if (!manifest || manifest.master || !manifest.segments.count) return nil;
    NSMutableArray *ordered = [NSMutableArray array];
    NSMutableSet *numbers = [NSMutableSet set];
    NSString *template = nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
        @"^(.*?)([0-9]+)([^0-9/]*)$" options:0 error:NULL];
    for (PVXHLSSegment *segment in manifest.segments) {
        if (segment.key || segment.map || segment.byterange || segment.discontinuity || segment.gap) {
            return PVXFail(error, PVXHLSLocalizerUnsupportedManifest,
                @"Legacy reorder forbids KEY/MAP/ranges/discontinuities/gaps", segment.URI);
        }
        NSString *local = [self safeFile:[NSURL URLWithString:segment.URI].path error:error];
        if (!local) return nil;
        NSString *sidecar = [self safeFile:[local stringByAppendingString:@".plist"] error:error];
        if (!sidecar) return nil;
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:sidecar];
        NSString *response = meta[@"responseURL"];
        NSURL *remote = [response isKindOfClass:NSString.class] ? [NSURL URLWithString:response] : nil;
        NSString *stem = remote.path.lastPathComponent;
        NSTextCheckingResult *match = [re firstMatchInString:stem ?: @"" options:0
            range:NSMakeRange(0, stem.length)];
        unsigned long long number = 0;
        double duration = [meta[@"duration"] doubleValue];
        if (!PVXRemote(remote) || !match || remote.query.length || !isfinite(duration) || duration <= 0 ||
            fabs(duration - segment.duration) > 0.000001 ||
            !PVXUInt([stem substringWithRange:[match rangeAtIndex:2]], &number) || number > LLONG_MAX) {
            return PVXFail(error, PVXHLSLocalizerUnsupportedManifest,
                @"Legacy order needs responseURL suffix evidence and matching real sidecar duration", local);
        }
        NSString *shape = [response stringByReplacingOccurrencesOfString:stem withString:
            [stem stringByReplacingCharactersInRange:[match rangeAtIndex:2] withString:@"{sequence}"]];
        if ((template && ![template isEqual:shape]) || [numbers containsObject:@(number)]) {
            return PVXFail(error, PVXHLSLocalizerAmbiguousResource,
                @"Legacy numeric mapping is duplicate or spans URL templates", response);
        }
        template = shape;
        [numbers addObject:@(number)];
        [ordered addObject:@{@"number": @(number), @"segment": segment}];
    }
    [ordered sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"number"] compare:b[@"number"]];
    }];
    unsigned long long minimum = [ordered.firstObject[@"number"] unsignedLongLongValue];
    unsigned long long maximum = [ordered.lastObject[@"number"] unsignedLongLongValue];
    if (maximum - minimum != ordered.count - 1) return PVXFail(error,
        PVXHLSLocalizerMissingResource, @"Legacy responseURL sequence is not complete and contiguous", nil);
    NSMutableArray *segments = [NSMutableArray array];
    for (NSDictionary *row in ordered) [segments addObject:row[@"segment"]];
    return [manifest localizedTextWithSegments:segments localURLs:@{}];
}

- (NSString *)mediaText:(NSString *)text base:(NSURL *)base error:(NSError **)error {
    NSMutableArray *out = [NSMutableArray array];
    NSString *pendingInf = nil, *pendingRange = nil, *previousURI = nil, *previousMapURI = nil;
    unsigned long long previousEnd = 0, previousMapEnd = 0, sequence = 0;
    NSUInteger count = 0;
    double totalDuration = 0;
    BOOL endList = NO, encrypted = NO, explicitIV = NO;
    NSSet *safeTags = [NSSet setWithArray:@[@"#EXTM3U", @"#EXT-X-VERSION",
        @"#EXT-X-TARGETDURATION", @"#EXT-X-PLAYLIST-TYPE", @"#EXT-X-DISCONTINUITY",
        @"#EXT-X-DISCONTINUITY-SEQUENCE", @"#EXT-X-PROGRAM-DATE-TIME",
        @"#EXT-X-INDEPENDENT-SEGMENTS", @"#EXT-X-I-FRAMES-ONLY", @"#EXT-X-BITRATE"]];
    NSString *tag= @"";
    for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        NSString *line = PVXTrim(raw);
        if (!line.length) continue;
        tag = [[line componentsSeparatedByString:@":"] firstObject];
        // Original PyVideo writes this non-resource metadata tag. Remove it
        // rather than handing an application token to the media demuxer.
        if ([tag isEqual:@"#EXT-X-TOKEN"]) continue;
        if ([line hasPrefix:@"#EXT"] && ![line containsString:@":"] &&
            ![@[@"#EXTM3U", @"#EXT-X-ENDLIST", @"#EXT-X-DISCONTINUITY",
                @"#EXT-X-INDEPENDENT-SEGMENTS", @"#EXT-X-I-FRAMES-ONLY"] containsObject:line]) {
            return PVXFail(error, PVXHLSLocalizerInvalidInput, @"Missing tag value", line);
        }
        if ([tag isEqual:@"#EXTINF"]) {
            if (pendingInf) return PVXFail(error, PVXHLSLocalizerInvalidInput, @"EXTINF without segment", line);
            NSString *number = [[[line substringFromIndex:8] componentsSeparatedByString:@","] firstObject];
            NSScanner *scanner = [NSScanner scannerWithString:number];
            double duration = 0;
            if (![scanner scanDouble:&duration] || !scanner.isAtEnd || !isfinite(duration) || duration <= 0) {
                return PVXFail(error, PVXHLSLocalizerInvalidInput, @"Missing or invalid real EXTINF duration", line);
            }
            totalDuration += duration;
            if (!isfinite(totalDuration)) return PVXFail(error, PVXHLSLocalizerInvalidInput,
                @"EXTINF duration total overflows", nil);
            pendingInf = line;
            continue;
        }
        if ([tag isEqual:@"#EXT-X-BYTERANGE"]) {
            if (pendingRange) return PVXFail(error, PVXHLSLocalizerInvalidRange, @"Duplicate range", line);
            pendingRange = [line substringFromIndex:17];
            continue;
        }
        if ([tag isEqual:@"#EXT-X-KEY"]) {
            NSDictionary *attrs = PVXAttributes([line substringFromIndex:11]);
            NSString *method = attrs[@"METHOD"];
            if ([method isEqual:@"NONE"] && attrs.count == 1) {
                encrypted = NO;
                explicitIV = NO;
                [out addObject:line];
                continue;
            }
            if (![method isEqual:@"AES-128"] ||
                (attrs[@"KEYFORMAT"] && ![attrs[@"KEYFORMAT"] isEqual:@"identity"]) ||
                (attrs[@"KEYFORMATVERSIONS"] && ![attrs[@"KEYFORMATVERSIONS"] isEqual:@"1"])) {
                return PVXFail(error, PVXHLSLocalizerUnsupportedManifest,
                    @"Only identity AES-128 or METHOD=NONE is supported (no DRM)", line);
            }
            NSString *iv = attrs[@"IV"];
            for (NSString *name in attrs) {
                if (![@[@"METHOD", @"URI", @"IV", @"KEYFORMAT", @"KEYFORMATVERSIONS"] containsObject:name]) {
                    return PVXFail(error, PVXHLSLocalizerUnsupportedManifest, @"Unknown KEY attribute", name);
                }
            }
            if (iv && ([iv rangeOfString:@"^0[xX][0-9a-fA-F]{1,32}$"
                options:NSRegularExpressionSearch].location == NSNotFound)) {
                return PVXFail(error, PVXHLSLocalizerInvalidKey, @"Invalid 128-bit IV", iv);
            }
            NSURL *uri = [self resolve:attrs[@"URI"] base:base error:error];
            if (!uri) return nil;
            NSDictionary *key = [self key:uri.absoluteString source:base error:error];
            if (!key) return nil;
            [self.keys addObject:key[@"uri"]];
            NSString *rewritten = PVXReplaceURI(line, key[@"uri"]);
            if (!rewritten) return PVXFail(error, PVXHLSLocalizerInvalidInput, @"KEY URI must be quoted", line);
            [out addObject:rewritten];
            encrypted = YES;
            explicitIV = iv.length > 0;
            continue;
        }
        if ([tag isEqual:@"#EXT-X-MAP"]) {
            NSDictionary *attrs = PVXAttributes([line substringFromIndex:11]);
            if (!attrs || (encrypted && !explicitIV)) return PVXFail(error,
                PVXHLSLocalizerInvalidKey, @"Encrypted MAP requires an explicit IV", line);
            NSURL *uri = [self resolve:attrs[@"URI"] base:base error:error];
            if (!uri) return nil;
            NSString *range = attrs[@"BYTERANGE"];
            for (NSString *name in attrs) {
                if (![@[@"URI", @"BYTERANGE"] containsObject:name]) return PVXFail(error,
                    PVXHLSLocalizerUnsupportedManifest, @"Unknown MAP attribute", name);
            }
            if (range && ![line containsString:[NSString stringWithFormat:@"BYTERANGE=\"%@\"", range]]) {
                return PVXFail(error, PVXHLSLocalizerInvalidRange, @"MAP BYTERANGE must be quoted", line);
            }
            unsigned long long offset = 0, length = 0;
            if (range && ![self parseRange:range previousURI:previousMapURI
                previousEnd:previousMapEnd uri:uri.absoluteString offset:&offset length:&length error:error]) return nil;
            NSDictionary *row = [self resource:uri.absoluteString range:range offset:offset error:error];
            if (!row) return nil;
            NSString *rewritten = PVXReplaceURI(line, row[@"uri"]);
            if (!rewritten) return PVXFail(error, PVXHLSLocalizerInvalidInput, @"MAP URI must be quoted", line);
            if (range) {
                rewritten = [rewritten stringByReplacingOccurrencesOfString:
                    [NSString stringWithFormat:@"BYTERANGE=\"%@\"", range]
                    withString:[NSString stringWithFormat:@"BYTERANGE=\"%@\"", row[@"range"]]];
            }
            [out addObject:rewritten];
            previousMapURI = uri.absoluteString;
            previousMapEnd = offset + length;
            continue;
        }
        if ([tag isEqual:@"#EXT-X-MEDIA-SEQUENCE"]) {
            if (count || !PVXUInt([line substringFromIndex:22], &sequence) || sequence > LLONG_MAX) {
                return PVXFail(error, PVXHLSLocalizerInvalidInput, @"Invalid media sequence", line);
            }
            [out addObject:line];
            continue;
        }
        if ([line isEqual:@"#EXT-X-ENDLIST"]) { endList = YES; continue; }
        if ([line hasPrefix:@"#"]) {
            if ([line hasPrefix:@"#EXT"] && ![safeTags containsObject:tag]) {
                return PVXFail(error, PVXHLSLocalizerUnsupportedManifest,
                    @"Unsupported tag; cannot prove a complete offline VOD closure", line);
            }
            if ([tag isEqual:@"#EXT-X-PLAYLIST-TYPE"] && ![line isEqual:@"#EXT-X-PLAYLIST-TYPE:VOD"]) {
                return PVXFail(error, PVXHLSLocalizerUnsupportedManifest, @"Only VOD playlists are supported", line);
            }
            [out addObject:line];
            continue;
        }
        if (!pendingInf || endList || sequence == ULLONG_MAX) return PVXFail(error,
            PVXHLSLocalizerInvalidInput, @"Segment lacks EXTINF or follows ENDLIST", line);
        NSURL *uri = [self resolve:line base:base error:error];
        if (!uri) return nil;
        unsigned long long offset = 0, length = 0;
        if (pendingRange && ![self parseRange:pendingRange previousURI:previousURI
            previousEnd:previousEnd uri:uri.absoluteString offset:&offset length:&length error:error]) return nil;
        NSDictionary *row = [self resource:uri.absoluteString range:pendingRange offset:offset error:error];
        if (!row) return nil;
        [out addObject:pendingInf];
        if (pendingRange) [out addObject:[@"#EXT-X-BYTERANGE:" stringByAppendingString:row[@"range"]]];
        [out addObject:row[@"uri"]];
        previousURI = pendingRange ? uri.absoluteString : nil;
        previousEnd = offset + length;
        pendingInf = nil;
        pendingRange = nil;
        sequence++;
        count++;
    }
    if (!endList || !count || pendingInf || pendingRange) return PVXFail(error,
        PVXHLSLocalizerUnsupportedManifest, @"Incomplete/empty/live media playlist", base.absoluteString);
    self.mediaDuration = totalDuration;
    self.mediaCount = count;
    [out addObject:@"#EXT-X-ENDLIST\n"];
    return [out componentsJoinedByString:@"\n"];
}

- (NSURL *)playlist:(NSString *)text base:(NSURL *)base depth:(NSUInteger)depth error:(NSError **)error {
    if (depth > 8 || [self.active containsObject:base.absoluteString]) return PVXFail(error,
        PVXHLSLocalizerUnsupportedManifest, @"Master playlist cycle or depth exceeds 8", base.absoluteString);
    if (self.completed[base.absoluteString]) return self.completed[base.absoluteString];
    if (![text hasPrefix:@"#EXTM3U"]) return PVXFail(error, PVXHLSLocalizerInvalidInput,
        @"Manifest must be UTF-8 EXTM3U", base.absoluteString);
    [self.active addObject:base.absoluteString];
    NSURL *output = nil;
    if ([text containsString:@"#EXT-X-STREAM-INF:"]) {
        PVXHLSManifest *master = [PVXHLSManifest parseText:text baseURL:base error:error];
        PVXHLSVariant *variant = master.bestVariant;
        if (!master || !variant) return PVXFail(error, PVXHLSLocalizerUnsupportedManifest,
            @"Master has no usable variant", base.absoluteString);
        PVXHLSEntry *audio = variant.audioGroup.length ? [master defaultAudioForGroup:variant.audioGroup] : nil;
        if (variant.audioGroup.length && !audio) {
            // In-band audio groups have no URI; unsupported rather than silently
            // claiming an external audio closure which was never established.
            return PVXFail(error, PVXHLSLocalizerMissingResource,
                @"Selected external AUDIO group has no cached rendition", variant.audioGroup);
        }
        NSMutableArray *lines = [NSMutableArray arrayWithObject:@"#EXTM3U"];
        NSDictionary *videoMetrics = nil, *audioMetrics = nil;
        NSString *stream = nil;
        for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
            NSString *line = PVXTrim(raw);
            if ([line hasPrefix:@"#EXT-X-SESSION-KEY:"] || [line hasPrefix:@"#EXT-X-SESSION-DATA:"] ||
                [line hasPrefix:@"#EXT-X-CONTENT-STEERING:"] || [line hasPrefix:@"#EXTINF:"]) {
                return PVXFail(error, PVXHLSLocalizerUnsupportedManifest,
                    @"Unsupported master metadata or mixed master/media", line);
            }
            if ([line hasPrefix:@"#EXT-X-VERSION:"] || [line isEqual:@"#EXT-X-INDEPENDENT-SEGMENTS"]) {
                [lines addObject:line];
            }
            if ([line hasPrefix:@"#EXT-X-MEDIA:"]) {
                NSDictionary *attrs = PVXAttributes([line substringFromIndex:13]);
                if ([attrs[@"TYPE"] isEqual:@"AUDIO"] && audio &&
                    [attrs[@"GROUP-ID"] isEqual:audio.groupID] && [attrs[@"NAME"] isEqual:audio.name]) {
                    NSURL *child = [self child:audio.URI depth:depth + 1 error:error];
                    if (!child) return nil;
                    audioMetrics = self.metrics[child.absoluteString];
                    NSString *rewritten = PVXReplaceURI(line, child.absoluteString);
                    if (!rewritten) return PVXFail(error, PVXHLSLocalizerInvalidInput, @"AUDIO URI must be quoted", line);
                    [lines addObject:rewritten];
                }
            }
            if ([line hasPrefix:@"#EXT-X-STREAM-INF:"]) { stream = line; continue; }
            if (stream && line.length && ![line hasPrefix:@"#"]) {
                NSURL *uri = [self resolve:line base:base error:error];
                if (!uri) return nil;
                if ([uri.absoluteString isEqual:variant.URI]) {
                    NSDictionary *attrs = PVXAttributes([stream substringFromIndex:18]);
                    if (attrs[@"SUBTITLES"] || attrs[@"VIDEO"] || attrs[@"CLOSED-CAPTIONS"]) {
                        return PVXFail(error, PVXHLSLocalizerUnsupportedManifest,
                            @"External subtitle/video/caption groups are not supported", stream);
                    }
                    NSURL *child = [self child:variant.URI depth:depth + 1 error:error];
                    if (!child) return nil;
                    videoMetrics = self.metrics[child.absoluteString];
                    [lines addObject:stream];
                    [lines addObject:child.absoluteString];
                }
                stream = nil;
            }
        }
        if (!videoMetrics || (audio && !audioMetrics)) return PVXFail(error,
            PVXHLSLocalizerMissingResource, @"Selected master tracks are incomplete", nil);
        output = [self writePlaylist:[[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] error:error];
        if (output) self.metrics[output.absoluteString] = @{
            @"expectedDuration": videoMetrics[@"expectedDuration"],
            @"requireAudio": @(variant.audioGroup.length > 0 || [videoMetrics[@"requireAudio"] boolValue]),
            @"segmentCount": @([videoMetrics[@"segmentCount"] unsignedIntegerValue] +
                [audioMetrics[@"segmentCount"] unsignedIntegerValue]),
            @"trackCount": @([videoMetrics[@"trackCount"] unsignedIntegerValue] +
                [audioMetrics[@"trackCount"] unsignedIntegerValue])};
    } else {
        NSString *localized = [self mediaText:text base:base error:error];
        if (localized) output = [self writePlaylist:localized error:error];
        if (output) self.metrics[output.absoluteString] = @{
            @"expectedDuration": @(self.mediaDuration), @"requireAudio": @NO,
            @"segmentCount": @(self.mediaCount), @"trackCount": @1};
    }
    [self.active removeObject:base.absoluteString];
    if (output) self.completed[base.absoluteString] = output;
    return output;
}

- (NSURL *)child:(NSString *)uri depth:(NSUInteger)depth error:(NSError **)error {
    NSDictionary *row = [self resource:uri range:nil offset:0 error:error];
    if (!row) return nil;
    NSData *data = [self manifestData:row[@"path"] error:error];
    if (!data) return nil;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) return PVXFail(error, PVXHLSLocalizerInvalidInput, @"Child manifest is not UTF-8", uri);
    NSURL *response=[NSURL URLWithString:[row[@"meta"][@"responseURL"] isKindOfClass:NSString.class]?row[@"meta"][@"responseURL"]:@""];
    NSURL *base=PVXRemote(response)?response:[NSURL URLWithString:uri];
    return [self playlist:text base:base depth:depth error:error];
}

- (NSURL *)build:(NSError **)error {
    self.generated = [NSMutableArray array];
    self.completed = [NSMutableDictionary dictionary];
    self.active = [NSMutableSet set];
    self.metrics = [NSMutableDictionary dictionary];
    self.keys = [NSMutableSet set];
    self.token = NSUUID.UUID.UUIDString;
    [self scan:error];
    NSString *sourceString = self.task[@"hlsSourceURL"];
    NSURL *source = [sourceString isKindOfClass:NSString.class] ? [NSURL URLWithString:sourceString] : nil;
    NSArray *sourceRows=source?self.index[source.absoluteString]:nil;
    if(sourceRows.count==1){
        id final=sourceRows.firstObject[@"meta"][@"responseURL"];
        NSURL *response=[final isKindOfClass:NSString.class]?[NSURL URLWithString:final]:nil;
        if(PVXRemote(response))source=response;
    }
    NSString *text = self.task[@"hlsPlaylistText"];
    if (text && (![text isKindOfClass:NSString.class] ||
        [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > PVXManifestLimit || !PVXRemote(source))) {
        return PVXFail(error, PVXHLSLocalizerInvalidInput,
            @"Explicit source text needs a valid source URL and size <= 2 MiB", nil);
    }
    NSString *path = self.task[@"hlsPlaylistPath"];
    if (path && ![path isKindOfClass:NSString.class]) return PVXFail(error,
        PVXHLSLocalizerInvalidInput, @"hlsPlaylistPath must be a string", nil);
    if (!text && !path && source) {
        NSArray *rows = self.index[source.absoluteString];
        if (rows.count > 1) return PVXFail(error, PVXHLSLocalizerAmbiguousResource,
            @"Multiple cached source manifests", source.absoluteString);
        path = rows.firstObject[@"path"];
    }
    if (!text && !path) {
        NSMutableArray *originals = [NSMutableArray array];
        for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.root error:error]) {
            if ([name hasPrefix:@"playlist-"] && [name.pathExtension isEqual:@"txt"]) {
                NSString *candidate = [self.root stringByAppendingPathComponent:name];
                NSData *data = [self manifestData:candidate error:NULL];
                NSString *content = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
                if ([content hasPrefix:@"#EXTM3U"]) [originals addObject:candidate];
            }
        }
        if (originals.count > 1) return PVXFail(error, PVXHLSLocalizerAmbiguousResource,
            @"Multiple source playlists; provide exact hlsPlaylistPath/responseURL", self.root);
        path = originals.firstObject ?: [self.root stringByAppendingPathComponent:@"local-0.m3u8"];
    }
    NSURL *base = source;
    if (!text) {
        if (![path isAbsolutePath]) path = [self.root stringByAppendingPathComponent:path];
        NSData *data = [self manifestData:path error:error];
        if (!data) return nil;
        text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) return PVXFail(error, PVXHLSLocalizerInvalidInput, @"Manifest is not UTF-8", path);
        if ([path.lastPathComponent hasPrefix:@"local-"]) base = [NSURL fileURLWithPath:path];
        else if (!PVXRemote(base)) return PVXFail(error, PVXHLSLocalizerInvalidInput,
            @"Source playlist requires hlsSourceURL for relative URI resolution", path);
    }
    if ([self.task[@"hlsLegacyRandomOrderVerified"] boolValue] && base.isFileURL) {
        text = [self legacyText:text base:base error:error];
        if (!text) return nil;
    }
    NSURL *result = [self playlist:text base:base depth:0 error:error];
    if (result) {
        NSMutableDictionary *summary = [self.metrics[result.absoluteString] mutableCopy];
        summary[@"keyCount"] = @(self.keys.count);
        summary[@"sourceKind"] = base.isFileURL ?
            ([self.task[@"hlsLegacyRandomOrderVerified"] boolValue] ? @"verified-legacy-local" : @"local-playlist") :
            ([text containsString:@"#EXT-X-STREAM-INF:"] ? @"source-master" : @"source-media");
        self.summary = summary;
    }
    if (!result) {
        for (NSString *file in self.generated) [[NSFileManager defaultManager] removeItemAtPath:file error:NULL];
    }
    return result;
}
@end

@interface PVXHLSLocalizer ()
@property(nonatomic, copy, readwrite) NSDictionary *summary;
@end

@implementation PVXHLSLocalizer
- (instancetype)init {
    if ((self = [super init])) _summary = @{};
    return self;
}

- (NSURL *)localizeTask:(NSDictionary *)task rootDirectory:(NSURL *)root error:(NSError **)error {
    self.summary = @{};
    if (error) *error = nil;
    NSString *identifier = [task isKindOfClass:NSDictionary.class] ? task[@"id"] : nil;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"];
    if (![identifier isKindOfClass:NSString.class] || !identifier.length || identifier.length > 128 ||
        [identifier rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound || !root.isFileURL) {
        return PVXFail(error, PVXHLSLocalizerInvalidInput, @"Invalid task id/root directory", nil);
    }
    NSURL *cache = [[root URLByAppendingPathComponent:@"media" isDirectory:YES]
        URLByAppendingPathComponent:[identifier stringByAppendingString:@".hls"] isDirectory:YES];
    return [self localizeTask:task cacheDirectory:cache error:error];
}

- (NSURL *)localizeTask:(NSDictionary *)task cacheDirectory:(NSURL *)cache error:(NSError **)error {
    self.summary = @{};
    if (error) *error = nil;
    char real[PATH_MAX];
    struct stat st;
    if (![task isKindOfClass:NSDictionary.class] || !cache.isFileURL ||
        lstat(cache.path.fileSystemRepresentation, &st) || !S_ISDIR(st.st_mode) ||
        S_ISLNK(st.st_mode) || !realpath(cache.path.fileSystemRepresentation, real)) {
        return PVXFail(error, PVXHLSLocalizerUnsafePath, @"Task cache must be an existing nonsymlink directory", cache.path);
    }
    PVXHLSClosure *closure = [PVXHLSClosure new];
    closure.root = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:real length:strlen(real)];
    closure.task = task;
    closure.fetch = self.keyFetchBlock;
    NSURL *result = [closure build:error];
    if (result) self.summary = closure.summary;
    return result;
}
@end

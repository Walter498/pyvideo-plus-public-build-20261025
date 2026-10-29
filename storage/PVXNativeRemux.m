#import "PVXNativeRemux.h"
#import <AVFoundation/AVFoundation.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>
#import <pthread.h>
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
#import <time.h>
#import "PVXAgentIdentity.h"

// x0/x1 paths; x2 error buffer; x3 size_t; x4 int(void *); x5 opaque.
// Original caller 0x1001a31d0 tests SIGN, not equality to zero.
typedef int (*PVXRemuxFn)(const char *, const char *, char *, size_t, int (*)(void *), void *);
static PVXRemuxFn PVXRemux;
static dispatch_once_t PVXRemuxOnce;
static NSString *PVXRemuxLoadError;
static const int PVXRemuxExit = -1414092869; // AVERROR_EXIT (0xabb6a7bb)

@implementation PVXNativeRemuxCancellation {
    NSLock *_lock;
    BOOL _cancelled;
}
- (instancetype)init { if ((self = [super init])) _lock = [NSLock new]; return self; }
- (void)cancel { [_lock lock]; _cancelled = YES; [_lock unlock]; }
- (BOOL)isCancelled { [_lock lock]; BOOL v = _cancelled; [_lock unlock]; return v; }
@end
static int PVXCancel(void *opaque) {
    return [(__bridge PVXNativeRemuxCancellation *)opaque isCancelled] ? 1 : 0;
}
static BOOL PVXResolveRemux(void) {
    dispatch_once(&PVXRemuxOnce, ^{
        (void)dlerror();
        void *p = dlsym(RTLD_DEFAULT, "PVRemuxHLSWithCancel");
        const char *e = dlerror();
        if (e || !p) {
            PVXRemuxLoadError = e ? [NSString stringWithUTF8String:e] : @"PVRemuxHLSWithCancel 未导出";
            return;
        }
        if (!PVXAgentOwnsExport(p,"PVRemuxHLSWithCancel")) {
            PVXRemuxLoadError = @"PVRemuxHLSWithCancel 不属于当前主镜像";
            return;
        }
        PVXRemux = (PVXRemuxFn)p;
    });
    return PVXRemux != NULL;
}
static pthread_mutex_t *PVXVerifiedSharedMutex(void) {
#if defined(PVX_NATIVE_REMUX_TESTING)
    // Host fake's original caller and adapter share this exact mutex.
    // No bypass of production symbol/owner/result checks.
    extern pthread_mutex_t *PVXNativeRemuxTestSharedMutex(void);
    return PVXNativeRemuxTestSharedMutex();
#else
    // Packaging exposes an alias to the hash-pinned Agent's existing mutex.
    // Resolve by name and verify its image; no slid address in runtime code.
    static pthread_mutex_t *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        (void)dlerror();
        void *p=dlsym(RTLD_DEFAULT,"PVXAgentRemuxMutex");
        const char *error=dlerror();
        if(!error&&PVXAgentOwnsExport(p,"PVXAgentRemuxMutex"))shared=p;
    });
    return shared;
#endif
}
#include "PVXNativeProbe.inc"

// The original Agent has a strict final gate that rejects some valid long
// HLS inputs (for example 60 fps Main-profile 2+ GiB VOD). Keep that native
// path first. Only after its explicit INVALIDDATA result and an independent
// input probe succeeds, use Apple's passthrough exporter on the same private
// local playlist. No transcoding or output publication happens here.
static BOOL PVXAVFoundationExport(NSString *inputPath, NSString *outputPath,
    NSString *preset, PVXNativeRemuxCancellation *cancellation, NSString **failure) {
    if (failure) *failure = nil;
    if (cancellation.isCancelled) { if (failure) *failure = @"AVFoundation fallback 调用前已取消"; return NO; }
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:inputPath]
        options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
    AVAssetExportSession *session=[[AVAssetExportSession alloc]
        initWithAsset:asset presetName:preset];
    if (!session) { if (failure) *failure=[NSString stringWithFormat:@"AVFoundation %@ exporter 不可用",preset]; return NO; }
    session.outputURL=[NSURL fileURLWithPath:outputPath];
    session.outputFileType=AVFileTypeMPEG4;
    session.shouldOptimizeForNetworkUse=NO;
    __block BOOL finished=NO;
    __block AVAssetExportSessionStatus finalStatus=AVAssetExportSessionStatusUnknown;
    __block NSError *finalError=nil;
    [session exportAsynchronouslyWithCompletionHandler:^{
        finalStatus=session.status; finalError=session.error; finished=YES;
    }];
    NSTimeInterval deadline=NSDate.date.timeIntervalSince1970+3600.0;
    while (!finished) {
        if (cancellation.isCancelled) { [session cancelExport]; if (failure) *failure=@"AVFoundation fallback 已取消"; return NO; }
        if (NSDate.date.timeIntervalSince1970>=deadline) { [session cancelExport]; if (failure) *failure=@"AVFoundation fallback 超时"; return NO; }
        struct timespec delay={0,100000000}; nanosleep(&delay,NULL);
    }
    if (finalStatus!=AVAssetExportSessionStatusCompleted) {
        if (failure) *failure=finalError.localizedDescription?:[NSString stringWithFormat:@"AVFoundation fallback 状态 %ld",(long)finalStatus];
        return NO;
    }
    struct stat st={0};
    if (lstat(outputPath.fileSystemRepresentation,&st)||!S_ISREG(st.st_mode)||st.st_size<=0) {
        if (failure) *failure=@"AVFoundation fallback 没有生成有效 MP4";
        return NO;
    }
    return YES;
}

BOOL PVXNativeRemuxHLS(NSString *inputPath, NSString *outputPath, NSString **errorText) {
    return PVXNativeRemuxHLSWithCancellation(inputPath, outputPath, nil, NULL, errorText);
}
BOOL PVXNativeRemuxHLSWithCancellation(NSString *inputPath, NSString *outputPath,
    PVXNativeRemuxCancellation *cancellation, NSDictionary **diagnostic, NSString **errorText) {
    if (errorText) *errorText = nil;
    if (diagnostic) *diagnostic = nil;
    NSString *stage = @"validate", *message = nil;
    NSDictionary *probe=nil;
    int rc = 0;
    BOOL called = NO, locked = NO, success = NO, fallbackAttempted = NO, fallbackSuccess = NO;
    NSString *fallbackError = nil;
    pthread_mutex_t *mutex = NULL;
    const char *input = inputPath.fileSystemRepresentation;
    const char *output = outputPath.fileSystemRepresentation;
    struct stat st = {0};
    // NSString UTF-16 inspection avoids a literal NUL's string-conversion traps.
    NSCharacterSet *nul = [NSCharacterSet characterSetWithRange:NSMakeRange(0, 1)];
    if (!inputPath.length || !outputPath.length || !input || !output ||
        [inputPath rangeOfCharacterFromSet:nul].location != NSNotFound ||
        [outputPath rangeOfCharacterFromSet:nul].location != NSNotFound) {
        message = @"输入或输出路径为空或包含 NUL"; goto done;
    }
    if (lstat(output, &st) == 0 || errno != ENOENT) {
        message = @"输出已存在或无法确认不存在"; goto done;
    }
    if (cancellation.isCancelled) { stage = @"cancel"; message = @"调用前已取消"; goto done; }
    stage = @"resolve";
    if (!PVXResolveRemux()) { message = PVXRemuxLoadError ?: @"原生导出不可用"; goto done; }
    stage = @"lock-contract";
    mutex = PVXVerifiedSharedMutex();
    if (!mutex) {
        message = @"原 Agent 共享互斥未动态导出；无法安全复用，已拒绝调用（非 HLS 解析失败）";
        goto done;
    }
    stage = @"lock-wait";
    for (;;) {
        if (cancellation.isCancelled) { stage = @"cancel"; message = @"等待共享锁时取消"; goto done; }
        int status = pthread_mutex_trylock(mutex);
        if (!status) { locked = YES; break; }
        if (status != EBUSY) { message = [NSString stringWithFormat:@"共享锁失败: %d", status]; goto done; }
        struct timespec delay = {0, 10000000};
        nanosleep(&delay, NULL);
    }
    stage = @"validate";
    if (lstat(output, &st) == 0 || errno != ENOENT) { message = @"等待期间输出已存在"; goto done; }
    if (cancellation.isCancelled) { stage = @"cancel"; message = @"进入原生函数前取消"; goto done; }
    {
        char nativeError[1024] = {0};
        stage = @"native-remux";
        called = YES;
        rc = PVXRemux(input, output, nativeError, sizeof(nativeError), PVXCancel, (__bridge void *)cancellation);
        nativeError[sizeof(nativeError) - 1] = '\0';
        NSString *detail = nativeError[0] ? [NSString stringWithUTF8String:nativeError] : nil;
        if (rc == PVXRemuxExit || cancellation.isCancelled) {
            stage = @"cancel"; message = detail ?: @"原生封装已取消"; goto done;
        }
        if (rc < 0) {
            probe=PVXInputProbe(input);
            // Preserve all original Agent checks. AVFoundation is considered
            // only for the Agent's explicit INVALIDDATA gate after input
            // probing has already confirmed a readable media stream.
            BOOL probeOK=[probe[@"available"] boolValue]&&
                [probe[@"openReturn"] intValue]==0&&[probe[@"streamInfoReturn"] intValue]==0;
            if (probeOK&&!cancellation.isCancelled) {
                unlink(output); fallbackAttempted=YES; stage=@"avfoundation-fallback";
                fallbackSuccess=PVXAVFoundationExport(inputPath,outputPath,AVAssetExportPresetPassthrough,cancellation,&fallbackError);
                if (!fallbackSuccess&&!cancellation.isCancelled) {
                    unlink(output); NSString *transcodeError=nil;
                    fallbackSuccess=PVXAVFoundationExport(inputPath,outputPath,AVAssetExportPresetHighestQuality,cancellation,&transcodeError);
                    if (!fallbackSuccess&&transcodeError.length) fallbackError=[NSString stringWithFormat:@"%@; 转码回退：%@",fallbackError?:@"passthrough失败",transcodeError];
                }
                if (fallbackSuccess) { success=YES; stage=@"complete"; goto done; }
            }
            message = fallbackError.length ? fallbackError : (detail ?: @"原生封装返回负错误码（内部 open/find/DTS 阶段未知）"); goto done;
        }
    }
    stage = @"output";
    if (lstat(output, &st) || !S_ISREG(st.st_mode) || st.st_size <= 0) {
        message = @"原生返回非负，但输出不存在、非普通文件或为空"; goto done;
    }
    success = YES;
    stage = @"complete";
done:
    // Caller must supply private closure-owned staging paths. Never unlink an
    // earlier output on validation/resolution/lock/pre-call cancellation failure.
    if (called && !success) unlink(output);
    if (locked) pthread_mutex_unlock(mutex);
    if (diagnostic) {
        NSMutableDictionary *d = [@{@"stage": stage, @"nativeCalled": @(called),
            @"success": @(success), @"internalStage": @"unknown",
            @"sharedLockVerified": @(mutex != NULL)} mutableCopy];
        if (called) d[@"nativeReturn"] = @(rc);
        if (fallbackAttempted) { d[@"avfoundationFallbackAttempted"]=@YES; d[@"avfoundationFallbackSuccess"]=@(fallbackSuccess); }
        if (fallbackError.length) d[@"avfoundationFallbackError"]=fallbackError;
        if (probe) d[@"independentProbe"]=probe;
        if (message) d[@"detail"] = message;
        *diagnostic = d;
    }
    if (!success && errorText) *errorText = [NSString stringWithFormat:@"[%@] %@%@", stage,
        message ?: @"原生封装失败", called ? [NSString stringWithFormat:@" (rc=%d)", rc] : @""];
    return success;
}

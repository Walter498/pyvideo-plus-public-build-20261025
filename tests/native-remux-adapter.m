#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>
#import <sys/stat.h>
#import "PVXNativeRemux.h"
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); abort(); } } while(0)
static pthread_mutex_t shared = PTHREAD_MUTEX_INITIALIZER;
static atomic_int calls, active, peak;
static dispatch_semaphore_t entered, releaseNative;
static BOOL denyLock;
pthread_mutex_t *PVXNativeRemuxTestSharedMutex(void) { return denyLock ? NULL : &shared; }
@interface PVXWaitCancellation : PVXNativeRemuxCancellation
- (instancetype)initWithSemaphore:(dispatch_semaphore_t)semaphore;
@end
@implementation PVXWaitCancellation {
    dispatch_semaphore_t _ready;
    atomic_int _queries;
}
- (instancetype)initWithSemaphore:(dispatch_semaphore_t)semaphore {
    if ((self = [super init])) { _ready = semaphore; atomic_init(&_queries, 0); }
    return self;
}
- (BOOL)isCancelled {
    BOOL value = [super isCancelled];
    if (atomic_fetch_add(&_queries, 1) == 1) dispatch_semaphore_signal(_ready);
    return value;
}
@end

// Deliberately NOT a media implementation. Each explicit mode tests one adapter
// branch; output bytes are fake, never evidence of real HLS or MP4 correctness.
__attribute__((visibility("default")))
int PVRemuxHLSWithCancel(const char *input, const char *output, char *error,
                        size_t capacity, int (*cancel)(void *), void *opaque) {
    CHECK(input && output && error && capacity == 1024 && cancel);
    atomic_fetch_add(&calls, 1);
    CHECK(atomic_fetch_add(&active, 1) == 0);
    atomic_store(&peak, 1);
    int rc = 0;
    if (!strcmp(input,"negative")) {
        FILE *f = fopen(output,"wb"); CHECK(f); fputs("partial",f); fclose(f);
        snprintf(error,capacity,"Invalid data found when processing input"); rc = -1094995529;
    } else if (!strcmp(input,"bad-utf8")) {
        memset(error,0xff,capacity); rc = -12;
    } else if (!strcmp(input,"missing")) {
        // Successful native status without creating output must fail validation.
    } else if (!strcmp(input,"symlink")) {
        CHECK(symlink("/dev/null",output) == 0);
    } else if (!strcmp(input,"cancel") || !strcmp(input,"hold")) {
        dispatch_semaphore_signal(entered);
        CHECK(dispatch_semaphore_wait(releaseNative, dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)) == 0);
        if (!strcmp(input,"cancel")) { CHECK(cancel(opaque) != 0); rc = -1414092869; }
        else { FILE *f = fopen(output,"wb"); CHECK(f); fputs("fake",f); fclose(f); }
    } else {
        FILE *f = fopen(output,"wb"); CHECK(f);
        if (strcmp(input,"empty")) fputs("FAKE - not media",f);
        fclose(f);
        if (!strcmp(input,"positive")) rc = 7;
    }
    atomic_fetch_sub(&active,1);
    return rc;
}
int main(void) { @autoreleasepool {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    CHECK([[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL]);
    NSString *out = [dir stringByAppendingPathComponent:@"result.mp4"];
    NSString *error = nil; NSDictionary *d = nil;
    (void)dlsym(RTLD_DEFAULT,"PVXThisSymbolMustNotExist"); // seed stale dlerror
    CHECK(PVXNativeRemuxHLSWithCancellation(@"success",out,nil,&d,&error));
    CHECK(!error && [d[@"stage"] isEqual:@"complete"] && [d[@"nativeReturn"] intValue] == 0);
    CHECK(!PVXNativeRemuxHLSWithCancellation(@"success",out,nil,&d,&error));
    CHECK([d[@"stage"] isEqual:@"validate"]); // preexisting output preserved
    CHECK([[NSFileManager defaultManager] fileExistsAtPath:out]);
    unlink(out.fileSystemRepresentation);
    CHECK(PVXNativeRemuxHLS(@"positive",out,&error)); // nonnegative, not rc==0
    unlink(out.fileSystemRepresentation);
    for (NSString *mode in @[@"negative",@"bad-utf8",@"missing",@"empty",@"symlink"]) {
        CHECK(!PVXNativeRemuxHLSWithCancellation(mode,out,nil,&d,&error));
        CHECK(error.length && [d[@"nativeCalled"] boolValue]);
        CHECK(![[NSFileManager defaultManager] fileExistsAtPath:out]);
        if ([mode isEqual:@"negative"]) {
            CHECK([d[@"stage"] isEqual:@"native-remux"]);
            CHECK([error containsString:@"Invalid data"] && [d[@"internalStage"] isEqual:@"unknown"]);
        }
    }
    PVXNativeRemuxCancellation *token = [PVXNativeRemuxCancellation new]; [token cancel];
    int before = atomic_load(&calls);
    CHECK(!PVXNativeRemuxHLSWithCancellation(@"success",out,token,&d,&error));
    CHECK(atomic_load(&calls) == before && [d[@"stage"] isEqual:@"cancel"]);
    denyLock = YES;
    CHECK(!PVXNativeRemuxHLSWithCancellation(@"success",out,nil,&d,&error));
    CHECK([d[@"stage"] isEqual:@"lock-contract"] && atomic_load(&calls) == before);
    denyLock = NO;
    entered = dispatch_semaphore_create(0); releaseNative = dispatch_semaphore_create(0);
    dispatch_group_t group = dispatch_group_create();
    token = [PVXNativeRemuxCancellation new];
    dispatch_group_async(group,dispatch_get_global_queue(0,0),^{ @autoreleasepool {
        NSDictionary *diag; NSString *text;
        CHECK(!PVXNativeRemuxHLSWithCancellation(@"cancel",out,token,&diag,&text));
        CHECK([diag[@"stage"] isEqual:@"cancel"] && [diag[@"nativeReturn"] intValue] == -1414092869);
    }});
    CHECK(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)) == 0);
    [token cancel]; dispatch_semaphore_signal(releaseNative);
    CHECK(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)) == 0);
    // Fake original caller holds the SAME lock: cancellation must interrupt wait.
    CHECK(pthread_mutex_lock(&shared) == 0);
    dispatch_semaphore_t waiting = dispatch_semaphore_create(0);
    token = [[PVXWaitCancellation alloc] initWithSemaphore:waiting];
    before = atomic_load(&calls);
    dispatch_group_async(group,dispatch_get_global_queue(0,0),^{ @autoreleasepool {
        NSDictionary *diag; NSString *text;
        CHECK(!PVXNativeRemuxHLSWithCancellation(@"success",out,token,&diag,&text));
        CHECK([diag[@"stage"] isEqual:@"cancel"]);
    }});
    CHECK(dispatch_semaphore_wait(waiting,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)) == 0);
    [token cancel];
    CHECK(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)) == 0);
    CHECK(atomic_load(&calls) == before);
    CHECK(pthread_mutex_unlock(&shared) == 0);
    dispatch_apply(16,dispatch_get_global_queue(0,0),^(size_t n) { @autoreleasepool {
        NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%zu.mp4",n]];
        CHECK(PVXNativeRemuxHLS(@"success",path,NULL));
    }});
    CHECK(atomic_load(&active) == 0 && atomic_load(&peak) == 1);
    CHECK([[NSFileManager defaultManager] removeItemAtPath:dir error:NULL]);
    puts("PASS adapter ABI/result/cancellation/shared-lock tests; NOT a real HLS test");
} return 0; }

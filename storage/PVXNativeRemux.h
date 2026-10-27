#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Thread-safe, sticky cancellation; the token must not be reset/reused.
@interface PVXNativeRemuxCancellation : NSObject
- (void)cancel;
@property (nonatomic, readonly, getter=isCancelled) BOOL cancelled;
@end

// Compatibility entry point. No cancellation and no diagnostic output.
FOUNDATION_EXPORT BOOL PVXNativeRemuxHLS(NSString *inputPath, NSString *outputPath, NSString * _Nullable * _Nullable errorText);
// Synchronous. Diagnostics describe adapter stages, NOT guessed internal libav stages.
// outputPath must not already exist. Cancellation is polled while waiting/in native IO.
FOUNDATION_EXPORT BOOL PVXNativeRemuxHLSWithCancellation(
    NSString *inputPath, NSString *outputPath,
    PVXNativeRemuxCancellation * _Nullable cancellation,
    NSDictionary<NSString *, id> * _Nullable * _Nullable diagnostic,
    NSString * _Nullable * _Nullable errorText);
NS_ASSUME_NONNULL_END

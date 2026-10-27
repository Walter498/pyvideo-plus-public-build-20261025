#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Asynchronous, bounded spot check, NOT a full-file decode. Completion is invoked
/// exactly once on the main queue, including invalid inputs and a 30-second timeout.
/// expectedDuration <= 0 disables duration comparison; positive values use
/// max(2 seconds, expectedDuration * 0.005). Audio is decoded when present.
/// The caller must keep the file immutable until completion.
FOUNDATION_EXPORT void PVXValidateMediaFile(NSString *path,
                                           double expectedDuration,
                                           BOOL requireAudio,
                                           void (^done)(BOOL valid, NSDictionary *details));
NS_ASSUME_NONNULL_END

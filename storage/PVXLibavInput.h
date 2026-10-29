#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Convert an already-closed NSURL-encoded playlist tree to libav file-protocol
/// input: ASCII relative leaves, hard links, no percent-escaped filesystem paths.
/// Returns a playlist inside the same task cache. Does not fetch/decrypt media.
FOUNDATION_EXPORT NSURL * _Nullable PVXLibavInput(NSURL *closedPlaylist, NSError **error);
/// Remove only the nonce-scoped generated native aliases, never source caches.
FOUNDATION_EXPORT NSDictionary * _Nullable PVXLibavInputLastReport(void);
FOUNDATION_EXPORT void PVXLibavInputCleanup(NSURL *nativePlaylist);
/// Retry-only input: plain finite TS playlists, no keys/maps/ranges/discontinuities.
FOUNDATION_EXPORT NSURL * _Nullable PVXLibavInputContinuousTS(NSURL *nativePlaylist,
    BOOL (^ _Nullable cancelled)(void), void (^ _Nullable progress)(NSUInteger,NSUInteger,unsigned long long), NSError **error);
NS_ASSUME_NONNULL_END

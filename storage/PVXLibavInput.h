#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Convert an already-closed NSURL-encoded playlist tree to libav file-protocol
/// input: ASCII relative leaves, hard links, no percent-escaped filesystem paths.
/// Returns a playlist inside the same task cache. Does not fetch/decrypt media.
FOUNDATION_EXPORT NSURL * _Nullable PVXLibavInput(NSURL *closedPlaylist, NSError **error);
NS_ASSUME_NONNULL_END

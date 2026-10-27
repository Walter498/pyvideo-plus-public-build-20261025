#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const PVXHLSLocalizerErrorDomain;

typedef NS_ENUM(NSInteger, PVXHLSLocalizerErrorCode) {
    PVXHLSLocalizerInvalidInput = 1,
    PVXHLSLocalizerUnsafePath,
    PVXHLSLocalizerMissingResource,
    PVXHLSLocalizerAmbiguousResource,
    PVXHLSLocalizerUnsupportedManifest,
    PVXHLSLocalizerInvalidRange,
    PVXHLSLocalizerInvalidKey,
    PVXHLSLocalizerNetworkFailure,
    PVXHLSLocalizerWriteFailure
};

/// Only invoked for missing identity AES-128 keys from a source manifest.
/// Must return exactly 16 bytes, or nil and an error. The request already has
/// scoped headers/cookies. Injected implementations must not follow redirects.
/// Production uses an ephemeral NSURLSession with redirects disabled.
typedef NSData * _Nullable (^PVXHLSKeyFetchBlock)(NSURLRequest *request,
                                                  NSError **error);

@interface PVXHLSLocalizer : NSObject
/// Nil uses the bounded production downloader. Inject a block for offline tests.
@property(nonatomic, copy, nullable) PVXHLSKeyFetchBlock keyFetchBlock;

/// Empty after initialization/failure and reset on every call. Filled only after
/// success: expectedDuration (selected video EXTINF sum), requireAudio,
/// segmentCount (all selected tracks), trackCount, keyCount (unique local keys),
/// sourceKind. No URLs, credentials, IVs or key bytes. Instances are not reentrant.
@property(nonatomic, copy, readonly) NSDictionary *summary;

/// Synchronous; invoke on a background thread if a missing key may need network.
/// cacheDirectory is the task's .hls directory, not its parent. Returns a unique
/// recovery m3u8 inside it only after every selected track/resource is closed.
/// Input keys: hlsSourceURL; optional hlsPlaylistPath (inside cache),
/// hlsPlaylistText (original UTF-8 source), headers (dictionary), cookies
/// (NSHTTPCookie array or cookie-property dictionaries). No shared cookie jar.
/// A legacy random local-0 playlist is reordered ONLY when the caller supplies
/// hlsLegacyRandomOrderVerified=YES, with complete contiguous responseURL suffix
/// evidence in one URL template. Real EXTINF stays attached to each file.
- (nullable NSURL *)localizeTask:(NSDictionary *)task
                cacheDirectory:(NSURL *)cacheDirectory
                         error:(NSError **)error;

/// Convenience adapter: root/media/<task.id>.hls, with a validated task id.
- (nullable NSURL *)localizeTask:(NSDictionary *)task
                 rootDirectory:(NSURL *)rootDirectory
                         error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END

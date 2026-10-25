#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^PVXMediaResourceCompletion)(NSData * _Nullable data, NSURL * _Nullable fileURL, NSHTTPURLResponse * _Nullable response, NSError * _Nullable error);
FOUNDATION_EXPORT NSArray<NSHTTPCookie *> *PVXMediaCookiesForURL(NSArray<NSHTTPCookie *> *cookies, NSURL *url);
FOUNDATION_EXPORT void PVXMediaResourceFetch(NSURLRequest *request, NSUInteger maxMemoryBytes, NSUInteger maxFileBytes, PVXMediaResourceCompletion completion);
FOUNDATION_EXPORT void PVXMediaResourceCancelAll(void);

NS_ASSUME_NONNULL_END

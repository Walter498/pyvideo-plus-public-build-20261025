#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT void PVXOpenDownloads(void);
FOUNDATION_EXPORT void PVXDownloadPlayingVideo(id _Nullable playerContext);
FOUNDATION_EXPORT void PVXInstallMenuHooks(void);
FOUNDATION_EXPORT void PVXInstallPlayerHooks(void);
FOUNDATION_EXPORT void PVXInstallImages(void);
FOUNDATION_EXPORT void PVXLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
FOUNDATION_EXPORT BOOL PVXHook(Class _Nullable cls, SEL sel, IMP replacement, IMP _Nullable * _Nullable original);
FOUNDATION_EXPORT id _Nullable PVXGet(id _Nullable object, NSString *key);
FOUNDATION_EXPORT id _Nullable PVXBrowser(void);
FOUNDATION_EXPORT WKWebView * _Nullable PVXCurrentWebView(void);
FOUNDATION_EXPORT NSString *PVXStateRoot(void);
FOUNDATION_EXPORT NSString *PVXResourcePath(NSString *name);
FOUNDATION_EXPORT UIViewController * _Nullable PVXPresenter(void);
FOUNDATION_EXPORT void PVXAlert(NSString *title, NSString *message);
FOUNDATION_EXPORT NSDictionary * _Nullable PVXActiveVideo(void);
FOUNDATION_EXPORT void PVXShowImages(void);
NS_ASSUME_NONNULL_END

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#define PVX_VERSION @"2.1.4"
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT void PVXOpenDownloads(void);
FOUNDATION_EXPORT void PVXDownloadPlayingVideo(id _Nullable playerContext);
FOUNDATION_EXPORT void PVXInstallMenuHooks(void);
FOUNDATION_EXPORT void PVXInstallPlayerHooks(void);
FOUNDATION_EXPORT void PVXInstallInlinePiP(void);
FOUNDATION_EXPORT void PVXInstallImages(void);
FOUNDATION_EXPORT void PVXLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
FOUNDATION_EXPORT void PVXDiagEvent(NSString *component, NSString *event, NSDictionary * _Nullable fields);
FOUNDATION_EXPORT BOOL PVXHook(Class _Nullable cls, SEL sel, IMP replacement, IMP _Nullable * _Nullable original);
FOUNDATION_EXPORT id _Nullable PVXGet(id _Nullable object, NSString *key);
FOUNDATION_EXPORT id _Nullable PVXBrowser(void);
FOUNDATION_EXPORT WKWebView * _Nullable PVXCurrentWebView(void);
FOUNDATION_EXPORT NSString *PVXStateRoot(void);
FOUNDATION_EXPORT NSString *PVXResourcePath(NSString *name);
FOUNDATION_EXPORT UIViewController * _Nullable PVXPresenter(void);
FOUNDATION_EXPORT void PVXAlert(NSString *title, NSString *message);
FOUNDATION_EXPORT NSDictionary * _Nullable PVXActiveVideo(void);
FOUNDATION_EXPORT void PVXExportActiveRuntime(void(^ _Nullable completion)(BOOL started));
FOUNDATION_EXPORT void PVXShowImages(void);
FOUNDATION_EXPORT void PVXShowDownloads(void);
FOUNDATION_EXPORT void PVXPreviewMedia(NSDictionary *row);
FOUNDATION_EXPORT void PVXPlayVideoURL(NSString *url);
FOUNDATION_EXPORT NSArray<NSDictionary*> *PVXReadVideoTasks(void);
FOUNDATION_EXPORT void PVXRequestTaskSnapshot(void(^ _Nullable completion)(NSArray<NSDictionary*> *rows, NSDictionary *storage));
FOUNDATION_EXPORT void PVXTaskAction(NSDictionary *task, NSString *action);
FOUNDATION_EXPORT void PVXTaskActionAll(NSArray<NSDictionary*> *tasks, NSString *action, void(^ _Nullable completion)(NSUInteger count, NSString * _Nullable error));
FOUNDATION_EXPORT BOOL PVXAutoSavePhotos(void);
FOUNDATION_EXPORT void PVXSetAutoSavePhotos(BOOL enabled);
FOUNDATION_EXPORT BOOL PVXTaskHasLocalFile(NSDictionary *task);
FOUNDATION_EXPORT void PVXExportTaskToFiles(NSDictionary *task);
FOUNDATION_EXPORT void PVXSaveTaskToPhotos(NSDictionary *task);
FOUNDATION_EXPORT void PVXSaveTaskToFiles(NSDictionary *task);
FOUNDATION_EXPORT void PVXApplyAutoSavePreferences(NSArray<NSDictionary*> *tasks);
FOUNDATION_EXPORT NSInteger PVXParallelLimit(void);
FOUNDATION_EXPORT void PVXSetParallelLimit(NSInteger limit);
FOUNDATION_EXPORT void PVXCreateDownloadFolder(NSString *name, void(^ _Nullable completion)(BOOL ok, NSString * _Nullable error));
FOUNDATION_EXPORT void PVXFetchTaskThumbnail(NSDictionary *task, void(^completion)(UIImage * _Nullable));
FOUNDATION_EXPORT NSDictionary *PVXTaskPresentation(NSDictionary *task);
FOUNDATION_EXPORT NSArray<NSDictionary*> *PVXCollectedMedia(NSString *kind);
FOUNDATION_EXPORT void PVXRefreshCollection(void);
FOUNDATION_EXPORT void PVXSetCollectionWebView(WKWebView * _Nullable web);
FOUNDATION_EXPORT WKWebView * _Nullable PVXCollectionWebView(void);
FOUNDATION_EXPORT void PVXSubmitMedia(NSDictionary *candidate, void(^completion)(NSDictionary * _Nullable submitted, NSString * _Nullable error));
FOUNDATION_EXPORT void PVXExportTasks(NSArray<NSDictionary*> *tasks, UIView * _Nullable anchor);
FOUNDATION_EXPORT void PVXExportDiagnostics(UIView * _Nullable anchor);
FOUNDATION_EXPORT void PVXUpdateTaskMetadata(NSArray<NSDictionary*> *tasks, NSString *field, NSString *value);
FOUNDATION_EXPORT NSString * _Nullable PVXTaskLocalPath(NSDictionary *task);
FOUNDATION_EXPORT NSString * _Nullable PVXTaskPreviewLocalPath(NSDictionary *task);
FOUNDATION_EXPORT NSDictionary *PVXStorageSummary(void);
FOUNDATION_EXPORT void PVXDeleteTasks(NSArray<NSDictionary*> *tasks, void(^completion)(NSString * _Nullable error));
FOUNDATION_EXPORT void PVXRememberSource(NSDictionary *candidate, NSDictionary *receipt);
FOUNDATION_EXPORT NSDictionary * _Nullable PVXLinkedTask(NSDictionary *candidate, NSArray<NSDictionary*> *tasks);
FOUNDATION_EXPORT void PVXFetchMediaQuality(NSDictionary *row, void(^done)(NSString *quality));
FOUNDATION_EXPORT void PVXFetchMediaMetadata(NSDictionary *row, void(^done)(NSDictionary *metadata));
NS_ASSUME_NONNULL_END

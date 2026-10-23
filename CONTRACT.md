# PyVideo Plus development contract
Root: /var/minis/workspace/pyvideo-plus
Original read-only analysis: /var/minis/workspace/pyvideo-0.0.3-analysis
Modules build in Objective-C ARC with iOS15 target, SDK /root/.ios-sdk/iPhoneOS26.5.sdk. No original payload edits outside staged package.

Shared src/PVXCommon.h declares exported functions:
void PVXOpenDownloads(void); // show original PVBrowser panel (main thread)
void PVXDownloadPlayingVideo(id _Nullable playerContext); // resolve active HTML/video URL using context, no arbitrary first candidate
void PVXInstallMenuHooks(void); // Menus.m module
void PVXInstallPlayerHooks(void); // Player.m module
void PVXInstallImages(void); // Images.m module
void PVXLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
BOOL PVXHook(Class cls, SEL sel, IMP replacement, IMP *original); // validates class/method, MSHookMessageEx via dlsym, fallback own-method-safe runtime swizzle
id _Nullable PVXGet(id object, NSString *key); // exception-safe KVC utility

Native addon name PyVideoPlus.dylib only loaded in Safari via substrate filter. Original PyVideo.dylib remains unchanged.
Use unique PVX class names and action identifier com.crctdd.pyvideo.plus.*. No globals named PV* without X; do not collide with original.
Menu module is responsible ONLY for address/search bar menu hook and calls PVXOpenDownloads. Player module responsible ONLY player ellipsis hook and capture reliable active player AVAsset URL/context, calls PVXDownloadPlayingVideo. Existing original tab-menu entry must remain untouched. No broad all-app injection.
All private selectors require runtime presence + type checks. Preserve original menus, completion handlers, disabled attributes; append idempotently. Avoid global UIMenu mutation that adds action to unrelated Safari menus. Diagnostics no cookies or signed media URLs in logs.
Images module and host main agent own collector, bridge, gallery and original panel image button. Separate photo-worker executable (worker/main.m) handles only image queues (see PHOTO_WORKER.md), never send image tasks to original video worker.
Other agents must not change common files/Main.m/Images.m/build scripts; write only own module + docs/evidence.

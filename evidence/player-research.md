# Player menu research and implementation evidence

## Scope and result

Implemented `src/Player.m` for **Safari's in-process native AVKit overflow (ellipsis) menu**, the menu containing Playback Speed / Show Text in the reported screenshot. This is not a claim to modify every Picture-in-Picture window. Changes are confined to this module and its own evidence/test files. No original PyVideo payload, tab-menu entry, Main/Common/Images/build file was changed by this task.

Read `CONTRACT.md` and the supplied `PVXCommon.h`; inspected Main's context resolver read-only to match its accepted dictionary keys. Session memory is disabled, so persistent memory/GLOBAL was not accessed. No separate workspace GLOBAL file was found.

## Actual selector evidence

RuntimeBrowser headers are declarations, not executable implementation or proof of behavior on every OS point release. The following successful source downloads establish real selector names and signatures, rather than guessed `_moreMenu` selectors.

### iOS 16: qingralf/iOS16-Runtime-Headers

Base: https://github.com/qingralf/iOS16-Runtime-Headers

1. [AVPlaybackControlsController.h](https://raw.githubusercontent.com/qingralf/iOS16-Runtime-Headers/main/Frameworks/AVKit.framework/AVPlaybackControlsController.h), line 319:

```objc
- (id)overflowMenuItemsForControlOverflowButton:(id)arg1;
```

This controller has `AVPlayerController *playerController` and `AVPlayerViewController *playerViewController`. **Hook target #1**, the legacy/chrome overflow provider.

2. [AVMobileAuxiliaryControlsView.h](https://raw.githubusercontent.com/qingralf/iOS16-Runtime-Headers/main/Frameworks/AVKit.framework/AVMobileAuxiliaryControlsView.h), line 41:

```objc
- (id)overflowMenuItemsForControlOverflowButton:(id)arg1;
```

The class conforms to `AVControlOverflowButtonDelegate` and has an object `delegate`. **Hook target #2**, the modern/chromeless overflow provider.

3. [AVMobileChromelessControlsViewController.h](https://raw.githubusercontent.com/qingralf/iOS16-Runtime-Headers/main/Frameworks/AVKit.framework/AVMobileChromelessControlsViewController.h), line 95:

```objc
- (id)auxiliaryControlsView:(id)arg1 menuElementForControl:(id)arg2;
```

This is a per-control menu provider, not the aggregate overflow provider. Deliberately **not hooked**: appending a download here could create duplicates in individual speed/audio/subtitle menus.

4. [AVMobileChromeControlsViewController.h](https://raw.githubusercontent.com/qingralf/iOS16-Runtime-Headers/main/Frameworks/AVKit.framework/AVMobileChromeControlsViewController.h) subclasses `AVMobileControlsViewController` and has `_playbackControlsController`, `_playbackControlsView`, `_playerViewController`. It is a controller/forwarding layer, not evidence for a made-up `buildMenu` method. No guessed selector or raw ivar hook is installed on it.

### iOS 17: MTACS/iOS-17-Runtime-Headers

Base: https://github.com/MTACS/iOS-17-Runtime-Headers

- [AVPlaybackControlsController.h](https://raw.githubusercontent.com/MTACS/iOS-17-Runtime-Headers/main/Frameworks/AVKit.framework/AVPlaybackControlsController.h), line 317: the same `- (id)overflowMenuItemsForControlOverflowButton:(id)arg1;`.
- [AVMobileAuxiliaryControlsView.h](https://raw.githubusercontent.com/MTACS/iOS-17-Runtime-Headers/main/Frameworks/AVKit.framework/AVMobileAuxiliaryControlsView.h), line 38: the same overflow provider; also `_updateOverflowControlContextMenu` and `updateOverflowMenu` (void update methods, NOT object-return menu builders).
- [AVControlOverflowButton.h](https://raw.githubusercontent.com/MTACS/iOS-17-Runtime-Headers/main/Frameworks/AVKit.framework/AVControlOverflowButton.h): `delegate`, `updateContextMenu`, and `contextMenuInteraction:configurationForMenuAtLocation:` confirm a context-menu button with delegated content. No broad UIKit context-menu interception is needed.
- [AVMobileChromelessControlsViewController.h](https://raw.githubusercontent.com/MTACS/iOS-17-Runtime-Headers/main/Frameworks/AVKit.framework/AVMobileChromelessControlsViewController.h), line 101: `auxiliaryControlsView:menuElementForControl:`; superclass provides `playerController`.
- [AVMobileControlsViewController.h](https://raw.githubusercontent.com/MTACS/iOS-17-Runtime-Headers/main/Frameworks/AVKit.framework/AVMobileControlsViewController.h): retained `AVPlayerController *playerController` and `transportBarCustomMenuItems`.
- [AVPlayerViewController.h](https://raw.githubusercontent.com/MTACS/iOS-17-Runtime-Headers/main/Frameworks/AVKit.framework/AVPlayerViewController.h): `player`, `playerController`, `transportBarCustomMenuItems`. Setting custom items is an alternative API path, but would require preserving every later setter/update; this implementation instead appends at the actual overflow return boundary.
- [AVPlaybackControlsView.h](https://raw.githubusercontent.com/MTACS/iOS-17-Runtime-Headers/main/Frameworks/AVKit.framework/AVPlaybackControlsView.h): investigated as requested. The two proven overflow providers above are more direct than indiscriminate controls-view layout hooks.

### iOS 15: honestly bounded evidence

[Public iPhoneOS15.5 AVPlayerViewController header](https://raw.githubusercontent.com/xybp888/iOS-SDKs/master/iPhoneOS15.5.sdk/System/Library/Frameworks/AVKit.framework/Headers/AVPlayerViewController.h) confirms the public AVPlayerViewController/player and separate full-screen/PiP lifecycle surface; it does not establish the private overflow builder's ABI. The attempted iOS15.3.1 runtime-header repository does not contain AVKit in its available Frameworks listing. Limneos requests did not return usable evidence in this environment. Therefore **the private iOS15 menu path is not source-verified here**. The actual legacy selector is established on iOS16/17, and the binary targets iOS15 with per-method runtime checks. On an iOS15 version exposing it, it can hook; if absent or ABI-incompatible it logs and skips. Do not describe this as device-verified support for all iOS15 builds.

No third-party tweak code is represented as proof: the cited real private headers and upstream WebKit source are the evidence used. No fabricated tweak repository or selector is required.

## Precise current-video selection

Upstream open-source WebKit is crucial evidence that `AVPlayerViewController.player.currentItem.asset.URL` alone is not universally the page media URL:

- [WebAVPlayerController.mm](https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebCore/platform/cocoa/WebAVPlayerController.mm), current source lines 277–279 creates an AVAsset using `about:blank`, then an AVPlayerItem and an AVPlayer. Lines 392–399 implement `player` and `currentItem`. These line numbers describe the downloaded source, not an immutable release.
- [WebAVPlayerController.h](https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebCore/platform/cocoa/WebAVPlayerController.h) declares `WebAVPlayerController : NSObject` and `playerControllerProxy`. This is why the code recognizes WebAVPlayerController independently, not just AVPlayerController subclasses.

Algorithm:

1. The action weakly references its specific menu owner. No process-global last-player pointer is used. If the owner has been released, show an explanatory alert and do not choose another tab.
2. At action invocation, traverse only that owner's known playback graph: legacy controller `playerController` / `playerViewController`; modern auxiliary view's typed AVMobileControlsViewController delegate; that controller's `playerController`; local responder ancestors as a bounded fallback.
3. Getter calls require an existing method with object-return / zero-explicit-argument ABI before exception-safe `PVXGet`. Traversal is identity-deduplicated and bounded (32 nodes, 16 responder steps).
4. On a real AVPlayer, snapshot **the current item at click time**, not at menu-build time. Return a dictionary with `url`, `player`, `currentItem`, `asset` only when the asset is AVURLAsset and the URL has HTTP(S) scheme and a host. Parent Main already accepts those keys; a URL snapshot prevents async queue-player advancement from changing the chosen source.
5. With synthetic/about/blob/non-URL assets, pass `playerController` context to `PVXDownloadPlayingVideo`. That parent's active-fullscreen/playing HTML bridge must provide the actual selected video's resource or fail clearly. This module never enumerates video candidates and never selects the first page `<video>`.

Passing a controller does not magically map a WebKit media element to a URL. The parent bridge remains the fallback authority. DRM, MediaSource blob URLs, inaccessible frames, revoked resources, or missing active-element evidence may remain undownloadable. No universal URL-extraction claim is made.

## Hook safety and menu preservation

- Installation is explicitly limited to `com.apple.mobilesafari`, uses `dispatch_once`, and loads AVKit before private class lookup to handle lazy loading.
- Each target must exist and have exactly three Objective-C arguments (`self`, `_cmd`, one object), with object return and object explicit argument after qualifier stripping. Struct/scalar/block-ABI guesses are rejected.
- Uses the provided `PVXHook`, separate original IMP slots, original called exactly once with unmodified arguments. These methods have no completion handler; none is intercepted or dropped.
- Normal result is expected to be `NSArray<UIMenuElement *>`. Since headers only say `id`, the implementation validates actual result shape at runtime. A compatible UIMenu result uses `menuByReplacingChildren:` so native title/options/identifier metadata survives. Unexpected types or nil are returned unchanged.
- All original child objects are retained unmodified: speed/subtitle/Show Text actions, attributes/disabled flags, ordering, deferred menu providers and their completion blocks. Exactly one UIAction with identifier `com.crctdd.pyvideo.plus.download-current-video` is appended; existing nested occurrences are detected before insertion. Existing menus are not mutated globally.
- UI title: `下载当前视频`; system symbol: `arrow.down.circle`. Action execution is marshalled onto the main queue.
- Logging contains only class names and hook status, never cookies, media URLs, page URLs or signed query parameters.

## PiP limitation

A system-owned PiP overlay is commonly hosted outside Safari. A Safari-only dylib cannot insert arbitrary actions into an out-of-process UI by hooking Safari's AVKit classes. No SpringBoard/PiP-agent injection, undocumented cross-process menu API, or universal PiP modification is implemented. If Safari itself owns an overflow menu using one of these builders, this code handles that menu; otherwise return to Safari's in-app full-screen player to use the action. This matches the supplied screenshot instead of mislabelling every ellipsis menu as PiP.

## Local validation (no installation / runtime claim)

Both commands completed with exit status 0 and no diagnostics:

```sh
clang -target arm64-apple-ios15.0 -fobjc-arc -fblocks -fsyntax-only \
  -isysroot /root/.ios-sdk/iPhoneOS26.5.sdk \
  -F/root/.ios-sdk/iPhoneOS26.5.sdk/System/Library/SubFrameworks \
  -Wall -Wextra src/Player.m

clang -target arm64-apple-ios15.0 -fobjc-arc -fblocks -fsyntax-only \
  -isysroot /root/theos/sdks/iPhoneOS16.5.sdk \
  -Wall -Wextra src/Player.m
```

These are actual cross-SDK ARC syntax checks, not simulator/device/UI tests. iOS frameworks cannot execute in this Linux shell. No app was installed or launched. Private selector presence on a user's device, actual NSArray result shape, menu appearance and selected-source behavior still require device validation. Reproducible syntax and object-compilation checks are in `evidence/player-tests/check.sh`.

Recommended device acceptance cases: legacy and chromeless full-screen menus; preserve Playback Speed/Show Text; reopen repeatedly with exactly one added action; multiple page videos with a non-first one fullscreen; AVQueuePlayer current-item change before tapping; direct MP4 and HLS assets; WebKit about:blank proxy with active-element bridge; paused fullscreen video; blob/DRM fail clearly; dismiss owner before action; missing selector safely skips; system PiP explicitly remains outside the claimed scope.

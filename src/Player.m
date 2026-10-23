// Safari-only AVKit overflow menu integration. No system PiP process injection.
#import "PVXCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <dlfcn.h>
#import <string.h>
#import <stdlib.h>

static NSString * const PVXPlayerActionID = @"com.crctdd.pyvideo.plus.download-current-video";
static IMP PVXLegacyOverflowOriginal;
static IMP PVXAuxiliaryOverflowOriginal;

static const char *PVXPlayerUnqualifiedType(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) ++type;
    return type;
}

// Do not invoke a guessed ABI. Object return and every explicit argument are checked.
static BOOL PVXPlayerObjectMethod(Method method, unsigned int explicitArguments) {
    if (!method || method_getNumberOfArguments(method) != explicitArguments + 2) return NO;
    char *type = method_copyReturnType(method);
    BOOL valid = *PVXPlayerUnqualifiedType(type) == '@';
    free(type);
    for (unsigned int i = 2; valid && i < explicitArguments + 2; ++i) {
        type = method_copyArgumentType(method, i);
        valid = *PVXPlayerUnqualifiedType(type) == '@';
        free(type);
    }
    return valid;
}

static BOOL PVXPlayerIsKind(id object, NSString *className) {
    Class cls = NSClassFromString(className);
    return object && cls && [object isKindOfClass:cls];
}

static id PVXPlayerRead(id object, NSString *getter) {
    if (!object) return nil;
    SEL sel = NSSelectorFromString(getter);
    Method method = class_getInstanceMethod(object_getClass(object), sel);
    if (!PVXPlayerObjectMethod(method, 0)) return nil;
    // PVXGet catches KVC / WebKit proxy exceptions; getter presence and ABI checked above.
    return PVXGet(object, getter);
}

static NSURL *PVXPlayerHTTPURL(id value) {
    if (![value isKindOfClass:NSURL.class]) return nil;
    NSURL *url = value;
    NSString *scheme = url.scheme.lowercaseString;
    return url.host.length && ([scheme isEqualToString:@"https"] ||
                              [scheme isEqualToString:@"http"]) ? url : nil;
}

// Traverse only this menu owner's playback graph, never app windows, all players,
// arbitrary Safari delegates, page candidate lists, or document.querySelector('video').
static NSDictionary *PVXPlayerContext(id owner) {
    NSMutableArray *queue = [NSMutableArray arrayWithObject:owner];
    NSHashTable *seen = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality];
    id playbackContext = nil;
    for (NSUInteger index = 0; index < queue.count && index < 32; ++index) {
        id node = queue[index];
        if ([seen containsObject:node]) continue;
        [seen addObject:node];
        if (PVXPlayerIsKind(node, @"AVPlayerController") ||
            PVXPlayerIsKind(node, @"WebAVPlayerController") ||
            [node isKindOfClass:AVPlayerViewController.class]) {
            if (!playbackContext) playbackContext = node;
        }
        if ([node isKindOfClass:AVPlayer.class]) {
            // Snapshot at action time, not menu construction time (AVQueuePlayer may advance).
            AVPlayerItem *item = [(AVPlayer *)node currentItem];
            AVAsset *asset = item.asset;
            NSURL *url = [asset isKindOfClass:AVURLAsset.class]
                ? PVXPlayerHTTPURL([(AVURLAsset *)asset URL]) : nil;
            if (url) return @{@"url": url, @"player": node,
                              @"currentItem": item, @"asset": asset};
        }
        if ([node isKindOfClass:AVPlayerViewController.class] ||
            PVXPlayerIsKind(node, @"AVPlayerController") ||
            PVXPlayerIsKind(node, @"WebAVPlayerController") ||
            PVXPlayerIsKind(node, @"AVPlaybackControlsController") ||
            PVXPlayerIsKind(node, @"AVMobileControlsViewController")) {
            for (NSString *getter in @[@"player", @"playerController", @"playerViewController"]) {
                id next = PVXPlayerRead(node, getter);
                if (next && next != node && ![seen containsObject:next]) [queue addObject:next];
            }
        }
        if (PVXPlayerIsKind(node, @"AVMobileAuxiliaryControlsView")) {
            id delegate = PVXPlayerRead(node, @"delegate");
            // Actual AVMobileAuxiliaryControlsViewDelegate implementation owns playerController.
            if (PVXPlayerIsKind(delegate, @"AVMobileControlsViewController")) [queue addObject:delegate];
            // Local responder ancestry only. Never search a global view-controller hierarchy.
            UIResponder *responder = [node isKindOfClass:UIResponder.class] ? node : nil;
            for (NSUInteger depth = 0; responder && depth < 16; ++depth) {
                responder = responder.nextResponder;
                if ([responder isKindOfClass:AVPlayerViewController.class] ||
                    PVXPlayerIsKind(responder, @"AVMobileControlsViewController")) {
                    [queue addObject:responder];
                    break;
                }
            }
        }
    }
    // WebKit often supplies a synthetic about:blank player, NOT the media resource.
    // Keep its controller context for the parent's active-fullscreen HTML bridge.
    // No URL is invented, and blob/about/file/non-HTTP URLs never become download URLs here.
    return @{@"playerController": playbackContext ?: owner};
}

static BOOL PVXPlayerContainsAction(NSArray *children, NSUInteger depth) {
    if (depth > 16) return NO;
    for (id item in children) {
        if ([item isKindOfClass:UIAction.class] &&
            [((UIAction *)item).identifier isEqualToString:PVXPlayerActionID]) return YES;
        if ([item isKindOfClass:UIMenu.class] &&
            PVXPlayerContainsAction(((UIMenu *)item).children, depth + 1)) return YES;
    }
    return NO;
}

static UIAction *PVXPlayerDownloadAction(id owner) {
    __weak id weakOwner = owner; // avoid owner -> controls/menu -> action -> owner retain cycle
    return [UIAction actionWithTitle:@"下载当前视频"
                              image:[UIImage systemImageNamed:@"arrow.down.circle"]
                         identifier:PVXPlayerActionID handler:^(__kindof UIAction *action) {
        (void)action;
        void (^invoke)(void) = ^{
            id strongOwner = weakOwner;
            if (!strongOwner) {
                PVXAlert(@"播放器已关闭", @"请在当前视频的播放器菜单中重新选择下载。");
                return; // do not fall back to another tab after this owner has gone away
            }
            PVXDownloadPlayingVideo(PVXPlayerContext(strongOwner));
        };
        if ([NSThread isMainThread]) invoke();
        else dispatch_async(dispatch_get_main_queue(), invoke);
    }];
}

static id PVXPlayerAppendDownload(id original, id owner) {
    // These private methods normally return NSArray<UIMenuElement *>.
    // Accept a UIMenu on compatible OS variants; preserve all its metadata via replacement.
    // Unexpected types and nil fail closed, rather than replacing native behavior.
    NSArray *children = nil;
    if ([original isKindOfClass:NSArray.class]) children = original;
    else if ([original isKindOfClass:UIMenu.class]) children = ((UIMenu *)original).children;
    else return original;
    for (id item in children) if (![item isKindOfClass:UIMenuElement.class]) return original;
    if (PVXPlayerContainsAction(children, 0)) return original;
    UIAction *manager = [UIAction actionWithTitle:@"下载管理" image:[UIImage systemImageNamed:@"list.bullet.rectangle"] identifier:@"com.crctdd.pyvideo.plus.player-manager" handler:^(__kindof UIAction *action) {
        (void)action;
        dispatch_async(dispatch_get_main_queue(), ^{ PVXOpenDownloads(); });
    }];
    NSArray *updated = [children arrayByAddingObjectsFromArray:@[PVXPlayerDownloadAction(owner), manager]];
    if ([original isKindOfClass:UIMenu.class])
        return [(UIMenu *)original menuByReplacingChildren:updated];
    return updated;
}

static id PVXPlayerLegacyOverflow(id self, SEL cmd, id button) {
    id original = ((id (*)(id, SEL, id))PVXLegacyOverflowOriginal)(self, cmd, button);
    return PVXPlayerAppendDownload(original, self);
}

static id PVXPlayerAuxiliaryOverflow(id self, SEL cmd, id button) {
    id original = ((id (*)(id, SEL, id))PVXAuxiliaryOverflowOriginal)(self, cmd, button);
    return PVXPlayerAppendDownload(original, self);
}

static BOOL PVXPlayerInstallOverflow(NSString *className, IMP replacement, IMP *original) {
    Class cls = NSClassFromString(className);
    SEL selector = NSSelectorFromString(@"overflowMenuItemsForControlOverflowButton:");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!PVXPlayerObjectMethod(method, 1)) {
        PVXLog(@"player menu: %@ unavailable or incompatible signature", className);
        return NO;
    }
    BOOL installed = PVXHook(cls, selector, replacement, original);
    PVXLog(@"player menu: %@ hook %@", className, installed ? @"installed" : @"failed");
    return installed;
}

void PVXInstallPlayerHooks(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.mobilesafari"]) return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // AVKit can be lazily loaded by Safari. Load before checking private classes.
        // Handle intentionally kept open for process lifetime, like the hooks themselves.
        (void)dlopen("/System/Library/Frameworks/AVKit.framework/AVKit", RTLD_LAZY | RTLD_LOCAL);
        BOOL legacy = PVXPlayerInstallOverflow(@"AVPlaybackControlsController",
            (IMP)PVXPlayerLegacyOverflow, &PVXLegacyOverflowOriginal);
        BOOL modern = PVXPlayerInstallOverflow(@"AVMobileAuxiliaryControlsView",
            (IMP)PVXPlayerAuxiliaryOverflow, &PVXAuxiliaryOverflowOriginal);
        if (!legacy && !modern)
            PVXLog(@"player menu: no supported in-process overflow builder; no generic menu fallback");
    });
}

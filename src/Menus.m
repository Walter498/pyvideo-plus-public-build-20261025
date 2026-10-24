#import "PVXCommon.h"
#import <mach-o/dyld.h>
#import <stdatomic.h>
#import <string.h>

// Header provenance and supported/fail-closed paths: evidence/menu-research.md.
static NSString *const PVXDownloadMenuIdentifier = @"com.crctdd.pyvideo.plus.address-downloads";
static IMP PVXOriginalCapsuleProvider;
static IMP PVXOriginalURLButtonMenu;
static atomic_bool PVXMenuInstallQueued;

static const char *PVXMenuUnqualified(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) ++type;
    return type;
}
static BOOL PVXMenuObjectType(const char *type) {
    type = PVXMenuUnqualified(type);
    return type && type[0] == '@';
}

// Only accept the documented object-only method ABIs. Never cast a mismatched IMP.
static BOOL PVXMenuMethodMatches(Class cls, SEL selector, NSUInteger count, BOOL blockReturn) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != count) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    const char *result = PVXMenuUnqualified(signature.methodReturnType);
    if (!PVXMenuObjectType(result) || (blockReturn && strcmp(result, "@?") != 0)) return NO;
    if (strcmp(PVXMenuUnqualified([signature getArgumentTypeAtIndex:1]), ":") != 0) return NO;
    for (NSUInteger i = 0; i < count; ++i) {
        if (i != 1 && !PVXMenuObjectType([signature getArgumentTypeAtIndex:i])) return NO;
    }
    return YES;
}

// Clang Blocks ABI: a provider must be a signed block returning an object and
// taking exactly one object argument (plus its implicit block argument).
// This is a signature check, not pointer-authentication/signing manipulation.
static BOOL PVXMenuProviderMatches(id object) {
    Class blockClass = NSClassFromString(@"NSBlock");
    if (!object || !blockClass || ![object isKindOfClass:blockClass]) return NO;
    struct PVXMenuBlockLiteral {
        void *isa;
        int flags;
        int reserved;
        void (*invoke)(void *, ...);
        const unsigned long *descriptor;
    };
    const struct PVXMenuBlockLiteral *literal = (__bridge const void *)object;
    if (!(literal->flags & (1 << 30)) || !literal->descriptor) return NO;
    const char *cursor = (const char *)literal->descriptor + 2 * sizeof(unsigned long);
    if (literal->flags & (1 << 25)) cursor += 2 * sizeof(void *);
    const char *encoding = NULL;
    memcpy(&encoding, cursor, sizeof(encoding));
    if (!encoding) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:encoding];
    return signature.numberOfArguments == 2 && PVXMenuObjectType(signature.methodReturnType)
        && strcmp(PVXMenuUnqualified([signature getArgumentTypeAtIndex:0]), "@?") == 0
        && PVXMenuObjectType([signature getArgumentTypeAtIndex:1]);
}

static UIMenu *PVXStripDownloadAction(UIMenu *menu) {
    if (![menu isKindOfClass:UIMenu.class]) return menu;
    NSMutableArray *children=[NSMutableArray array];BOOL changed=NO;
    for(UIMenuElement *child in menu.children){
        if([child isKindOfClass:UIAction.class]&&[((UIAction*)child).identifier isEqualToString:PVXDownloadMenuIdentifier]){changed=YES;continue;}
        if([child isKindOfClass:UIMenu.class]){UIMenu *nested=PVXStripDownloadAction((UIMenu*)child);changed|=nested!=child;[children addObject:nested];}
        else [children addObject:child];
    }
    return changed?[menu menuByReplacingChildren:children]:menu;
}
static id PVXMenuAppendDownloads(id original) {
    if (![original isKindOfClass:UIMenu.class] || !NSThread.isMainThread) return original;
    UIMenu *menu=PVXStripDownloadAction((UIMenu*)original);
    UIAction *action=[UIAction actionWithTitle:@"下载视频与图片" image:[UIImage systemImageNamed:@"arrow.down.circle"] identifier:PVXDownloadMenuIdentifier handler:^(__unused UIAction *sender){dispatch_async(dispatch_get_main_queue(),^{PVXOpenDownloads();});}];
    return [menu menuByReplacingChildren:[menu.children arrayByAddingObject:action]];
}

static id PVXCapsuleActionProvider(id self, SEL command) {
    id original = ((id (*)(id, SEL))PVXOriginalCapsuleProvider)(self, command);
    if (!PVXMenuProviderMatches(original)) return original;
    UIContextMenuActionProvider provider = [original copy];
    UIContextMenuActionProvider wrapped = ^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        // Call Apple's provider exactly once, unchanged arguments, then append.
        return PVXMenuAppendDownloads(provider(suggested));
    };
    return [wrapped copy];
}

static id PVXURLButtonEditMenu(id self, SEL command, id interaction, id configuration, id suggested) {
    id menu = ((id (*)(id, SEL, id, id, id))PVXOriginalURLButtonMenu)
        (self, command, interaction, configuration, suggested);
    return PVXMenuAppendDownloads(menu);
}

static void PVXTryInstallMenuHooks(void) {
    // All installation attempts are serialized on the main queue, including
    // image-load notifications; never call ObjC or hook code under dyld's lock.
    Class capsule = NSClassFromString(@"CapsuleNavigationBarViewController");
    SEL provider = NSSelectorFromString(@"_contextMenuActionProvider");
    if (!PVXOriginalCapsuleProvider && capsule && PVXMenuMethodMatches(capsule, provider, 2, YES)) {
        if (PVXHook(capsule, provider, (IMP)PVXCapsuleActionProvider, &PVXOriginalCapsuleProvider))
            PVXLog(@"Address menu: installed CapsuleNavigationBarViewController provider hook");
    }
    Class urlButton = NSClassFromString(@"_SFNavigationBarURLButton");
    SEL editMenu = NSSelectorFromString(@"editMenuInteraction:menuForConfiguration:suggestedActions:");
    if (!PVXOriginalURLButtonMenu && urlButton && PVXMenuMethodMatches(urlButton, editMenu, 5, NO)) {
        if (PVXHook(urlButton, editMenu, (IMP)PVXURLButtonEditMenu, &PVXOriginalURLButtonMenu))
            PVXLog(@"Address menu: installed _SFNavigationBarURLButton edit-menu hook");
    }
}

static void PVXQueueMenuInstallation(void) {
    if (atomic_exchange(&PVXMenuInstallQueued, true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store(&PVXMenuInstallQueued, false);
        PVXTryInstallMenuHooks();
    });
}
static void PVXMenuImageAdded(__unused const struct mach_header *header, __unused intptr_t slide) {
    PVXQueueMenuInstallation();
}

static IMP PVXOldBarSetMenu;
static UIMenu *PVXRemoveOriginalTabAction(UIMenu *menu) {
    if (![menu isKindOfClass:UIMenu.class]) return menu;
    BOOL changed=NO; NSMutableArray *items=[NSMutableArray array];
    for (UIMenuElement *item in menu.children) {
        if ([item isKindOfClass:UIAction.class] && [((UIAction*)item).identifier isEqualToString:@"com.crctdd.pyvideo.download-video"]) { changed=YES; continue; }
        if ([item isKindOfClass:UIMenu.class]) { UIMenu *nested=PVXRemoveOriginalTabAction((UIMenu*)item);changed|=nested!=item;[items addObject:nested]; } else [items addObject:item];
    }
    return changed?[menu menuByReplacingChildren:items]:menu;
}
static void PVXBarSetMenu(id self,SEL command,id menu) { UIMenu *clean=PVXRemoveOriginalTabAction(menu); ((void(*)(id,SEL,id))PVXOldBarSetMenu)(self,command,PVXMenuAppendDownloads(clean)); }
void PVXInstallMenuHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.mobilesafari"]) return;
        PVXHook(UIBarButtonItem.class,@selector(setMenu:),(IMP)PVXBarSetMenu,&PVXOldBarSetMenu);
        // Includes already loaded images and later-loaded Safari frameworks.
        _dyld_register_func_for_add_image(PVXMenuImageAdded);
        PVXQueueMenuInstallation();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            PVXTryInstallMenuHooks();
            if (!PVXOriginalCapsuleProvider && !PVXOriginalURLButtonMenu)
                PVXLog(@"Address menu: no supported class/signature; leaving menus unchanged");
        });
    });
}

#import "PVXCommon.h"
#import <AVKit/AVKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <stdatomic.h>
static char PVXInlineMenuKey;
@interface PVXInlineMenu : NSObject<UIContextMenuInteractionDelegate>
@property(nonatomic,weak)id playbackOwner;
@end
@implementation PVXInlineMenu
- (UIContextMenuConfiguration*)contextMenuInteraction:(UIContextMenuInteraction*)interaction configurationForMenuAtLocation:(CGPoint)location{__weak id owner=self.playbackOwner;return [UIContextMenuConfiguration configurationWithIdentifier:@"com.crctdd.pyvideo.plus.inline-pip" previewProvider:nil actionProvider:^UIMenu*(NSArray<UIMenuElement*> *suggested){UIAction *current=[UIAction actionWithTitle:@"下载当前视频" image:[UIImage systemImageNamed:@"arrow.down.circle"] identifier:@"com.crctdd.pyvideo.plus.inline-current" handler:^(UIAction *a){id c=owner;if(c)PVXDownloadPlayingVideo(c);else PVXAlert(@"播放器已关闭",@"请在当前播放器重新打开菜单。");}];UIAction *manager=[UIAction actionWithTitle:@"下载管理" image:[UIImage systemImageNamed:@"list.bullet.rectangle"] identifier:@"com.crctdd.pyvideo.plus.inline-manager" handler:^(UIAction *a){PVXOpenDownloads();}];return [UIMenu menuWithTitle:@"PyVideo" children:@[current,manager]];}];}
@end
static void PVXAttachInlineMenu(id owner){if(!NSThread.isMainThread)return;UIView *v=nil;if([owner isKindOfClass:UIViewController.class])v=[(UIViewController*)owner viewIfLoaded];else if([owner isKindOfClass:UIView.class])v=owner;if(!v||objc_getAssociatedObject(v,&PVXInlineMenuKey))return;PVXInlineMenu *delegate=[PVXInlineMenu new];delegate.playbackOwner=owner;UIContextMenuInteraction *interaction=[[UIContextMenuInteraction alloc] initWithDelegate:delegate];[v addInteraction:interaction];objc_setAssociatedObject(v,&PVXInlineMenuKey,delegate,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
static IMP PVXPiPLoad,PVXPlayerAppear;
static void PVXPiPDidLoad(id self,SEL cmd){((void(*)(id,SEL))PVXPiPLoad)(self,cmd);PVXAttachInlineMenu(self);}
static void PVXPlayerDidAppear(id self,SEL cmd,BOOL animated){((void(*)(id,SEL,BOOL))PVXPlayerAppear)(self,cmd,animated);PVXAttachInlineMenu(self);}
static BOOL PVXVoidMethod(Class c,SEL s,unsigned count){Method m=class_getInstanceMethod(c,s);if(!m||method_getNumberOfArguments(m)!=count)return NO;char *t=method_copyReturnType(m);BOOL ok=t&&t[0]=='v';free(t);if(count==3){t=method_copyArgumentType(m,2);ok=ok&&t&&(t[0]=='B'||t[0]=='c');free(t);}return ok;}
static void PVXTryInline(void){Class p=NSClassFromString(@"AVPictureInPictureViewController");SEL load=@selector(loadView);if(!PVXPiPLoad&&PVXVoidMethod(p,load,2))PVXHook(p,load,(IMP)PVXPiPDidLoad,&PVXPiPLoad);Class player=NSClassFromString(@"AVPlayerViewController");SEL appear=@selector(viewDidAppear:);if(!PVXPlayerAppear&&PVXVoidMethod(player,appear,3))PVXHook(player,appear,(IMP)PVXPlayerDidAppear,&PVXPlayerAppear);}
static atomic_bool PVXInlineQueued;
static void PVXInlineImage(const struct mach_header *h,intptr_t slide){if(atomic_exchange(&PVXInlineQueued,true))return;dispatch_async(dispatch_get_main_queue(),^{atomic_store(&PVXInlineQueued,false);PVXTryInline();});}
void PVXInstallInlinePiP(void){static dispatch_once_t once;dispatch_once(&once,^{if(![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.mobilesafari"])return;dlopen("/System/Library/Frameworks/AVKit.framework/AVKit",RTLD_LAZY|RTLD_LOCAL);_dyld_register_func_for_add_image(PVXInlineImage);PVXTryInline();});}

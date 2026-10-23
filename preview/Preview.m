// Simulator-only fixtures. Not included in production addon.
#import "PVXCommon.h"
#import <objc/message.h>
static NSArray *Rows;static BOOL Auto=YES;
NSArray *PVXReadVideoTasks(void){return Rows;}
id PVXGet(id o,NSString *k){@try{return [o valueForKey:k];}@catch(NSException *e){return nil;}}
id PVXBrowser(void){return nil;}NSString *PVXStateRoot(void){return NSHomeDirectory();}
BOOL PVXAutoSavePhotos(void){return Auto;}void PVXSetAutoSavePhotos(BOOL value){Auto=value;}
BOOL PVXTaskHasLocalFile(NSDictionary *t){return [t[@"state"] isEqual:@"saved"]||[t[@"state"] isEqual:@"ready"];}
void PVXTaskAction(NSDictionary *t,NSString *a){(void)t;(void)a;}
void PVXExportTaskToFiles(NSDictionary *t){(void)t;}void PVXSaveTaskToPhotos(NSDictionary *t){(void)t;}
void PVXShowImages(void){}
void PVXAlert(NSString *t,NSString *m){NSLog(@"%@ %@",t,m);}
NSDictionary *PVXTaskPresentation(NSDictionary *r){BOOL active=[r[@"state"] isEqual:@"downloading"];return @{@"status":active?@"下载中":@"下载成功",@"symbol":active?@"arrow.down.circle.fill":@"checkmark.circle.fill",@"tint":active?UIColor.systemBlueColor:UIColor.systemGreenColor,@"size":active?@"31.0 MB/1.44 GB (2.2%)":@"2.04 GB",@"format":@"mp4",@"progress":active?@.022:@1};}
void PVXFetchTaskThumbnail(NSDictionary *t,void(^done)(UIImage*)){UIGraphicsBeginImageContextWithOptions(CGSizeMake(320,180),YES,1);[[UIColor blackColor] setFill];UIRectFill(CGRectMake(0,0,320,180));NSString *s=@"PyVideo";[s drawAtPoint:CGPointMake(85,70) withAttributes:@{NSFontAttributeName:[UIFont boldSystemFontOfSize:30],NSForegroundColorAttributeName:UIColor.whiteColor}];UIImage *image=UIGraphicsGetImageFromCurrentImageContext();UIGraphicsEndImageContext();done(image);}
@interface PreviewApp : UIResponder<UIApplicationDelegate>
@property UIWindow *window;
@end
UIViewController *PVXPresenter(void){UIViewController *c=((PreviewApp*)UIApplication.sharedApplication.delegate).window.rootViewController;while(c.presentedViewController)c=c.presentedViewController;return c;}
@implementation PreviewApp
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launch{NSMutableArray *rows=[NSMutableArray array];for(int i=0;i<9;i++)[rows addObject:@{@"id":[NSString stringWithFormat:@"00000000-0000-0000-0000-%012d",i],@"title":i==0?@"当前影片 · 下载进度展示":@"网页影片 · 原文件保留与手动导出",@"state":i==0?@"downloading":@"saved",@"kind":@"video"}];Rows=rows;self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];self.window.rootViewController=[UIViewController new];[self.window makeKeyAndVisible];dispatch_async(dispatch_get_main_queue(),^{PVXShowDownloads();});return YES;}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(PreviewApp.class));}}

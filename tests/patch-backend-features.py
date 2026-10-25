from pathlib import Path
import re
P=Path('/var/minis/workspace/pyvideo-plus')
# Header
p=P/'src/PVXCommon.h';s=p.read_text()
if 'PVXTaskActionAll' not in s:s=s.replace('FOUNDATION_EXPORT void PVXTaskAction(NSDictionary *task, NSString *action);','FOUNDATION_EXPORT void PVXTaskAction(NSDictionary *task, NSString *action);\nFOUNDATION_EXPORT void PVXTaskActionAll(NSArray<NSDictionary*> *tasks, NSString *action, void(^ _Nullable completion)(NSUInteger count, NSString * _Nullable error));')
if 'PVXSaveTaskToFiles' not in s:s=s.replace('FOUNDATION_EXPORT void PVXDeleteTasks(NSArray<NSDictionary *> *tasks, void(^completion)(NSString * _Nullable error));','FOUNDATION_EXPORT void PVXDeleteTasks(NSArray<NSDictionary *> *tasks, void(^completion)(NSString * _Nullable error));\nFOUNDATION_EXPORT void PVXSaveTaskToFiles(NSDictionary *task);\nFOUNDATION_EXPORT void PVXApplyAutoSavePreferences(NSArray<NSDictionary*> *tasks);\nFOUNDATION_EXPORT void PVXCreateDownloadFolder(NSString *name, void(^ _Nullable completion)(BOOL ok, NSString * _Nullable error));')
p.write_text(s)
# TaskSupport exact targeted patches
p=P/'src/TaskSupport.m';s=p.read_text()
if '#import <Photos/Photos.h>' not in s:s=s.replace('#import <AVFoundation/AVFoundation.h>','#import <AVFoundation/AVFoundation.h>\n#import <Photos/Photos.h>',1)
s=s.replace('@"conversionProgress"] {','@"conversionProgress", @"height", @"width"] {',1)
start=s.index('static BOOL PVXQueueControl(');end=s.index('\nvoid PVXDeleteTasks',start)
old=s[start:end]
if 'static Control fn' not in old:
 new='''static BOOL PVXQueueControl(NSDictionary *task, NSString *action, NSError **error) {
    if (!PVXUUID(task[@"id"]) || ![@[@"delete", @"pause", @"resume", @"retry"] containsObject:action]) return NO;
    if ([task[@"kind"] isEqual:@"image"]) {
        if (![action isEqual:@"delete"]) return NO;
        NSString *request = NSUUID.UUID.UUIDString;
        BOOL ok = PVXAtomic(@{@"id":request, @"target":task[@"id"], @"action":@"delete", @"created":@(NSDate.date.timeIntervalSince1970)}, PVXPath([NSString stringWithFormat:@"plus-image-control/%@.plist", request]), error);
#if !defined(PVX_FOUNDATION_TEST)
        if (ok) notify_post("com.crctdd.pyvideo.plus.images.queue");
#endif
        return ok;
    }
    typedef BOOL (*Control)(NSString *, NSString *, NSError **);
    static Control fn; static dispatch_once_t once;
    dispatch_once(&once, ^{ fn=(Control)dlsym(RTLD_DEFAULT, "PVEnqueueControl"); });
    return fn ? fn(task[@"id"], action, error) : NO;
}'''
 s=s[:start]+new+s[end:]
# action all
if 'void PVXTaskActionAll(' not in s:
 marker='NSDictionary *PVXStorageSummary(void) {'
 insert='''void PVXTaskActionAll(NSArray<NSDictionary*> *tasks, NSString *action, void(^completion)(NSUInteger,NSString*)) {
    NSArray *copy=[tasks copy]?:@[];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSUInteger count=0; NSString *firstError=nil;
        for(NSDictionary *task in copy){ NSError *error=nil; if(PVXQueueControl(task,action,&error)) count++; else if(!firstError.length) firstError=error.localizedDescription?:@"部分任务操作未入队"; }
        dispatch_async(dispatch_get_main_queue(),^{if(completion)completion(count,firstError);});
    });
}
'''
 s=s.replace(marker,insert+marker,1)
# Replace stubs with concrete export settings functions, using existing share as fallback.
old='void PVXExportTaskToFiles(NSDictionary *task) { PVXExportTasks(@[task], nil); }\nvoid PVXSaveTaskToPhotos(NSDictionary *task) { PVXExportTasks(@[task], nil); }'
if old in s:
 new='''static NSString *PVXCloudDownloadsPath(void){
    NSString *home=NSHomeDirectory();
    NSArray *roots=@[[home stringByAppendingPathComponent:@"Library/Mobile Documents/com~apple~CloudDocs/Downloads"],[home stringByAppendingPathComponent:@"Library/Mobile Documents/com~apple~CloudDocs/下载项目"]];
    for(NSString *root in roots) if([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]) return root;
    return nil;
}
void PVXSaveTaskToFiles(NSDictionary *task) {
    NSString *source=PVXTaskLocalPath(task); if(!source.length){PVXAlert(@"保存失败",@"本地文件尚未准备完成。");return;}
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSString *dir=PVXCloudDownloadsPath(); NSError *error=nil; NSString *title=PVXSafeText(task[@"title"],80); if(!title.length)title=task[@"id"]?:@"下载文件"; title=[title stringByReplacingOccurrencesOfString:@"/" withString:@"_"]; NSString *ext=task[@"kind"]&&[task[@"kind"] isEqual:@"image"]?source.pathExtension:@"mp4"; NSString *dest=dir?[dir stringByAppendingPathComponent:[title stringByAppendingPathExtension:ext]]:nil; BOOL ok=dest&&[NSFileManager.defaultManager copyItemAtPath:source toPath:dest error:&error]; dispatch_async(dispatch_get_main_queue(),^{if(ok)PVXAlert(@"已保存到文件",@"文件已写入 iCloud 云碟下载项目。 ");else PVXExportTasks(@[task],nil);});
    });
}
void PVXSaveTaskToPhotos(NSDictionary *task) {
    NSString *path=PVXTaskLocalPath(task); if(!path.length){PVXAlert(@"保存失败",@"本地文件尚未准备完成。");return;}
    void(^save)(void)=^{[[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{if([task[@"kind"] isEqual:@"image"]){UIImage *image=[UIImage imageWithContentsOfFile:path];if(image)[PHAssetChangeRequest creationRequestForAssetFromImage:image];}else [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:[NSURL fileURLWithPath:path]];} completionHandler:^(BOOL ok,NSError *error){if(!ok)PVXAlert(@"保存到相册失败",error.localizedDescription?:@"系统未完成保存。");}];};
    if(@available(iOS 14.0,*))[[PHPhotoLibrary sharedPhotoLibrary] requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status){if(status==PHAuthorizationStatusAuthorized||status==PHAuthorizationStatusLimited)dispatch_async(dispatch_get_main_queue(),save);else PVXAlert(@"无法保存到相册",@"没有照片添加权限。");}];else [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status){if(status==PHAuthorizationStatusAuthorized)dispatch_async(dispatch_get_main_queue(),save);}];
}
BOOL PVXAutoSavePhotos(void){return [NSUserDefaults.standardUserDefaults boolForKey:@"com.crctdd.pyvideo.plus.autoPhotos"];}
void PVXSetAutoSavePhotos(BOOL enabled){[NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"com.crctdd.pyvideo.plus.autoPhotos"];}
void PVXApplyAutoSavePreferences(NSArray<NSDictionary*> *tasks){if(![NSUserDefaults.standardUserDefaults boolForKey:@"com.crctdd.pyvideo.plus.autoPhotos"]&&! [NSUserDefaults.standardUserDefaults boolForKey:@"com.crctdd.pyvideo.plus.autoFiles"])return;for(NSDictionary *task in tasks){if(!PVXComplete(task)||!PVXTaskLocalPath(task))continue;if([NSUserDefaults.standardUserDefaults boolForKey:@"com.crctdd.pyvideo.plus.autoPhotos"])PVXSaveTaskToPhotos(task);if([NSUserDefaults.standardUserDefaults boolForKey:@"com.crctdd.pyvideo.plus.autoFiles"])PVXSaveTaskToFiles(task);}}
void PVXCreateDownloadFolder(NSString *name,void(^completion)(BOOL,NSString*)){NSString *safe=PVXSafeText(name,80);BOOL valid=safe.length&&[safe rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\\\:"]].location==NSNotFound;dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSString *root=PVXRoot();NSError *error=nil;BOOL ok=valid&&root&&[NSFileManager.defaultManager createDirectoryAtPath:[root stringByAppendingPathComponent:[NSString stringWithFormat:@"files/%@",safe]] withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error];dispatch_async(dispatch_get_main_queue(),^{if(completion)completion(ok,error.localizedDescription);});});}'''
 s=s.replace(old,new,1)
p.write_text(s)
# Build framework
p=P/'build-macos.py';s=p.read_text();s=s.replace("'AVKit','ImageIO'","'AVKit','Photos','ImageIO'",1);p.write_text(s)
# simulator framework only if present
p=P/'tests/webkit-beta3-simulator.py';s=p.read_text();s=s.replace("'-framework', 'AVKit', '-framework', 'AVFAudio'","'-framework', 'AVKit', '-framework', 'Photos', '-framework', 'AVFAudio'",1);p.write_text(s)
print('backend patches applied')

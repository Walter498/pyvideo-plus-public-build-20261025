from pathlib import Path
P=Path('/var/minis/workspace/pyvideo-plus')
# Shared declarations
p=P/'src/PVXCommon.h';s=p.read_text()
s=s.replace('FOUNDATION_EXPORT void PVXTaskAction(NSDictionary *task, NSString *action);','''FOUNDATION_EXPORT void PVXTaskAction(NSDictionary *task, NSString *action);
FOUNDATION_EXPORT void PVXTaskActionAll(NSArray<NSDictionary*> *tasks, NSString *action, void(^ _Nullable completion)(NSUInteger count, NSString * _Nullable error));''',1)
s=s.replace('FOUNDATION_EXPORT void PVXDeleteTasks(NSArray<NSDictionary *> *tasks, void(^completion)(NSString * _Nullable error));','''FOUNDATION_EXPORT void PVXDeleteTasks(NSArray<NSDictionary *> *tasks, void(^completion)(NSString * _Nullable error));
FOUNDATION_EXPORT void PVXSaveTaskToFiles(NSDictionary *task);
FOUNDATION_EXPORT void PVXApplyAutoSavePreferences(NSArray<NSDictionary*> *tasks);
FOUNDATION_EXPORT void PVXCreateDownloadFolder(NSString *name, void(^ _Nullable completion)(BOOL ok, NSString * _Nullable error));''',1)
p.write_text(s)
# TaskSupport
p=P/'src/TaskSupport.m';s=p.read_text()
s=s.replace('#import <AVFoundation/AVFoundation.h>','#import <AVFoundation/AVFoundation.h>\n#import <Photos/Photos.h>',1)
s=s.replace('@"conversionProgress"] {','@"conversionProgress", @"height", @"width"] {',1)
old='''static BOOL PVXQueueControl(NSDictionary *task, NSString *action, NSError **error) {
    if (!PVXUUID(task[@"id"]) || ![@["delete", "pause", "resume", "retry"] containsObject:action]) return NO;
    if ([task[@"kind"] isEqual:@"image"]) {
        if (![action isEqual:@"delete"]) return NO;
        NSString *request = NSUUID.UUID.UUIDString;
        BOOL ok = PVXAtomic(@{"id":request, @"target":task[@"id"], @"action":@"delete", @"created":@(NSDate.date.timeIntervalSince1970)}, PVXPath([NSString stringWithFormat:@"plus-image-control/%@.plist", request]), error);
#if !defined(PVX_FOUNDATION_TEST)
        if (ok) notify_post("com.crctdd.pyvideo.plus.images.queue");
#endif
        return ok;
    }
    typedef BOOL (*Control)(NSString *, NSString *, NSError **);
    Control fn = (Control)dlsym(RTLD_DEFAULT, "PVEnqueueControl");
    return fn ? fn(task[@"id"], action, error) : NO;
}'''
new='''static BOOL PVXQueueControl(NSDictionary *task, NSString *action, NSError **error) {
    if (!PVXUUID(task[@"id"]) || ![@[ @"delete", @"pause", @"resume", @"retry" ] containsObject:action]) return NO;
    if ([task[@"kind"] isEqual:@"image"]) {
        // The image worker accepts pause/resume as a queued-state control.
        NSString *request = NSUUID.UUID.UUIDString;
        BOOL ok = PVXAtomic(@{@"id":request, @"target":task[@"id"], @"action":action, @"created":@(NSDate.date.timeIntervalSince1970)}, PVXPath([NSString stringWithFormat:@"plus-image-control/%@.plist", request]), error);
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
assert old in s
s=s.replace(old,new,1)
old='''void PVXTaskAction(NSDictionary *task, NSString *action) {
    if ([action isEqual:@"delete"]) {
        PVXDeleteTasks(@[task], ^(NSString *error) { if (error) PVXAlert(@"删除未完成", error); });
        return;
    }
    NSError *error = nil;
    if (!PVXQueueControl(task, action, &error)) PVXAlert(@"任务操作失败", @"下载服务接口不可用或操作不受支持");
}'''
new='''void PVXTaskAction(NSDictionary *task, NSString *action) {
    if ([action isEqual:@"delete"]) {
        PVXDeleteTasks(@[task], ^(NSString *error) { if (error) PVXAlert(@"删除未完成", error); });
        return;
    }
    NSError *error = nil;
    if (!PVXQueueControl(task, action, &error)) PVXAlert(@"任务操作失败", @"下载服务接口不可用或操作不受支持");
}
void PVXTaskActionAll(NSArray<NSDictionary*> *tasks, NSString *action, void(^completion)(NSUInteger,NSString*)) {
    NSArray *copy=[tasks copy]?:@[];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSUInteger count=0;NSString *firstError=nil;
        for(NSDictionary *task in copy){NSError *error=nil;if(PVXQueueControl(task,action,&error))count++;else if(!firstError.length)firstError=error.localizedDescription?:@"部分任务操作未入队";}
        dispatch_async(dispatch_get_main_queue(),^{if(completion)completion(count,firstError);});
    });
}'''
assert old in s
s=s.replace(old,new,1)
old='''void PVXExportTaskToFiles(NSDictionary *task) { PVXExportTasks(@[task], nil); }
void PVXSaveTaskToPhotos(NSDictionary *task) { PVXExportTasks(@[task], nil); }'''
new='''void PVXExportTaskToFiles(NSDictionary *task) { PVXExportTasks(@[task], nil); }
static NSString *PVXCloudDownloadsPath(void){
    NSString *home=NSHomeDirectory();
    NSArray *roots=@[[home stringByAppendingPathComponent:@"Library/Mobile Documents/com~apple~CloudDocs/Downloads"], [home stringByAppendingPathComponent:@"Library/Mobile Documents/com~apple~CloudDocs/下载项目"]];
    for(NSString *root in roots){if([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil])return root;}
    return nil;
}
void PVXSaveTaskToFiles(NSDictionary *task) {
    NSString *source=PVXTaskLocalPath(task);if(!source.length){PVXAlert(@"保存失败",@"本地文件尚未准备完成。 ");return;}
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSString *dir=PVXCloudDownloadsPath();NSError *error=nil;NSString *ext=task[@"kind"]&&[task[@"kind"] isEqual:@"image"]?[[source pathExtension] lowercaseString]:@"mp4";NSString *name=PVXSafeText(task[@"title"],80);if(!name.length)name=task[@"id"]?:@"下载文件";name=[name stringByReplacingOccurrencesOfString:@"/" withString:@"_"];NSString *dest=dir?[dir stringByAppendingPathComponent:[name stringByAppendingPathExtension:ext]]:nil;if(dest&&[NSFileManager.defaultManager fileExistsAtPath:dest])[NSFileManager.defaultManager removeItemAtPath:dest error:nil];BOOL ok=dir&&[NSFileManager.defaultManager copyItemAtPath:source toPath:dest error:&error];dispatch_async(dispatch_get_main_queue(),^{if(!ok)PVXAlert(@"保存到文件失败",error.localizedDescription?:@"iCloud 云碟下载项目不可写，请使用系统文件导出。 ");else PVXAlert(@"已保存到文件",@"文件已写入 iCloud 云碟的下载项目。 ");});
    });
}
void PVXSaveTaskToPhotos(NSDictionary *task) {
    NSString *path=PVXTaskLocalPath(task);if(!path.length){PVXAlert(@"保存失败",@"本地文件尚未准备完成。 ");return;}
    void(^save)(void)=^{[[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{if([task[@"kind"] isEqual:@"image"]){UIImage *image=[UIImage imageWithContentsOfFile:path];if(image)[PHAssetChangeRequest creationRequestForAssetFromImage:image];}else [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:[NSURL fileURLWithPath:path]];} completionHandler:^(BOOL ok,NSError *error){dispatch_async(dispatch_get_main_queue(),^{if(!ok)PVXAlert(@"保存到相册失败",error.localizedDescription?:@"系统未完成保存。 ");else PVXAlert(@"已保存到相册",@"媒体已直接保存到照片。 ");});}];};
    if(@available(iOS 14.0,*))[[PHPhotoLibrary sharedPhotoLibrary] requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status){if(status==PHAuthorizationStatusAuthorized||status==PHAuthorizationStatusLimited)dispatch_async(dispatch_get_main_queue(),save);else dispatch_async(dispatch_get_main_queue(),^{PVXAlert(@"无法保存到相册",@"没有照片添加权限。 ");});}];else [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status){if(status==PHAuthorizationStatusAuthorized)dispatch_async(dispatch_get_main_queue(),save);}];
}
BOOL PVXAutoSavePhotos(void){return [NSUserDefaults.standardUserDefaults boolForKey:@"com.crctdd.pyvideo.plus.autoPhotos"];}
void PVXSetAutoSavePhotos(BOOL enabled){[NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"com.crctdd.pyvideo.plus.autoPhotos"];}
static BOOL PVXAutoSaveFiles(void){return [NSUserDefaults.standardUserDefaults boolForKey:@"com.crctdd.pyvideo.plus.autoFiles"];}
static BOOL PVXAutoMark(NSDictionary *task,NSString *key){return [PVXMetadata(task[@"id"])[key] boolValue];}
static void PVXMarkAuto(NSDictionary *task,NSString *key){NSString *uuid=task[@"id"];if(!PVXUUID(uuid))return;NSMutableDictionary *m=[PVXMetadata(uuid) mutableCopy];m[@"id"]=uuid;m[key]=@YES;PVXAtomic(m,PVXMetadataPath(uuid),NULL);}
void PVXApplyAutoSavePreferences(NSArray<NSDictionary*> *tasks){NSArray *copy=[tasks copy];if(!PVXAutoSavePhotos()&&!PVXAutoSaveFiles())return;dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{for(NSDictionary *task in copy){if(!PVXComplete(task)||!PVXTaskLocalPath(task))continue;if(PVXAutoSaveFiles()&&!PVXAutoMark(task,@"autoFiles")){PVXSaveTaskToFiles(task);PVXMarkAuto(task,@"autoFiles");}if(PVXAutoSavePhotos()&&!PVXAutoMark(task,@"autoPhotos")){PVXSaveTaskToPhotos(task);PVXMarkAuto(task,@"autoPhotos");}}});}
void PVXCreateDownloadFolder(NSString *name,void(^completion)(BOOL,NSString*)){NSString *safe=PVXSafeText(name,80);BOOL valid=safe.length&&[safe rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\\\:"]].location==NSNotFound;dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSError *error=nil;NSString *root=PVXRoot();BOOL ok=valid&&root&&[NSFileManager.defaultManager createDirectoryAtPath:[root stringByAppendingPathComponent:[NSString stringWithFormat:@"files/%@",safe]] withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error];dispatch_async(dispatch_get_main_queue(),^{if(completion)completion(ok,error.localizedDescription);});});}'''
assert old in s
s=s.replace(old,new,1)
p.write_text(s)
# Worker image controls: add pause/resume handling while preserving delete behavior.
p=P/'worker/main.m';s=p.read_text()
s=s.replace('''!PVXID(c[@"target"]) ||
            ![c[@"action"] isEqual:@"delete"] || !PVXNumber(c[@"created"])''','''!PVXID(c[@"target"]) ||
            ![@[@"delete", @"pause", @"resume"] containsObject:c[@"action"]] || !PVXNumber(c[@"created"])''',1)
needle='''        j.state[@"state"] = @"deleting";
        j.state[@"url"] = @""; j.state[@"page"] = @"";'''
insert='''        NSString *controlAction=c[@"action"];
        if([controlAction isEqual:@"pause"]||[controlAction isEqual:@"resume"]){
            NSString *current=j.state[@"state"];
            if([controlAction isEqual:@"pause"] && [@[@"queued",@"downloading"] containsObject:current]){[j.task cancel];j.task=nil;j.state[@"state"]=@"paused";[self persist:j];}
            else if([controlAction isEqual:@"resume"] && [current isEqual:@"paused"]){j.state[@"state"]=@"queued";[self persist:j];}
            PVXRemove(self.controlFD,name);continue;
        }
        j.state[@"state"] = @"deleting";
        j.state[@"url"] = @""; j.state[@"page"] = @"";'''
assert needle in s
s=s.replace(needle,insert,1)
p.write_text(s)

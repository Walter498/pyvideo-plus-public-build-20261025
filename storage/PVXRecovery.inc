// Included by Storage.m; Agent dictionaries and lifecycle checks stay on main.
@interface PVXRecoveryJob : NSObject
@property(nonatomic,copy) NSString *uuid;
@property(nonatomic,copy) NSString *nonce;
@property(nonatomic,copy) NSDictionary *task;
@property(nonatomic) double expectedDuration;
@property(nonatomic) BOOL requireAudio;
@property(atomic) BOOL cancelled;
@property(nonatomic,strong) PVXNativeRemuxCancellation *cancellation;
@end
@implementation PVXRecoveryJob
@end

static dispatch_queue_t PVXRecoveryQueue;
static void PVXRecoverySetup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        PVXRecoveryQueue=dispatch_queue_create("com.crctdd.pyvideo.native-recovery",DISPATCH_QUEUE_SERIAL);
    });
}
static BOOL PVXRecoveryCurrent(id agent,PVXRecoveryJob *job) {
    if(job.cancelled||RecoveryExports[job.uuid]!=job)return NO;
    NSDictionary *live=[agent tasks][job.uuid];
    return live&&[live[@"state"] isEqual:@"remuxing"]&&[live[@"pvxRecoveryNonce"] isEqual:job.nonce]&&![agent clearingRequest];
}
static void PVXRecoveryRecord(id agent,PVXRecoveryJob *job,NSString *stage,NSString *failure) {
    NSMutableDictionary *live=[[[agent tasks] objectForKey:job.uuid] mutableCopy];
    if(!live)return;
    live[@"pvxRecoveryStage"]=stage;
    live[@"updated"]=@(NSDate.date.timeIntervalSince1970);
    if(failure.length)live[@"error"]=[NSString stringWithFormat:@"HLS 后处理失败（%@）：%@",stage,failure];
    [[agent tasks] setObject:live forKey:job.uuid];
    if(Persist)Persist(agent,@selector(persist:),live);
    if(Notify)Notify(Signal);
}
static void PVXRecoveryFinish(id agent,PVXRecoveryJob *job,NSString *temporary,BOOL valid,NSDictionary *details) {
    BOOL current=PVXRecoveryCurrent(agent,job);
    if(!current){
        unlink(temporary.fileSystemRepresentation);
        if(RecoveryExports[job.uuid]==job)[RecoveryExports removeObjectForKey:job.uuid];
        return;
    }
    NSString *destination=Path([NSString stringWithFormat:@"media/%@.mp4",job.uuid]);
    NSError *publishError=nil;
    if(valid) {
        int fd=open(temporary.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
        if(fd<0||fsync(fd)) {
            valid=NO;publishError=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        }
        if(fd>=0)close(fd);
        if(valid&&rename(temporary.fileSystemRepresentation,destination.fileSystemRepresentation)) {
            valid=NO;
            publishError=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        }
        if(valid&&!PVXSyncParent(destination.fileSystemRepresentation)) {
            valid=NO;
            publishError=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        }
    }
    NSMutableDictionary *result=[details mutableCopy]?:[NSMutableDictionary dictionary];
    result[@"event"]=valid?@"recovery-output-valid":@"recovery-output-invalid";
    result[@"nonce"]=job.nonce;
    result[@"version"]=@"1.5.0";
    if(publishError)result[@"error"]=publishError.localizedDescription;
    NSMutableDictionary *live=[[[agent tasks] objectForKey:job.uuid] mutableCopy];
    live[@"pvxRecoveryVersion"]=@"1.5.0";
    live[@"pvxRecoveryStage"]=valid?@"complete":@"failed";
    live[@"updated"]=@(NSDate.date.timeIntervalSince1970);
    struct stat st;
    if(valid&&!lstat(destination.fileSystemRepresentation,&st)&&S_ISREG(st.st_mode)) {
        live[@"state"]=@"ready";
        live[@"fileComplete"]=@YES;
        live[@"received"]=@(st.st_size);
        live[@"total"]=@(st.st_size);
        live[@"mediaBytes"]=@(st.st_size);
        live[@"engine"]=@"PVXLocalizer+AgentNativeRemux";
        live[@"engineVersion"]=@5;
        for(NSString *key in @[@"error",@"networkErrorCode",@"networkErrorDomain",@"validationIssue"])[live removeObjectForKey:key];
        if(details[@"videoWidth"])live[@"width"]=details[@"videoWidth"];
        if(details[@"videoHeight"])live[@"height"]=details[@"videoHeight"];
        if(details[@"duration"])live[@"duration"]=details[@"duration"];
    } else {
        live[@"state"]=@"failed";
        live[@"fileComplete"]=@NO;
        live[@"error"]=[NSString stringWithFormat:@"HLS 后处理失败：%@",result[@"error"]?:@"封装或输出验证未通过"];
        unlink(temporary.fileSystemRepresentation);
    }
    [[agent tasks] setObject:live forKey:job.uuid];
    BOOL persisted=Persist&&Persist(agent,@selector(persist:),live);
    result[@"taskPersisted"]=@(persisted);
    if(valid&&!persisted){
        live[@"state"]=@"failed";live[@"fileComplete"]=@NO;
        live[@"error"]=@"MP4 已校验并保留，但任务状态写入失败";
        [[agent tasks] setObject:live forKey:job.uuid];
        result[@"event"]=@"output-valid-state-write-failed";
    }
    PVXDiagnostic([NSString stringWithFormat:@"hls-%@-result",job.uuid],result);
    [RecoveryExports removeObjectForKey:job.uuid];
    if(Notify)Notify(Signal);
}

static void PVXRecoverFailedHLS(id agent,NSDictionary *task) {
    NSString *uuid=task[@"id"];
    if(!ValidID(uuid)||RecoveryExports[uuid]||[agent clearingRequest])return;
    PVXRecoverySetup();
    PVXRecoveryJob *job=[PVXRecoveryJob new];
    job.uuid=uuid;job.nonce=NSUUID.UUID.UUIDString;
    job.task=[task copy];job.cancellation=[PVXNativeRemuxCancellation new];
    RecoveryExports[uuid]=job;
    [RecoveryAttempted addObject:uuid];
    NSMutableDictionary *live=[task mutableCopy];
    live[@"state"]=@"remuxing";
    live[@"pvxRecoveryNonce"]=job.nonce;
    live[@"pvxRecoveryStage"]=@"localizing";
    live[@"pvxRecoveryVersion"]=@"1.5.0";
    live[@"updated"]=@(NSDate.date.timeIntervalSince1970);
    [[agent tasks] setObject:live forKey:uuid];
    if(Persist)Persist(agent,@selector(persist:),live);
    if(Notify)Notify(Signal);
    PVXDiagnostic([NSString stringWithFormat:@"hls-%@-start",uuid],@{
        @"event":@"recovery-started",@"version":@"1.5.0",@"nonce":job.nonce,
        @"segmentsDone":task[@"segmentsDone"]?:@0,@"segmentsTotal":task[@"segmentsTotal"]?:@0});
    NSString *temporary=Path([NSString stringWithFormat:@"media/%@.%@.recovery.mp4",uuid,job.nonce]);
    NSURL *root=[NSURL fileURLWithPath:Path(@"") isDirectory:YES];
    dispatch_async(PVXRecoveryQueue,^{@autoreleasepool {
        if(job.cancelled)return;
        NSError *error=nil;
        PVXHLSLocalizer *localizer=[PVXHLSLocalizer new];
        NSURL *playlist=[localizer localizeTask:job.task rootDirectory:root error:&error];
        if(!playlist){
            NSDictionary *details=@{@"stage":@"localize",@"error":error.localizedDescription?:@"HLS 资源闭包失败"};
            dispatch_async(dispatch_get_main_queue(),^{PVXRecoveryFinish(agent,job,temporary,NO,details);});
            return;
        }
        NSDictionary *summary=localizer.summary?:@{};
        job.expectedDuration=[summary[@"expectedDuration"] doubleValue];
        job.requireAudio=[summary[@"requireAudio"] boolValue];
        NSMutableDictionary *playlistDetails=[summary mutableCopy];
        playlistDetails[@"event"]=@"playlist-built";playlistDetails[@"nonce"]=job.nonce;
        PVXDiagnostic([NSString stringWithFormat:@"hls-%@-playlist",uuid],playlistDetails);
        __block BOOL current=NO;
        dispatch_sync(dispatch_get_main_queue(),^{
            current=PVXRecoveryCurrent(agent,job);
            if(current)PVXRecoveryRecord(agent,job,@"remuxing",nil);
        });
        if(!current){unlink(temporary.fileSystemRepresentation);return;}
        NSDictionary *nativeDetails=nil;NSString *nativeError=nil;
        BOOL remuxed=PVXNativeRemuxHLSWithCancellation(playlist.path,temporary,job.cancellation,&nativeDetails,&nativeError);
        NSMutableDictionary *remuxDetails=[nativeDetails mutableCopy]?:[NSMutableDictionary dictionary];
        remuxDetails[@"event"]=remuxed?@"remux-success":@"remux-failed";
        remuxDetails[@"nonce"]=job.nonce;
        if(nativeError.length)remuxDetails[@"error"]=nativeError;
        PVXDiagnostic([NSString stringWithFormat:@"hls-%@-remux",uuid],remuxDetails);
        dispatch_async(dispatch_get_main_queue(),^{
            if(!remuxed){PVXRecoveryFinish(agent,job,temporary,NO,remuxDetails);return;}
            if(!PVXRecoveryCurrent(agent,job)){PVXRecoveryFinish(agent,job,temporary,NO,@{});return;}
            PVXRecoveryRecord(agent,job,@"validating",nil);
            PVXValidateMediaFile(temporary,job.expectedDuration,job.requireAudio,^(BOOL valid,NSDictionary *details){
                PVXRecoveryFinish(agent,job,temporary,valid,details);
            });
        });
    }});
}
static BOOL PVXCompletedHLS(NSDictionary *task) {
    long long done=[task[@"segmentsDone"] longLongValue],total=[task[@"segmentsTotal"] longLongValue];
    return ValidID(task[@"id"])&&[task[@"hlsSourceURL"] isKindOfClass:NSString.class]&&total>0&&done==total;
}
static void PVXScanFailedHLS(id agent) {
    if([agent clearingRequest])return;
    for(NSDictionary *task in [[[agent tasks] allValues] copy]) {
        if(![task isKindOfClass:NSDictionary.class]||![task[@"state"] isEqual:@"failed"]||!PVXCompletedHLS(task))continue;
        if([task[@"pvxRecoveryVersion"] isEqual:@"1.5.0"]||[RecoveryAttempted containsObject:task[@"id"]])continue;
        PVXRecoverFailedHLS(agent,task);
    }
}
static BOOL (*OldControl)(id,SEL,id,id);
static BOOL PVXControlRecovery(id agent,SEL selector,id action,id uuid) {
    if(!ValidID(uuid)||![action isKindOfClass:NSString.class])return OldControl(agent,selector,action,uuid);
    NSDictionary *task=[agent tasks][uuid];
    PVXRecoveryJob *job=RecoveryExports[uuid];
    if(job&&[@[@"pause",@"delete"] containsObject:action]) {
        job.cancelled=YES;[job.cancellation cancel];
        [RecoveryExports removeObjectForKey:uuid];
    }
    if([@[@"retry",@"resume"] containsObject:action]&&PVXCompletedHLS(task)&&
       [@[@"failed",@"paused"] containsObject:task[@"state"]]&&!job) {
        [RecoveryAttempted removeObject:uuid];
        PVXRecoverFailedHLS(agent,task);
        return YES;
    }
    return OldControl(agent,selector,action,uuid);
}

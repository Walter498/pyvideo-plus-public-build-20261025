// Included by Storage.m; Agent dictionaries and lifecycle checks stay on main.
@interface PVXRecoveryJob : NSObject
@property(nonatomic,copy) NSString *uuid;
@property(nonatomic,copy) NSString *nonce;
@property(nonatomic,copy) NSDictionary *task;
@property(nonatomic) double expectedDuration;
@property(nonatomic) BOOL requireAudio;
@property(atomic) BOOL cancelled;
@property(nonatomic,strong) PVXNativeRemuxCancellation *cancellation;
@property(nonatomic,strong) NSURL *nativePlaylist;
@property(nonatomic,copy) NSString *stage;
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
    BOOL active=[live[@"pvxRecoveryActive"] boolValue];
    return live&&active&&[live[@"pvxRecoveryNonce"] isEqual:job.nonce]&&! [agent clearingRequest];
}
static void PVXRecoveryRecord(id agent,PVXRecoveryJob *job,NSString *stage,NSString *failure) {
    NSMutableDictionary *live=[[[agent tasks] objectForKey:job.uuid] mutableCopy];
    if(!live||!PVXRecoveryCurrent(agent,job))return;
    live[@"pvxRecoveryStage"]=stage;
    // Keep the original Agent protocol state; presentation and JSONL use the
    // distinct pvxRecoveryStage (waiting/preparing/remuxing/fallback/validating).
    if ([live[@"pvxRecoveryActive"] boolValue]) live[@"state"]=@"checking";
    live[@"updated"]=@(NSDate.date.timeIntervalSince1970);
    if(failure.length)live[@"error"]=[NSString stringWithFormat:@"HLS 后处理失败（%@）：%@",stage,failure];
    [[agent tasks] setObject:live forKey:job.uuid];
    if(Persist)Persist(agent,@selector(persist:),live);
    PVXLogEvent(live,YES);
    if(Notify)Notify(Signal);
}
static void PVXRecoveryHeartbeat(id agent,PVXRecoveryJob *job) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if(!PVXRecoveryCurrent(agent,job))return;
        PVXLogEvent([agent tasks][job.uuid],YES);
        PVXRecoveryHeartbeat(agent,job);
    });
}

static void PVXRecoveryFinish(id agent,PVXRecoveryJob *job,NSString *temporary,BOOL valid,NSDictionary *details) {
    if(job.nativePlaylist)PVXLibavInputCleanup(job.nativePlaylist);
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
    result[@"nonce"]=job.nonce;result[@"id"]=job.uuid;
    result[@"version"]=@"3.0.2";
    if(publishError)result[@"error"]=publishError.localizedDescription;
    NSMutableDictionary *live=[[[agent tasks] objectForKey:job.uuid] mutableCopy];
    live[@"pvxRecoveryVersion"]=@"3.0.2";
    live[@"pvxRecoveryActive"]=@NO;
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
    PVXLogEvent(live,NO);
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
    job.task=[task copy];job.cancellation=[PVXNativeRemuxCancellation new];job.stage=@"waiting";
    RecoveryExports[uuid]=job;
    [RecoveryAttempted addObject:uuid];
    NSMutableDictionary *live=[task mutableCopy];
    live[@"state"]=@"checking";
    live[@"pvxRecoveryActive"]=@YES;
    [live removeObjectsForKeys:@[@"error",@"networkErrorCode",@"networkErrorDomain",@"validationIssue"]];
    live[@"pvxRecoveryNonce"]=job.nonce;
    live[@"pvxRecoveryStage"]=@"waiting";
    live[@"pvxRecoveryVersion"]=@"3.0.2";
    live[@"updated"]=@(NSDate.date.timeIntervalSince1970);
    [[agent tasks] setObject:live forKey:uuid];
    if(Persist)Persist(agent,@selector(persist:),live);
    if(Notify)Notify(Signal);
    PVXRecoveryHeartbeat(agent,job);
    PVXDiagnostic([NSString stringWithFormat:@"hls-%@-start",uuid],@{
        @"event":@"recovery-started",@"version":@"3.0.2",@"nonce":job.nonce,
        @"segmentsDone":task[@"segmentsDone"]?:@0,@"segmentsTotal":task[@"segmentsTotal"]?:@0,
        @"id":uuid,@"recoveryActive":@YES,@"stage":@"waiting"});
    NSString *temporary=Path([NSString stringWithFormat:@"media/%@.%@.recovery.mp4",uuid,job.nonce]);
    NSURL *root=[NSURL fileURLWithPath:Path(@"") isDirectory:YES];
    dispatch_async(PVXRecoveryQueue,^{@autoreleasepool {
        if(job.cancelled)return;
        __block BOOL preparing=NO;
        dispatch_sync(dispatch_get_main_queue(),^{
            preparing=PVXRecoveryCurrent(agent,job);
            if(preparing){job.stage=@"preparing";PVXRecoveryRecord(agent,job,@"preparing",nil);}
        });
        if(!preparing)return;
        NSError *error=nil;
        PVXHLSLocalizer *localizer=[PVXHLSLocalizer new];
        NSURL *playlist=[localizer localizeTask:job.task rootDirectory:root error:&error];
        if(playlist)playlist=PVXLibavInput(playlist,&error);
        job.nativePlaylist=playlist;
        NSDictionary *inputReport=PVXLibavInputLastReport();
        if(inputReport){NSMutableDictionary *report=[inputReport mutableCopy];report[@"id"]=uuid;PVXDiagnostic([NSString stringWithFormat:@"hls-%@-input",uuid],report);}
        if(!playlist){
            NSMutableDictionary *details=[@{@"stage":@"localize",@"error":error.localizedDescription?:@"HLS 资源闭包失败",
                @"errorDomain":error.domain?:@"PVXHLSLocalizer",@"errorCode":@(error.code)} mutableCopy];
            if(error.userInfo[@"manifestTag"])details[@"manifestTag"]=error.userInfo[@"manifestTag"];
            dispatch_async(dispatch_get_main_queue(),^{PVXRecoveryFinish(agent,job,temporary,NO,details);});
            return;
        }
        NSDictionary *summary=localizer.summary?:@{};
        job.expectedDuration=[summary[@"expectedDuration"] doubleValue];
        job.requireAudio=[summary[@"requireAudio"] boolValue];
        NSMutableDictionary *playlistDetails=[summary mutableCopy];
        playlistDetails[@"id"]=uuid;playlistDetails[@"event"]=@"playlist-built";playlistDetails[@"nonce"]=job.nonce;
        PVXDiagnostic([NSString stringWithFormat:@"hls-%@-playlist",uuid],playlistDetails);
        __block BOOL current=NO;
        dispatch_sync(dispatch_get_main_queue(),^{
            current=PVXRecoveryCurrent(agent,job);
            if(current){job.stage=@"remuxing";PVXRecoveryRecord(agent,job,@"remuxing",nil);}
        });
        if(!current){PVXLibavInputCleanup(playlist);unlink(temporary.fileSystemRepresentation);return;}
        NSDictionary *nativeDetails=nil;NSString *nativeError=nil;
        BOOL remuxed=PVXNativeRemuxHLSWithCancellation(playlist.path,temporary,job.cancellation,&nativeDetails,&nativeError);
        BOOL concatAttempted=NO;
        if(!remuxed&&[nativeDetails[@"nativeReturn"] intValue]==-1094995529&&
           [playlist.pathExtension.lowercaseString isEqual:@"m3u8"]&&!job.cancelled){
            concatAttempted=YES;
            NSError *concatError=nil;__block NSUInteger lastConcatLog=0;__block unsigned long long concatBytes=0,lastConcatBytes=0;
            NSURL *concat=PVXLibavInputContinuousTS(playlist,^{ return job.cancelled; },^(NSUInteger done,NSUInteger total,unsigned long long bytes){
                concatBytes=bytes;
                if(done==total||done>=lastConcatLog+32||bytes>=lastConcatBytes+16*1024*1024){
                    lastConcatLog=done;lastConcatBytes=bytes;
                    PVXDiagnostic([NSString stringWithFormat:@"hls-%@-concat-progress",uuid],@{
                        @"id":uuid, @"event":@"continuous-ts-progress", @"stage":@"preparing",
                        @"segmentsDone":@(done), @"segmentsTotal":@(total), @"received":@(bytes)});
                }
            },&concatError);
            if(concat){
                NSDictionary *concatDetails=nil;NSString *concatText=nil;
                BOOL concatOK=PVXNativeRemuxHLSWithCancellation(concat.path,temporary,job.cancellation,&concatDetails,&concatText);
                NSMutableDictionary *combined=[concatDetails mutableCopy]?:[NSMutableDictionary dictionary];
                combined[@"inputMode"]=@"continuous-mpegts";
                combined[@"primaryInputMode"]=@"hls-m3u8";
                combined[@"primaryNativeReturn"]=nativeDetails[@"nativeReturn"]?:@(-1094995529);
                combined[@"concatBytes"]=@(concatBytes);
                if(!concatOK)combined[@"concatError"]=concatText?:@"连续 TS 原生封装失败";
                nativeDetails=combined;nativeError=concatText;remuxed=concatOK;
            } else {
                NSMutableDictionary *details=[nativeDetails mutableCopy]?:[NSMutableDictionary dictionary];
                details[@"concatInputRejected"]=concatError.localizedDescription?:@"连续 TS 输入不适用";
                details[@"concatBytes"]=@(concatBytes);nativeDetails=details;
            }
        }
        NSMutableDictionary *remuxDetails=[nativeDetails mutableCopy]?:[NSMutableDictionary dictionary];
        remuxDetails[@"event"]=remuxed?@"remux-success":@"remux-failed";
        remuxDetails[@"concatAttempted"]=@(concatAttempted);
        remuxDetails[@"nonce"]=job.nonce;remuxDetails[@"id"]=uuid;
        if(nativeError.length)remuxDetails[@"error"]=nativeError;
        PVXDiagnostic([NSString stringWithFormat:@"hls-%@-remux",uuid],remuxDetails);
        dispatch_async(dispatch_get_main_queue(),^{
            if(!remuxed){PVXRecoveryFinish(agent,job,temporary,NO,remuxDetails);return;}
            if(!PVXRecoveryCurrent(agent,job)){PVXRecoveryFinish(agent,job,temporary,NO,@{});return;}
            job.stage=@"validating";PVXRecoveryRecord(agent,job,@"validating",nil);
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
        if(![task isKindOfClass:NSDictionary.class]||!PVXCompletedHLS(task))continue;
        BOOL active=[task[@"pvxRecoveryActive"] boolValue];
        BOOL failed=[task[@"state"] isEqual:@"failed"];
        if(!failed&&!active)continue;
        if(!active&&([task[@"pvxRecoveryVersion"] isEqual:@"3.0.2"]||[RecoveryAttempted containsObject:task[@"id"]]))continue;
        if(active&&!RecoveryExports[task[@"id"]]){
            [RecoveryAttempted removeObject:task[@"id"]];
            PVXRecoverFailedHLS(agent,task);
        } else if(failed&&!RecoveryExports[task[@"id"]]) {
            if([task[@"pvxRecoveryVersion"] isEqual:@"3.0.2"]||[RecoveryAttempted containsObject:task[@"id"]])continue;
            PVXRecoverFailedHLS(agent,task);
        }
    }
}
static BOOL (*OldControl)(id,SEL,id,id);
static BOOL PVXControlRecovery(id agent,SEL selector,id action,id uuid) {
    if(!ValidID(uuid)||![action isKindOfClass:NSString.class])return OldControl(agent,selector,action,uuid);
    NSDictionary *task=[agent tasks][uuid];
    PVXRecoveryJob *job=RecoveryExports[uuid];
    if(job&&[action isEqual:@"resume"])return YES;
    if(job&&[@[@"pause",@"delete"] containsObject:action]) {
        job.cancelled=YES;[job.cancellation cancel];
        NSMutableDictionary *cancelled=[[task mutableCopy]?:[NSMutableDictionary dictionary] mutableCopy];
        cancelled[@"pvxRecoveryActive"]=@NO;cancelled[@"state"]=[action isEqual:@"pause"]?@"paused":@"deleted";
        cancelled[@"pvxRecoveryStage"]=@"cancelled";cancelled[@"updated"]=@(NSDate.date.timeIntervalSince1970);PVXLogEvent(cancelled,NO);
        if(Persist)Persist(agent,@selector(persist:),cancelled);
        [[agent tasks] setObject:cancelled forKey:uuid];
        [RecoveryExports removeObjectForKey:uuid];
    }
    if([@[@"retry",@"resume"] containsObject:action]&&PVXCompletedHLS(task)&&
       ([task[@"pvxRecoveryActive"] boolValue]||[@[@"failed",@"paused"] containsObject:task[@"state"]])&&!job) {
        [RecoveryAttempted removeObject:uuid];
        PVXRecoverFailedHLS(agent,task);
        return YES;
    }
    return OldControl(agent,selector,action,uuid);
}

// Original startWorker reconciles interrupted remuxing tasks back to queued.
// Preserve complete fragments across process restart: do not enter network job.
static void (*OldStartTask)(id,SEL,id,id);
static void PVXStartTaskRecovery(id agent,SEL selector,NSDictionary *task,id hlsURL) {
    if(PVXCompletedHLS(task)&&![task[@"fileComplete"] boolValue]&&
       [task[@"state"] isEqual:@"queued"]&&![agent clearingRequest]) {
        PVXRecoverFailedHLS(agent,task);
        return;
    }
    if(OldStartTask)OldStartTask(agent,selector,task,hlsURL);
}

static void (*PVXOldAVExport)(id,SEL,void(^)(void));
static void PVXObserveAVExport(AVAssetExportSession *session,SEL selector,void(^completion)(void)) {
    NSString *leaf=[session.outputURL.lastPathComponent copy];
    if(![leaf hasSuffix:@".recovery.mp4"]){PVXOldAVExport(session,selector,completion);return;}
    NSString *preset=[session.presetName copy];
    NSString *outputPath=[session.outputURL.path copy];
    dispatch_async(dispatch_get_main_queue(),^{
        for(PVXRecoveryJob *job in [RecoveryExports.allValues copy]) {
            NSString *expected=[NSString stringWithFormat:@"%@.%@.recovery.mp4",job.uuid,job.nonce];
            id agent=Worker;
            if([leaf isEqual:expected]&&[outputPath isEqual:Path([@"media" stringByAppendingPathComponent:expected])]&&agent&&PVXRecoveryCurrent(agent,job)){
                job.stage=@"fallback";PVXRecoveryRecord(agent,job,@"fallback",nil);
                PVXLogEvent(@{@"id":job.uuid,@"stage":@"fallback",@"event":[preset isEqual:AVAssetExportPresetPassthrough]?@"avfoundation-passthrough":@"avfoundation-highestQuality"},NO);
            }
        }
    });
    __weak AVAssetExportSession *weakSession=session;
    PVXOldAVExport(session,selector,^{
        AVAssetExportSession *finished=weakSession;
        NSError *error=finished.error;
        NSError *underlying=error.userInfo[NSUnderlyingErrorKey];
        NSNumber *code=@(error.code),*underlyingCode=@([underlying isKindOfClass:NSError.class]?underlying.code:0);
        NSNumber *status=@(finished.status);
        // Capture only codes/status, never NSError userInfo or signed URLs.
        dispatch_async(dispatch_get_main_queue(),^{
            for(PVXRecoveryJob *job in [RecoveryExports.allValues copy]) {
                NSString *expected=[NSString stringWithFormat:@"%@.%@.recovery.mp4",job.uuid,job.nonce];
                if([leaf isEqual:expected]&&[outputPath isEqual:Path([@"media" stringByAppendingPathComponent:expected])])
                    PVXLogEvent(@{@"id":job.uuid,@"stage":@"fallback",@"event":[preset isEqual:AVAssetExportPresetPassthrough]?@"avfoundation-passthrough-finished":@"avfoundation-highestQuality-finished",@"errorCode":code,@"underlyingErrorCode":underlyingCode,@"exportStatus":status},NO);
            }
        });
        if(completion)completion();
    });
}

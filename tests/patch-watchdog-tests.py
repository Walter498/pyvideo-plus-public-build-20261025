from pathlib import Path
P=Path(__file__).resolve().parents[1]
p=P/'src/TaskSupport.m';s=p.read_text();a='static NSDictionary *PVXPlist(NSString *path) {';assert a in s;s=s.replace(a,'''#if defined(PVX_WATCHDOG_TEST)
static NSUInteger PVXTestMainDiskReads;
static NSUInteger PVXTestBackgroundScans;
#endif
'''+a+'''
#if defined(PVX_WATCHDOG_TEST)
    if(NSThread.isMainThread)PVXTestMainDiskReads++;
#endif''',1)
a='static NSArray<NSDictionary *> *PVXScanVideoTasks(void) {';assert a in s;s=s.replace(a,a+'''
#if defined(PVX_WATCHDOG_TEST)
    if(!NSThread.isMainThread)PVXTestBackgroundScans++;
#endif''',1);p.write_text(s)
p=P/'tests/webkit-beta3-ui.m';s=p.read_text();s=s.replace('#define PVX_TEST 1','#define PVX_TEST 1\n#define PVX_WATCHDOG_TEST 1',1)
a='- (void)verifyShare {';idx=s.index(a)
code='''- (void)verifyWatchdogSnapshot {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSString *source=PVXTaskLocalPath(self.ready);
        for(int i=0;i<180;i++){
            NSString *uuid=[NSString stringWithFormat:@"77777777-7777-4777-8777-%012d",i];
            NSString *file=PVXPath([NSString stringWithFormat:@"image-media/%@.original",uuid]);
            if(!PVXRegular(file))[NSFileManager.defaultManager copyItemAtPath:source toPath:file error:NULL];
            Check(PVXAtomic(@{@"id":uuid,@"kind":@"image",@"title":@"Watchdog regression fixture",@"created":@1,@"state":@"ready"},PVXPath([NSString stringWithFormat:@"image-tasks/%@.plist",uuid]),NULL),@"stress task fixture created");
        }
        dispatch_async(dispatch_get_main_queue(),^{
            NSUInteger readsBefore=PVXTestMainDiskReads,scansBefore=PVXTestBackgroundScans;
            CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();__block BOOL heartbeat=NO;
            PVXRequestTaskSnapshot(^(NSArray *rows,NSDictionary *storage){
                Check(rows.count>=182,@"large task set asynchronously scanned");
                Check(PVXTestMainDiskReads==readsBefore,@"background task snapshot performs zero main-thread plist reads");
                Check(PVXTestBackgroundScans>scansBefore,@"production worker queue executes disk scan");
                Check(heartbeat,@"main-thread heartbeat runs while disk snapshot is in flight");
                Record(@"webkit-beta3-result.txt",[@"PASS system native player and watchdog regression: exact Apple controller, real H264 playback/seek/dismiss; async large task snapshot, zero main-thread plist reads, responsive main heartbeat; existing media pipeline passed\\n" stringByAppendingString:[Checks componentsJoinedByString:@"\\n"]]);
            });
            Check(CFAbsoluteTimeGetCurrent()-start<.1,@"snapshot scheduling returns immediately without scanning on main");
            dispatch_async(dispatch_get_main_queue(),^{heartbeat=YES;});
        });
    });
}
'''
s=s[:idx]+code+s[idx:];p.write_text(s)
p=P/'tests/system-player-test.inc';s=p.read_text();a='Record(@"webkit-beta3-result.txt",[@"PASS existing real media pipeline plus native Apple fullscreen player, H264 decoding, playback time, seeking and dismissal cleanup; no custom transport or PiP controller\\n" stringByAppendingString:[Checks componentsJoinedByString:@"\\n"]]);';assert a in s;s=s.replace(a,'[self verifyWatchdogSnapshot];',1);p.write_text(s)

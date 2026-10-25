from pathlib import Path
p=Path('/var/minis/workspace/pyvideo-plus/storage/Storage.m');s=p.read_text()
s=s.replace('static void (*OldClear)(id, SEL);','static void (*OldClear)(id, SEL);\nstatic void (*OldPump)(id, SEL);\nstatic void (*AgentStartTask)(id, SEL, id, id);',1)
# Insert scheduler hook before old Clear.
needle='static void (*OldClear)(id, SEL);'
idx=s.index(needle)
code='''static NSInteger PVXConfiguredParallel(void){NSDictionary *v=[NSDictionary dictionaryWithContentsOfFile:Path(@"plus-preferences.plist")];NSInteger n=[v[@"parallelDownloads"] integerValue];return n>=1&&n<=15?n:5;}
static void PVXPumpWithConfiguredLimit(id self, SEL cmd){
    OldPump(self,cmd);
    if(![self workerMode]||![self reconciled]||![self memoryReady]||!AgentStartTask)return;
    NSMutableDictionary *tasks=[self tasks],*jobs=[self valueForKey:@"jobs"],*checks=[self valueForKey:@"checks"];if(!tasks||!jobs||!checks)return;
    NSInteger limit=PVXConfiguredParallel(),active=(NSInteger)jobs.count+(NSInteger)checks.count;if(active>=limit)return;
    for(NSDictionary *task in [tasks.allValues copy]){
        if(active>=limit||![task isKindOfClass:NSDictionary.class]||![task[@"state"] isEqual:@"queued"]||!ValidID(task[@"id"])||jobs[task[@"id"]]||checks[task[@"id"]])continue;
        NSString *hls=[task[@"hlsSourceURL"] isKindOfClass:NSString.class]?task[@"hlsSourceURL"]:nil;
        AgentStartTask(self,NSSelectorFromString(@"startTask:hlsURL:"),task,hls);active++;
    }
}
'''
s=s[:idx]+code+s[idx:]
# Signature declarations and checks
s=s.replace('const char *removeArgs[] = {"@", "^@"};','const char *removeArgs[] = {"@", "^@"};\n        const char *twoObjects[] = {"@", "@"};',1)
s=s.replace('!Signature(c, @selector(exportReady), "v", 0, NULL) ||','!Signature(c, @selector(exportReady), "v", 0, NULL) ||\n            !Signature(c, @selector(pump), "v", 0, NULL) ||\n            !Signature(c, NSSelectorFromString(@"startTask:hlsURL:"), "v", 2, twoObjects) ||',1)
s=s.replace('Hook(c, @selector(tasks), (IMP)TasksView, (IMP *)&OldTasks);','Hook(c, @selector(tasks), (IMP)TasksView, (IMP *)&OldTasks);\n        Hook(c, @selector(pump), (IMP)PVXPumpWithConfiguredLimit, (IMP *)&OldPump);\n        AgentStartTask = (void *)class_getMethodImplementation(c, NSSelectorFromString(@"startTask:hlsURL:"));',1)
p.write_text(s)

from pathlib import Path
p=Path('/var/minis/workspace/pyvideo-plus/src/TaskSupport.m');s=p.read_text()
old='void PVXApplyAutoSavePreferences(NSArray<NSDictionary*> *tasks){if(![NSUserDefaults.standardUserDefaults boolForKey:@"com.crctdd.pyvideo.plus.autoPhotos"]&&! [NSUserDefaults.standardUserDefaults boolForKey:@"com.crctdd.pyvideo.plus.autoFiles"])return;for(NSDictionary *task in tasks){if(!PVXComplete(task)||!PVXTaskLocalPath(task))continue;if([NSUserDefaults.standardUserDefaults boolForKey:@"com.crctdd.pyvideo.plus.autoPhotos"])PVXSaveTaskToPhotos(task);if([NSUserDefaults.standardUserDefaults boolForKey:@"com.crctdd.pyvideo.plus.autoFiles"])PVXSaveTaskToFiles(task);}}'
new='''void PVXApplyAutoSavePreferences(NSArray<NSDictionary*> *tasks){
    BOOL photos=[NSUserDefaults.standardUserDefaults boolForKey:@"com.crctdd.pyvideo.plus.autoPhotos"],files=[NSUserDefaults.standardUserDefaults boolForKey:@"com.crctdd.pyvideo.plus.autoFiles"];if(!photos&&!files)return;
    for(NSDictionary *task in tasks){if(!PVXComplete(task)||!PVXTaskLocalPath(task)||![PVXUUID(task[@"id"])])continue;NSMutableDictionary*m=[PVXMetadata(task[@"id"]) mutableCopy];m[@"id"]=task[@"id"];if(photos&&! [m[@"autoPhotos"] boolValue]){m[@"autoPhotos"]=@YES;PVXAtomic(m,PVXMetadataPath(task[@"id"]),NULL);PVXSaveTaskToPhotos(task);}if(files&&! [m[@"autoFiles"] boolValue]){m[@"autoFiles"]=@YES;PVXAtomic(m,PVXMetadataPath(task[@"id"]),NULL);PVXSaveTaskToFiles(task);}}
}'''
assert old in s;s=s.replace(old,new,1);p.write_text(s)

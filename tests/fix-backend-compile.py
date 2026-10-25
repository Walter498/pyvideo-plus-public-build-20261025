from pathlib import Path
p=Path('/var/minis/workspace/pyvideo-plus/src/TaskSupport.m');s=p.read_text()
s=s.replace('BOOL PVXAutoSavePhotos(void) { return NO; }\nvoid PVXSetAutoSavePhotos(BOOL enabled) { (void)enabled; }','',1)
s=s.replace('[[PHPhotoLibrary sharedPhotoLibrary] requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:', '[PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:',1)
p.write_text(s)

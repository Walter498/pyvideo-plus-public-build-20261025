# Beta2 contract
Project /var/minis/workspace/pyvideo-plus. Original analysis /var/minis/workspace/pyvideo-0.0.3-analysis. Read own assigned files only, avoid racing other modules. User explicitly clarified ONLY Safari in-app picture-in-picture/player, NO system host injection. Screenshot dark list downloads manager + optional automatic Photos and Files export. No device install. Build via GitHub macos-15 Apple arm64e compile. Local syntax SDK16.5 /root/theos/sdks/iPhoneOS16.5.sdk or SDK26.5 with SubFrameworks. Do not claim runtime proof.

Parent owns src/Main.m src/PVXCommon.h src/Images.m worker/main.m build/package files. New modules:
- UI agent owns src/Downloads.m (UIKit list controller; replace PVXOpenDownloads routing parent). exported void PVXShowDownloads(void). Use same screenshot list: dark background #111/#222, header close Download/Collect tabs, select/settings, storage indicator, search, sections with covers format badge/title/status/size progress and trailing ellipsis. Responsive touch targets44pt. Preserve original candidate downloads by PVXBrowser candidates, download:completion:; rows read tasks; more tasks menus dispatch original PVEnqueueControl via parent helper.
- Storage agent owns storage/Storage.m as standalone dylib injected into original PyVideoAgent using added LC_LOAD_DYLIB (parent handles patch/sign/package). It must intercept automatic export correctly, retain ready local files while disabled, manual Photos command optional. Shared prefs root/plus-preferences.plist {autoSavePhotos: bool} default YES. New tasks transition ready (original), no original export when NO. Manual photo requests via image? separate root/plus-manual-photos/<UUID>.plist / notification com.crctdd.pyvideo.plus.storage. Need support manual save one task even when autoOFF, prevent fallback mass saving; can implement by exportReady temporary filtered task dict scoped original call if proven state safe. Parent can implement command producer to match documented.
- PiP agent owns src/PiP.m (standalone system host dylib) + src/PiPClient.m (Safari companion) if needed. Only confirmed actual PiP hosting class/selector, supported runtime process gates. Need actual in-window trigger (long press / button menu) asks Safari open download manager / download current via Darwin notify signal. Do not affect unrelated apps PiP: must identify Safari playback. Report uncertainties.

Shared parent APIs guaranteed in PVXCommon.h:
existing PVXBrowser/PVXCurrentWebView/PVXStateRoot/PVXPresenter/PVXGet/PVXHook/PVXAlert/PVXShowImages
new:
void PVXShowDownloads(void); // UI module
NSArray<NSDictionary*> *PVXReadVideoTasks(void); // parent bounded safe task snapshot
void PVXTaskAction(NSDictionary *task, NSString *action); // pause/resume/retry/delete original PVEnqueueControl
BOOL PVXAutoSavePhotos(void); void PVXSetAutoSavePhotos(BOOL on);
void PVXExportTaskToFiles(NSDictionary *task); // parent UIDocumentPicker export local original/compatible path
void PVXSaveTaskToPhotos(NSDictionary *task); // parent manual storage command
void PVXFetchTaskThumbnail(NSDictionary *task, void(^completion)(UIImage * _Nullable)); // parent bounded cached load
NSDictionary *PVXTaskPresentation(NSDictionary *task); // parent mapping {status,symbol,tint:UIColor,size,format,progress NSNumber}

UI may use original PVBrowser candidates (fresh refresh), original tasks via parent APIs. Manual photo option only ready/completed local files; saved original auto Photos deletes file so Files disabled if absent. Parent ensures future retain originals default? New Storage must avoid deleting local original on Photos success if Files export desired; document design retained downloads and disk controls.

Do not modify other module files; docs/tests within own evidence subpaths. Module functions real code no stubs. Report exact tests and limitation. Avoid tests that simply search own implementation without behavior value.

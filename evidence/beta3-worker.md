# Beta3 worker/storage evidence

Changed only worker/main.m, storage/Storage.m, tests/photo-worker.py, tests/storage-beta2/mock.m and this evidence file. Other agents' concurrent changes are outside this work. No install or device execution was performed.

## Photos behavior

- Video Storage Export never calls OldExport, regardless of missing, malformed, YES or NO historical preferences. It drains obsolete plus-manual-photos/<UUID>.plist and .plist.claimed leaves without acting on them. No settings reader remains in Storage.m.
- Video download/conversion core is unchanged. Ready media remains in the original worker's normal location. The original tasks getter and original active-save Finish/Remove/Delete/Clear retention hooks are retained. A Beta2 Photos save that was already running can finish naturally, including original/compatible preservation and retained-file collision fallback. No new transaction is scheduled by this add-on.
- Image autoSavePhotos always returns NO. Pump schedules only downloads (maximum two), never save, and does not consult preferences or manualPhotos. save: is inert. No Photos import, authorization/status query or performChanges code remains in the image worker.
- Image legacy plus-image-photos commands are dropped even before their corresponding task arrives; durable manualPhotos flags are removed. They cannot revive failed/ready jobs or authorize background saves.
- Verified image originals and UTI/extension metadata still persist at ready; ready backlog does not limit download scheduling. Foreground UIActivityViewController export belongs to the parent/UI implementation.
- Historical image saving snapshots recover as uncertain, without replay. Historical saved snapshots retain existing cleanup behavior. An already executing older worker binary finishes using its own existing code; this source does not issue any new Photos transaction.

## Image delete interface

Producer atomically writes a binary plist at the EXISTING mapped root:

    plus-image-control/<requestUUID>.plist
    { id: requestUUID, target: taskUUID, action: "delete", created: unixSeconds }

id and target must be UUID strings; filename UUID must exactly equal id. Only those four keys are accepted; created must be a finite non-boolean number >= 0. The existing bounded binary-only reader is used: maximum 2 MiB, regular file owned by effective UID, single link, no symlink/nonblocking open, exact complete read and binary plist decoding; file mode normalized to 0600. The new control directory uses the existing owner-checked O_DIRECTORY/O_NOFOLLOW path and 0700 mode. Original canonical root + jbroot mapping is unchanged.

The existing queue notification com.crctdd.pyvideo.plus.images.queue or 2-second polling scans controls on main, before importing inbox jobs. No additional notification protocol is necessary.

For queued, active, completed, failed or even not-yet-imported UUIDs:

1. Persist deleting before removing bytes. For unknown UUIDs, create a minimal permanent task record so a pending inbox publication cannot be reimported.
2. Detach the task identifier from active, clear job.task/ready/request, then cancel NSURLSessionDownloadTask. All delegates and transitions run on main.
3. Remove image-inbox/<taskUUID>.plist, image-media/<taskUUID>.original, and obsolete plus-image-photos/<taskUUID>.plist; fsync each directory. Clear source/page/manual intent in the snapshot.
4. Persist deleted only after every cleanup succeeds. Otherwise remain deleting with error "图片删除未完成，将重试清理". The command is consumed after durable cleanup ownership passes to the task snapshot. Failed state persistence stops new scheduling; restart retries durable deleting cleanup.
5. Startup snapshot whitelist accepts deleting/deleted and resumes cleanup for both. Runtime retries deleting on subsequent scans. Task tombstones are never removed, so duplicate inbox UUIDs are never downloaded again.

Late progress, download-finish and task-completion callbacks cannot locate a detached active job. Explicit deleting/deleted guards also prevent a failed persistence edge from re-marking a task failed, queued, ready or writing its original again. fail: itself refuses to overwrite deletion states.

Parent/export integration must observe image-tasks/<taskUUID>.plist state == deleted before removing organizer metadata, sidecar copies/hardlinks or reporting deletion success. The worker deliberately never edits parent-owned sidecars. deleting is an intermediate/retry state, not success; deleting.error should be surfaced on timeout. No retry/requeue action is introduced.

## Verification actually performed

- `python3 tests/photo-worker.py`: 13 tests passed. Tests execute real SDK16.5 and SDK26.5 arm64e ARC object compilation with -Wall -Wextra -Werror (existing unused-parameter allowance), real binary-plist roundtrips, cookie/redirect and crash-recovery models, no-Photos source entrypoint checks, old preference/manual-command denial, retained metadata/backlog checks, delete lifecycle/late-callback models and production ordering/validation guards.
- `sh tests/storage-beta2/check.sh`: native production disk primitive tests passed: idempotence, collision, source/destination symlink, empty/missing files, ENOSPC rollback and short writes. Storage.m passed strict SDK16.5 arm64 syntax and actual object compilation. The production-including Foundation mock passed strict SDK16.5 syntax compilation.
- tests/storage-beta2/mock.m now asserts OldExport call count stays zero with absent/YES/NO/malformed preferences and obsolete manual commands. Ready tasks remain ready. Already-active Beta2 saves are explicitly seeded to exercise actual Finish retention, collision fallback, failed-save passthrough and scoped Remove protection. Old manual-gate tests were adapted rather than skipped or disabled.
- This environment is Linux. The macOS Foundation execution branch remains enabled in check.sh but was NOT executed here. No claim of Foundation runtime, UI, Photos, network or device verification is made.

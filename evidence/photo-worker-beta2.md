# Image worker Beta2: retained originals and optional Photos

Scope: only `worker/main.m`, `tests/photo-worker.py`, and this evidence file were changed. Main/Images/Common, storage, build and package modules were not modified. No iOS executable was launched or installed.

## Parent integration contract

All paths below are relative to the same mapped state root already used by the image producer and worker (normally jbroot-mapped `/var/mobile/Library/Application Support/com.crctdd.pyvideo`). Preserve the UUID spelling from the task `id`; filenames are not case-normalized.

- Preference: atomically write a **binary** plist `plus-preferences.plist`, with `autoSavePhotos` a true plist boolean. Missing file/key, invalid file, or a nonboolean value defaults to YES. Existing other preference keys are tolerated. OFF keeps downloaded images in `ready`; ON allows all ready images to enter the serialized Photos queue. Preference changes do not cancel a Photos transaction already begun.
- Manual image Photos command: atomically write a **binary** plist `plus-image-photos/<UUID>.plist` containing exactly `{id: <same UUID string>, created: <finite nonnegative Unix seconds number>}`. Directory mode 0700, file mode 0600, owned by mobile, single hard link; use a same-directory temporary file, fsync, rename, and directory fsync. The worker creates the command directory if missing. This is separate from video's `plus-manual-photos` interface.
- After preference or command publication, post Darwin notification `com.crctdd.pyvideo.plus.images.queue`. A two-second worker polling timer also catches updates. Worker snapshot changes continue posting `com.crctdd.pyvideo.plus.images.tasks`.
- Manual commands persist `manualPhotos: true` in the individual task before command deletion. They can arrive while queued/downloading and survive restart. They never globally enable automatic Photos. A failed Photos attempt can be manually retried if its typed original still validates. Commands for saved, saving, or uncertain tasks are consumed without starting another save. Commands for an unknown UUID wait for its inbox/task publication. Malformed commands are ignored. Parent should produce commands, not edit worker-owned task plists.
- Export source: `image-media/<task.id>.original`. It contains the exact downloaded file, including animation, with no JPEG conversion. This file is retained after Photos success as well as while ready. The worker does not create a document picker: the parent exports a copy through its foreground Files UI.
- Snapshot `uti` is an ImageIO-detected UTI string, for example `public.jpeg`, `public.png`, `com.compuserve.gif`, or `public.heic`. Snapshot `extension` is that UTI's preferred extension, e.g. jpg/png/gif/heic, falling back to img. It is a detected format extension, not an untrusted URL suffix. Parent can copy to an export staging filename `<UUID>.<extension>` and use `uti` for content type. Do not rename/move the worker original. Old saved snapshots can lack these new keys and their original might already have been deleted by the old worker; verify existence and detect type if needed.
- Parent should offer Files for ready/saved tasks only after validating a regular local file exists; failed/uncertain originals may also be exported after equivalent independent verification, but uncertain must never be offered as an automatic Photos retry. Suggested Chinese labels: queued=等待下载, downloading=正在下载, ready=已下载，待保存, saving=正在保存到相册, saved=已保存到相册, failed=处理失败, uncertain=请核对相册. Native task `error` strings are Chinese. Machine state values remain stable English tokens.

## Persistence, privacy and recovery

After download verification, the worker fsyncs the original and media directory before publishing durable state `ready`. It stores detected UTI/extension, byte counts, and only small task metadata in memory; it does not retain NSData, decoded images, or ImageIO sources in ready job records. Two active NSURLSession downloads remain the hard concurrency limit. Ready backlog no longer limits subsequent downloads, including when auto Photos is OFF.

Ready startup optionally reads an existing inbox request, verifies the retained file's regular-file/owner/single-link/size and ImageIO constraints, reconstructs `mediaName`/UTI/extension, and marks the job ready. Credentials are not required for this recovery. Missing/corrupt originals become failed. Ready and saved cleanup removes inbox credentials, releases the request dictionary, and clears source/page signed URLs; original retention is explicitly parameterized and enabled for these paths.

Photos remains serialized. The preference is checked both before scheduling and again at the asynchronous authorization continuation. No background authorization prompt is requested: the worker checks AddOnly authorization and fails with a Chinese retained-original message if access is unavailable. Private PhotosAdd entitlement/foreground authorization provisioning remains an external deployment concern.

Before `performChanges`, `manualPhotos` is consumed and a durable `saving` snapshot is written. Restart maps saving to uncertain; neither auto ON nor manual commands revive uncertain. A successful Photos callback persists saved/assetID/savedAt before credential cleanup, and does not delete the original. Failure retains the original and marks failed. An acknowledged success whose snapshot cannot be made durable halts new work; its prior durable saving marker prevents an automatic duplicate after restart. Snapshot files remain permanent UUID tombstones.

## Disk lifecycle

Retained originals intentionally increase disk usage even with auto Photos ON; each image remains capped at 100 MiB, but there is no aggregate quota or eviction implementation in this worker. The parent must expose storage usage and coordinate deletion of completed originals with worker/Files consumers. Do not remove active downloading, ready-to-save, saving, or export-in-use files. In particular, do not delete task tombstones, which prevent re-import and duplicate Photos saves. There is no worker delete-command protocol in this change. Ready job records still grow with task count; image payloads do not accumulate in RAM.

## Validation

Command: `python3 /var/minis/workspace/pyvideo-plus/tests/photo-worker.py`

Result: 10 tests passed. The suite covers cookie domain/path/secure/expiry handling, real binary plist fixtures, crash recovery including credential-free ready recovery and missing originals, transaction ordering/original retention, filesystem/privacy guards, strict boolean/default-YES preferences, individual manual intent and ambiguous transaction rejection, ready-backlog download progress under a two-download limit, and UTI/extension roundtrips.

The compile test successfully runs real Objective-C object compilation (`-c ... -o /dev/null`) against both `/root/theos/sdks/iPhoneOS16.5.sdk` and `/root/.ios-sdk/iPhoneOS26.5.sdk`, using `-target arm64e-apple-ios15.0 -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter` and the SDK SubFrameworks search path. Tests combine Python behavior models with source contracts; they do not execute Foundation, ImageIO, NSURLSession, or Photos on iOS. No runtime permission, daemon, Files picker, animation import, or actual device Photos save claim is made.

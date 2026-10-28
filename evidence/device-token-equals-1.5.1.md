# 1.5.1 device regression: equals-delimited private TOKEN tag

## Device evidence

Uploaded diagnostics: `shared-8779EA85_PyVideo-diagnostics-C7BA4381-D639-4A12-9C73-92528DBF7C0A.txt`.
Current task `6DD7DD67-9906-4205-8B22-039B7D1720D1` reported 2114/2114 fragments, recovery version 1.5.0, nonce `D12EA4A7-A4FD-434F-8D2C-F2F3B91DC97B` and `stage=localize`, `error=Missing tag value`. No new native-remux result exists for that nonce. Old FFmpegKit load errors in the export are historical and are not this attempt's failure.

## Root cause and evidence boundary

`mediaText:base:error:` classified tag names by splitting only at `:`. Its compatibility branch removed `#EXT-X-TOKEN:…` but did not recognize `#EXT-X-TOKEN=…`, so the following missing-colon guard rejected the real format before processing any media.

The previously captured real D1 cache's original `playlist-*.txt` and `local-0.m3u8` both contain `#EXT-X-TOKEN=…`. The new uploaded log does not contain its source playlist bytes, so the exact offending line for the new task is not directly recorded. The error and shared cached-source syntax strongly identify this compatibility gap, but a successful patched-device attempt is still required.

## Fix

Strip only the known private token's exact colon/bare tag or equals-delimited spelling. Retain rejection of lookalikes (`#EXT-X-TOKEN-OTHER=…`) and other unknown HLS tags. Do not alter KEY/IV, media ordering, duration, or native ABI.

Errors now persist `errorDomain`, `errorCode` and the sanitized `manifestTag` (without tag values, full URIs or tokens) to make the next failure attributable.

## Regression coverage

- Unit tests cover colon, nonempty equals, empty equals, and unknown lookalike rejection.
- A small sanitized captured-syntax fixture retains the actual header, 4.004000 EXTINF values and `videoN.jpeg` media names; the token is replaced and media bodies are synthetic placeholders. It proves parsing/mapping, not original libav decoding.
- All six actual synthetic-media E2E cases now include `#EXT-X-TOKEN=synthetic-cache-token` before production localization. Host FFmpeg remux/full decode/content checks are distinct from original iOS libav execution.

No installation, process termination, restart or device write was performed.

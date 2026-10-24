# 媒体下载重构第一阶段静态分析记录

日期：2026-10-25

## 设备实证

只读读取 `KongtekiiPhone` 上 `com.crctdd.pyvideo/tasks/*.plist`：

- 失败任务错误为：`HLS 封装失败，文件未保存相册：Invalid data found when processing input`。
- 失败任务的 `segmentsDone == segmentsTotal`，例如 1839/1839、1799/1799、1985/1985。
- 失败任务仍保留 `.hls` 目录，目录内分别有 1839、1799、1985 个 `.ts` 文件及同数量 `.ts.plist` 元数据。
- 分片文件头均为 MPEG-TS `47 40 11...`，不是空文件或明显 HTML 错误页。
- `.ts.plist` 包含 `request`、`responseURL`、`source`、`sha256`、`size`；`responseURL` 中有可恢复的顺序，例如 `video143.jpeg`、`video1158.jpeg`。
- 当前原 Agent 的哈希文件名不携带顺序，封装阶段需要从分片元数据恢复顺序。

## 亚瑟 IPA 静态证据

`/var/minis/shared/yase/亚瑟浏览器_25.3_去检测_解锁会员.ipa`：

- 内置 `libavformat`、`libavcodec`、`libavfilter`、`libavutil`、`libswresample`、`libswscale`、`ffmpegkit`、`YSVLCPlayer`。
- Swift dump 类型：
  - `BaseDownloadTask`: `url/id/dirPath/rd_cachePath/ext_cachePath/header/keyUri/keyArr/a_keyArr/v_keyArr/mapUri/a_mapUri/v_mapUri/state/mp4FileName/folder/progressCallback/stateCallback`。
  - `BaseDownloadTaskExt`: `segments/a_segments/v_segments/unSuccessUrls`。
  - `M3u8HeadRequest.ParseResult`: `localM3u8/tsArr/keyArr/mapUri/audio/video`。
  - `M3u8HeadRequest`: `header/webUrl/userAgent/rules/ruleIndex`。
  - `DownloadM3u8Task`: `downloadTaskDict/currentDownloadUrlDict/bgTsTask/isdownloadinga_Keys/isdownloadingv_Keys/isdownloadingMap/isSingleDownload/downloadFailCount/addReferer/addKeyHeader/tryType`。
  - `M3u8TsDownloadTask`: `outputStream/task/dir/url/header/tmpFileName/rdFileName/targetFileName`。
  - `FormatConvViewController`: `fileMediaInfo/selectVideoCodec/selectAudioCodec/selectSizeType/selectFPSType/selectQualityType`。
- 枚举明确包含：`DownloadState.waiting/downloading/pauseByUser/failed/successed/combine/pauseBy4G`、分辨率到 4K、编码选择和输出质量选择。
- 亚瑟 `videoDetector.js` 会监视动态 video/source 节点、`currentSrc`、`loadedmetadata`、动态创建的 audio/video，并通过 `postMessage` 上报源；主二进制还包含脚本侧 URL 扫描和 `window.fetch` / XHR 类拦截线索。

## 开源参考

- yt-dlp：`FragmentFD`、`HlsFD`、`DashSegmentsFD`；分片索引状态、单片重试、HTTP Range/If-Range。
- Streamlink：插件式源探测、会话请求头、HLS/DASH 流管线、FFmpeg mux。
- N_m3u8DL-RE：`MediaSegment`、`Playlist`、`HLSExtractor`、`DASHExtractor2`、`LiveSegmentTracker`；分片模型、init segment、直播刷新和断网恢复。
- FFmpeg：`ffprobe`、`avformat`、`avcodec`、`-map`、`-c copy`、转码/封装。
- Shaka Packager：`SegmentCoordinator`、HLS/DASH manifest、fMP4/CMAF 时间线对齐。

## 已实施第一阶段

1. `MediaCollector.js` 增加动态 fetch/XHR/媒体 src 探测和 HLS/DASH/MP4 协议分类；仍不把 `blob:` 伪装成可下载 URL。
2. `Images.m`/`Collection.m` 保留协议和 MIME 分类字段。
3. 任务 UI 保留原始安全错误文本，不再把所有失败压成“下载失败”。
4. Storage 注入层扫描失败 HLS 任务：读取 `.ts.plist` 的 `responseURL`，按分片序号重建 TS，调用 `AVAssetExportSession` 先 passthrough、失败再最高质量导出到 MP4，成功后原子替换任务状态为 ready。
5. HLS 恢复扫描放在后台队列，不能阻塞 Agent 主线程。
6. 并行下载设置、媒体探测、失败恢复均通过本地严格编译；后续需云端 arm64e 构建和实体设备回归。

## 当前边界

- 由于设备没有 `ffprobe`，无法在手机上直接读出失败 TS 的完整流表；分片头、数量和错误状态已足够证明下载阶段完成而封装阶段失败。
- 第一阶段使用系统 AVFoundation 恢复 MPEG-TS→MP4；若某些源包含特殊音频、加密、非标准时间戳或多路轨道导致 AVFoundation 仍失败，再把 FFmpegKit/FFmpeg 的 LGPL 构建接入独立后处理模块。
- `blob/MSE` 没有可见上游 URL 时仍然只能标记为运行时媒体；如果其上游通过 fetch/XHR，新的网络探测层会在 blob 生成前记录真实 URL。
- DASH 目前完成识别和分类，原 Agent 不应被误称为完整 DASH 下载器；后续下载器层需要新增 DASH segment resolver。

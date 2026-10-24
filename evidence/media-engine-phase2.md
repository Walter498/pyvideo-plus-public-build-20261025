# 第二阶段媒体探测进展

- MediaCollector 现在额外捕获 Performance Resource Timing、fetch/XHR responseURL、HTML 中的隐藏 m3u8/mpd/mp4 URL。
- 继续监视动态 video/source/src，并分类 HLS、DASH、MP4、M4S、TS、WebM 等协议。
- 增加 MediaSource.createObjectURL / addSourceBuffer 的运行时媒体记录。blob/MSE 没有可见上游时保持 runtime-only，不伪造 HTTP 下载地址。
- WebKit 真实回归夹具增加 fetch real.mp4 和 MediaSource blob，生产测试确认网络媒体 URL 与 MIME 协议分类保留。
- MediaQuality 加入 H.264、HEVC、VP9、AV1 识别，图片与视频分辨率仍来自真实 ImageIO/AVAsset formatDescriptions。
- 第一阶段设备 HLS 失败证据：所有 TS 完成但封装失败；第二阶段仍需要实体机安装新包验证恢复引擎是否能在该任务上把重建 TS 转成 MP4。
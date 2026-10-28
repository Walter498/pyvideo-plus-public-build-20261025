# Safari Arthur Downloads 1.5.0 — 原生封装重构

当前分支：`media-fix-1.5.0`。实际生产源码版本与 SHA-256 由 `build/cloud-build.json` 的 `_source` 字段记录；打包时验证同一组生产输入，拒绝混用旧产物。

## 1. Apple macOS / Xcode 编译

需要 macOS、Xcode Command Line Tools、iPhoneOS SDK、`clang`、`ldid`。

```sh
cd pyvideo-plus
python3 build-macos.py
cat build/cloud-build.json
```

生产构建输入由以下清单维护：

```text
config/build-manifest.json
```

输出：

```text
build/PyVideoPlus.dylib
build/PyVideoPhotoWorker
build/PyVideoStorage.dylib
```

## 2. 本地媒体回归

宿主机需要 `ffmpeg` 和 `ffprobe`：

```sh
python3 tests/media-metadata-regression.py
python3 tests/media-pipeline-local.py
```

覆盖内容：

- HEAD 返回错误长度 915，但 GET 返回真实图片；
- ImageIO 图片完整解码、像素尺寸和实际字节数；
- Range/Content-Range 视频总大小；
- Cookie、域名、路径、Secure 过滤；
- 乱序 MPEG-TS 按 response 序号重排；
- 真实 FFmpeg 输出 MP4；
- ffprobe 视频轨、宽高和 duration；
- 无本地 playlist 的 HLS 恢复分支静态断言。

## 3. Storage 语法和磁盘回归

```sh
sh tests/storage-beta2/check.sh
sh tests/export-beta3-check.sh
```

在 iSH/Alpine 中若出现 LLVM 动态库加载失败，应在 macOS runner 执行；这属于编译环境问题，不是构建源码输入。

## 4. 重新打包 Debian/安装包

仅需要哈希锁定的原始 PyVideo 0.0.3 基线，不需要亚瑟 Framework。
原 Agent 内已静态链接真正的 arm64e libav；打包只为其已验证的现有互斥导出别名，不转换架构或复制外接 FFmpegKit。

```sh
export PYVIDEO_BASE_PAYLOAD=/path/to/pyvideo-0.0.3-analysis
python3 package.py
ls -lh dist/Safari-Arthur-Downloads-1.5.0-storage-recovery-refactor-iphoneos-arm64e.deb
cat dist/manifest.json
python3 tests/verify-install-package.py \
  dist/Safari-Arthur-Downloads-1.5.0-storage-recovery-refactor-iphoneos-arm64e.deb \
  dist/manifest.json \
  "$PYVIDEO_BASE_PAYLOAD/rootfs/Applications/PyVideoAgent.app/PyVideoAgent"
```

当前 `package.py` 会读取：

```text
build/cloud-build.json
build/PyVideoPlus.dylib
build/PyVideoPhotoWorker
build/PyVideoStorage.dylib
```

因此必须先完成 `build-macos.py`。

## 5. 当前修复内容

- 采集列表图片主动加载缩略图；
- 统一远程媒体资源请求层；
- 图片 GET + ImageIO 获取真实大小、宽度、高度和缩略图；
- 视频使用 Range/Content-Range，不再直接信任 HEAD 长度；
- HLS/DASH 清单读取 RESOLUTION；
- 统一 Cookie、Referer、User-Agent；
- 去除重复 Native Performance Resource 探测；
- 防止历史 sidecar 的零宽高覆盖真实值；
- 真实源清单驱动资源闭包，不再伪造每片 10 秒的清单；
- 保留 KEY/IV/MAP/Range/媒体序号，并支持证明完整后的旧清单迁移；
- 失败任务仅重试后处理，暂停/删除取消当前工作；
- 校验三个视频位置与音频缓冲后，原子发布 MP4 并落盘 ready。

## 6. 当前验证边界

这个源码包没有声称设备验证成功。真实设备仍需自行安装后检查：

```text
Storage constructor / symbols / installed
hls-UUID-start: version / nonce
hls-UUID-playlist: expectedDuration / trackCount / keyCount
hls-UUID-remux: nativeCalled / nativeReturn / sharedLockVerified
hls-UUID-result: recovery-output-valid / taskPersisted
```

生产模块回归（macOS）：

```sh
sh tests/native-remux-check.sh
sh tests/media-validator-check.sh
sh tests/recovery-state-check.sh
```

原生接口测试使用明确的 fake-remux 导出验证 ABI 和生命周期；视频校验执行真实 AVFoundation 解码。它们不等价于原 iOS Agent 的真实 libav 调用成功。真机最终结果须另行核实。

设备诊断目录为：

```text
plus-diagnostics/
```

源码包不包含任何设备导出日志、旧 deb、旧 build 产物或未跟踪 evidence。

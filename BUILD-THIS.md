# Safari Arthur Downloads — 当前可编译源码包

源码基线：当前分支 `83491e9efcbd9e0cc284e9910b68887bdd8daeec`
工作区包含该提交之后的当前媒体元数据、统一资源加载器、构建清单和打包脚本修改。

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

`package.py` 需要原始基线和亚瑟 FFmpeg Framework 来源：

```text
/var/minis/workspace/pyvideo-0.0.3-analysis
/var/minis/workspace/yase-25.3/Payload/YSBrowser.app/Frameworks
```

准备好上述目录后，可通过环境变量覆盖默认路径：

```sh
export PYVIDEO_BASE_PAYLOAD=/path/to/pyvideo-0.0.3-analysis
export PYVIDEO_FFMPEG_ROOT=/path/to/YSBrowser.app/Frameworks
python3 package.py
ls -lh dist/Safari-Arthur-Downloads-1.4.0-storage-recovery-refactor-iphoneos-arm64e.deb
cat dist/manifest.json
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
- HLS 失败恢复支持无 playlist 的 MPEG-TS 缓存入口；
- HLS 支持非零连续 response 序号；
- 记录恢复开始、清单重建失败和输出校验诊断。

## 6. 当前验证边界

这个源码包没有声称设备验证成功。真实设备仍需自行安装后检查：

```text
Storage dylib 是否完成 constructor gate
Hook 是否安装
FFmpegKit 是否成功 dlopen
HLS recovery 是否进入
recovery.m3u8 是否生成
最终 MP4 是否通过 AVAsset 校验
```

设备诊断目录为：

```text
plus-diagnostics/
```

源码包不包含任何设备导出日志、旧 deb、旧 build 产物或未跟踪 evidence。

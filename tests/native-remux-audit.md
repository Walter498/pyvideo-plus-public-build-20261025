# 原生 remux ABI / 共享锁审计（2026-10-27）

## 状态与发布门槛

这是 ABI、owner、取消、输出与锁安全修复，**不是已经打通真实 HLS 的声明**。
原样本锁没有可供 dlsym 使用的动态导出；本适配器生产构建在 `lock-contract`
阶段安全拒绝，不会把私有新锁冒充与原任务共享的锁。因文件所有权限制，本次
无法改原 Agent 调用链使其合作使用新的共享锁，也不能向原二进制添加导出。
若上层依赖此接口，必须把此阻塞如实展示，不能重试同一 wrapper 宣称修复。

## 可复核证据

原样本：`/var/minis/workspace/pyvideo-0.0.3-analysis/rootfs/Applications/PyVideoAgent.app/PyVideoAgent`

SHA256：`eb3cb70ba332473bb1f294cd091142959f37a6465dabb6c88b33db41e017a623`

准确 C ABI（arm64e/AAPCS64）：

```c
int PVRemuxHLSWithCancel(const char *input, const char *output,
                        char *error, size_t errorCapacity,
                        int (*cancel)(void *), void *opaque);
```

* `0x1001a8224–0x1001a8238`：x5→x25，x4→x24，x3→x20，x2→x19，x1→x21，x0→x22。
* `0x1001a824c–0x1001a8258`：回调可空；x25 作为 x0，`blraaz x24`，w0 非零即取消。
* `0x1001a827c` / `0x1001a8440`：回调和 opaque 写入 input/output context 的 interrupt callback；异步取消 token 必须保持到同步调用结束。
* `0x1001a8334–0x1001a834c`：x20/x19 非空且 w26 为负才以 x19/x20 作为 av_strerror 的 buffer/size。
* `0x1001a83b0`：x26 返回到 x0；原调用 `0x1001a31c0` 保存返回值，`0x1001a31d0 tbz w24,#31`：**rc >= 0 是成功候选，不是只允许 rc == 0**。
* `0x1001a8884–0x1001a888c`：成功结尾以 av_write_trailer 返回值写入 x26。
* `0x1001a8264–0x1001a8268`、`0x1001a88a0–0x1001a88a8`、`0x1001a88b0–0x1001a88b4`：取消为 `0xabb6a7bb = -1414092869 = AVERROR_EXIT`。
* `PVRemuxHLS` 在 `0x1001a81ec–0x1001a81f4` 清空 x4/x5 并跳入 WithCancel，同一 ABI 的无取消薄封装。

### 锁：有静态共享互斥，但没有动态导出

* `0x1001a30d4–0x1001a30dc`：x0=`0x100263500`，调用 `pthread_mutex_trylock`。
* `0x1001a30e8–0x1001a310c`：轮询同一锁，期间检查取消并 usleep(50000)。
* `0x1001a31bc`：锁持有期间调用 WithCancel。
* `0x1001a31c4–0x1001a31cc`：同一地址调用 pthread_mutex_unlock，然后判断返回值。
* `--indirect-symbols` 将 `0x1001bc338` 对应到 `_pthread_mutex_trylock`、`0x1001bc348` 对应到 `_pthread_mutex_unlock`。
* `--exports-trie` 只有 `_PVRemuxHLS` / `_PVRemuxHLSWithCancel`，**没有 `_PVRemuxMutex` 或其他 Mutex 导出**；`llvm-nm -an` 也没有给该静态数据锁提供名称。不能把惯用名称 PVRemuxMutex 当成样本实际导出。
* WithCancel 本身没有负责上述外部锁；直接调用时自建锁只能串行新调用，不能排斥既有 Agent 任务。生产端因此拒绝，没有硬编码 VA、指令补丁、猜测 data ABI 或伪造锁复用。

复核命令（静态，不接触设备）：

```sh
A=/var/minis/workspace/pyvideo-0.0.3-analysis/rootfs/Applications/PyVideoAgent.app/PyVideoAgent
sha256sum "$A"
llvm-objdump --macho --exports-trie "$A" | rg 'PVRemux|Mutex'
llvm-nm -an "$A" | rg -i 'remux|mutex'
llvm-objdump --macho --indirect-symbols "$A" | rg 'pthread_mutex'
llvm-objdump -d --start-address=0x1001a30d4 --stop-address=0x1001a3220 "$A"
llvm-objdump -d --start-address=0x1001a81ec --stop-address=0x1001a88d0 "$A"
```

## API / 诊断

保留 `PVXNativeRemuxHLS(input, output, error)`；新增
`PVXNativeRemuxHLSWithCancellation(input, output, token, &diagnostic, &error)`。
`PVXNativeRemuxCancellation` 为线程安全、不可复位的 sticky token。

诊断键：`stage`、`success`、`nativeCalled`、`sharedLockVerified`、`internalStage`；
实际进入 wrapper 才有 `nativeReturn`，有失败细节时有 `detail`。
阶段：validate / resolve / lock-contract / lock-wait / native-remux / cancel / output / complete。
`internalStage=unknown` 是有意保留的边界，不把 wrapper 汇总错误伪装成已定位到 open/find/DTS。

清除 dlerror 后查符号；dladdr 严格要求符号属于主镜像；同一生产调用路径保留回调、size_t、负码判断与有界错误缓冲。
输出必须原先不存在；成功还需 lstat 普通文件且非空，符号链接和空文件不能冒充成功。
验证/解析/锁/调用前取消失败不删已有输出；实际 native 调用失败清理 partial output。
上层仍必须提供经 local closure 验证且不受攻击者替换的私有 staging 路径，并做真实容器、轨道、时长校验。

不调整时间戳、不盲重试、不关闭 extension_picky、不放宽 allowed_segment_extensions。
本次没有新增 opaque avformat 诊断探针：在没有可复用全局锁与上层 closure 证明的情况下，另行调用同进程 libav 不是安全绕过；不能声称 Invalid data 根因已修复。

## 宿主测试

```sh
cd /var/minis/workspace/pyvideo-plus
sh tests/native-remux-check.sh
```

脚本仅 macOS 执行，Linux 以 **77** 表示 SKIP，绝不执行设备程序。
每个可执行文件都编译生产 `storage/PVXNativeRemux.m`：

* 主镜像 fake **多分支** C 导出：rc=0/rc=7 成功；负码和保留的 Invalid data；错误缓冲无 NUL/非 UTF8；输出缺失/空/符号链接；已有输出保留；调用前及调用中取消。
* `PVX_NATIVE_REMUX_TESTING` 唯一注入共享 mutex 提供者，不替换生产 adapter、resolver、owner 校验、取消回调或输出校验。
* 并发 16 次调用检查无同时进入 fake；fake 原调用者持有相同 mutex 时的取消。
* 独立进程测试：缺失导出、来自外来 dylib 的导出 owner 拒绝、未定义测试宏的生产构建即使主镜像有函数也必须拒绝未知共享锁。

fake 输出明确不是媒体，不能证明真实 HLS/MP4 成功。

本次实际验证：`sh -n tests/native-remux-check.sh`、`git diff --check` 通过；
Linux 脚本结果 SKIP/77，尚未在 macOS 执行宿主测试。使用现有 iOS SDK 静态语法检查生产和测试代码通过：

```sh
clang -target arm64e-apple-ios15.0 \
  -isysroot /opt/theos/sdks/iPhoneOS17.3.1.sdk \
  -fobjc-arc -fblocks -Wall -Wextra -Werror -fsyntax-only \
  -Istorage storage/PVXNativeRemux.m
clang -target arm64e-apple-ios15.0 \
  -isysroot /opt/theos/sdks/iPhoneOS17.3.1.sdk \
  -fobjc-arc -fblocks -Wall -Wextra -Werror -fsyntax-only \
  -DPVX_NATIVE_REMUX_TESTING=1 -Istorage storage/PVXNativeRemux.m \
  tests/native-remux-adapter.m tests/native-remux-resolver.m
```

共享锁可获取性、macOS 宿主执行、真实 closure HLS 输入封装和容器校验仍是发布门槛，不能用本次静态通过替代。

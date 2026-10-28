# 原 iOS `PVRemuxHLSWithCancel` Invaliddata 分支定位（2026-10-28）

## 结论

本次 `rc=-1094995529` 不是 `avformat_open_input` 或 `avformat_find_stream_info` 的返回值，也不是“归属门禁”失败。按 32 位补码它是 `0xbebbb1b7`，而 wrapper 在 **VA `0x1001a879c`** 明确构造该值：

```asm
1001a879c: 529636fa  mov w26, #0xb1b7
1001a87a0: 72b7d77a  movk w26, #0xbebb, lsl #16   ; w26 = 0xbebbb1b7
```

该路径由 EOF 后的最终验收状态汇聚到 `0x1001a885c..0x1001a8890`；它是 wrapper 自己的显式拒绝（INVALIDDATA），不是宿主 ffmpeg 证据。

最可能触发路径是：**所有包已读完（真实 `av_read_frame` EOF），但 packet 时间戳覆盖范围与 `AVFormatContext.duration` 的容差检查不一致**；次级可能是 wrapper 认为没有完整的音频包统计，或视频/音频输出流验收状态不满足。不能仅凭当前 rc 在这几个条件之间做最终归因，必须在独立 dylib 观测点记录寄存器/字段。

## 已确认的前置路径（不是触发点）

- `0x1001a82d4` 调用 `avformat_open_input`，负值才跳 `0x1001a8318`。
- `0x1001a82ec` 调用 `avformat_find_stream_info`，负值才跳同一失败清理路径。
- 当前报告说明两者均返回 0，因此这两个显式 libav failure branch 已排除。
- `0x1001a82f8` 读取 `[AVFormatContext+0x68]`（`nb_streams`）；小于 1 跳 `0x1001a840c`，不是当前 `0xbebbb1b7` 汇聚点。
- 当前输入是 6 个连续旧 D1 TS，playlist 每片 `#EXTINF:4.004000`，探测侧报告 video+h264 与 audio+aac；这些探测结果不能当作 iOS wrapper 已通过的证据。

## 流选择/布局分支（精确条件）

输入流循环从 `0x1001a84a4` 开始，数量为 `[format+0x2c]`，数组为 `[format+0x30]`，每个 `AVStream` 的 codecpar 为 `[stream+0x10]`：

1. 取 `codecpar->codec_type`：`0x1001a84c0`。
2. 若 type 为 0（视频），只接受 codec id `0x1b` 或 `0xad`：
   - `0x1001a8504` compare `0x1b`
   - `0x1001a50c` compare `0xad`
   - 两者均不满足跳 `0x1001a878c`，返回 `-0x4e`（不是当前 INVALIDDATA）。
   - 接受后 `w25=1`，并复制参数、强制 tag：H264 分支 tag=0，codec id `0xad` 分支 tag=`0x31637668`（`hvc1`）。
3. 若 codec type 非 0，且尚未选择音频（`[sp+0x2c]==0`），只接受 codec id `0x1005002`：
   - `0x1001a84dc..0x1001a84e8`
   - 不等则 `0x1001a878c` 返回 `-0x4e`。
   - 接受后 `[sp+0x2c]=1`。
4. 接受的流通过 `avformat_new_stream`（`0x1001a851c`）、`avcodec_parameters_copy`（`0x1001a8530`）；失败分别是 `-12` 或传播 copy rc，不会构成 `0xbebbb1b7`。
5. `w25==0`（没有符合视频 codec）在 `0x1001a8578` 跳 `0x1001a879c`，构造同一个 `0xbebbb1b7`。因此“没有有效视频流”是一个明确可触发该 rc 的分支。

## 包循环与最终验收

`0x1001a85e8` 调 `av_read_frame`；EOF 后在 `0x1001a8748` 保存原 rc，并建立计数：

- `[sp]`：遇到有效 DTS/PTS 条件的包计数（每次 `0x1001a8660` 增加）。
- `[sp+8]`：成功 `av_interleaved_write_frame` 次数（`0x1001a8720` 增加）。
- `x28`：codec type==1 的包计数（`0x1001a86bc..0x1001a86c4` 增加）。
- `d10`：包时间范围的最小值；`d9`：包时间范围的最大值。初始化分别为 `+Inf/-Inf`，更新在 `0x1001a8680..0x1001a86ac`。
- 包索引越界、输入 stream index 无映射、映射为 -1：跳 `0x1001a8730` 丢包，不直接返回 invaliddata。
- 缺失 packet PTS/DTS：跳更新计数逻辑，但不直接返回 invaliddata。
- DTS 不严格递增：`0x1001a86e0..0x1001a86ec` 跳 `0x1001a88bc`，构造 `0xbebbb1b7`。这是另一个明确的 wrapper 自有 INVALIDDATA 分支，需优先观测。

EOF 后 `0x1001a87cc..0x1001a8844` 做最终时长验收：

- 仅当原 `av_read_frame` rc 为 `AVERROR_EOF` 常数（`0xdfb9b0bb`，比较点 `0x1001a87d4`）才继续验收；否则原 rc 直接返回。
- `d8` 是 `[AVFormatContext+0x68]`（代码前面将它当 duration，并除以 `1,000,000.0`）。若 `d8<=0`，`0x1001a8858` 将 `w10=1`，即跳过 duration 差值拒绝。
- 正常 duration 路径要求 d8、d9、d10 均为有限数（`0x1001a87e4..0x1001a8814`）。
- 容差：读取常数 `[0x1001e1aa0] = 0.001`，计算 `max(0.25, min(2.0, d8*0.001))`（`0x1001a8818..0x1001a8830`）。
- 比较 `abs((d9-d10)-d8) <= tolerance`（`0x1001a8834..0x1001a8844`）。注意 d9/d10 是包时间端点，端点与 format duration 的差异超过约 250 ms（24.024 秒输入时）即失败。
- 失败时 `w10=0`；但最终还需经过流/包计数门。

最终门（`0x1001a885c..0x1001a8880`）：

```text
w11 = ([sp+0x2c] == 0)       // 是否没有被接受的音频流
w9  = (x28 > 0)               // 至少一个 audio(type==1) 包
w9  = w11 OR w9
w8  = (有效包数 > 0 && 成功写包数 > 0)
w8  = w8 AND w9
if (w8 != 1) return 0xbebbb1b7
if (duration_ok == 0) return 0xbebbb1b7
else av_write_trailer()
```

反汇编对应：`0x1001a8860`、`0x1001a8868`、`0x1001a8870`、`0x1001a8874`、`0x1001a8878`。所以音频 stream 存在时，至少要观察到一个 type==1 packet；无音频时反而依赖 `[sp+0x2c]==0` 的特殊兼容条件，但当前 TS 预期有 AAC。

## 最可能触发路径排序

1. **高概率：时间范围/format duration 不匹配**。`open/find_stream_info` 已通过，视频+音频输入表面存在，且错误正是最终 wrapper 常数。六片预期 24.024 s；只要 iOS 版解析出的 `duration` 或首尾 PTS/DTS 端点相差 >约 0.25 s，就会在 `0x1001a8840` 后把 `w10=0`，最终 `0x1001a8878` → `0x1001a879c`。
2. **必须排除：DTS 非严格递增**。任意输出 stream 的当前 DTS `x8=[packet+0x10]` 不大于上次 `[x22+index*8]`，即 `0x1001a86e0`/`0x1001a86ec` → `0x1001a88bc` → 同一 `0xbebbb1b7`。这比“duration”更直接，且旧 TS 跨片时常见。
3. **中概率：未找到接受的视频 codec**。`w25==0` → `0x1001a879c`。若 codecpar type/id 与预期不同，理论上前面的 audio/codec 分支也可能先返回 `-0x4e`；不能只看最终错误文字。
4. **中低概率：音频 packet 计数为零/包或写包计数为零**。最终门拒绝；不是 stream count=0（stream count=0 在 `0x1001a8300` 走另一条路径）。

## 独立 dylib 精准观测点（只观测，不关闭检查）

按 VA（不能把 host ffmpeg 地址替代 iOS 地址）在隔离副本添加只读 stage 记录：

- `PVRemuxHLSWithCancel+0x214`=`0x1001a840c`：记录 `nb_streams`、`duration`。
- `+0x2ac`=`0x1001a84a4`：每轮记录 stream index、codecpar type/id、time_base num/den、stream time_base、映射槽初值。
- `+0x370`=`0x1001a8568`：记录接受/跳过流及映射；特别记录 `w25`、`[sp+0x2c]`。
- `+0x410`=`0x1001a8608`：每 packet 记录 index、PTS、DTS、duration、size、codec type；这是最重要的 stage。
- `+0x4b8`=`0x1001a86b0`：记录有效 DTS/PTS 更新前后的 d9/d10 与 audio计数 x28。
- `+0x4f0`附近=`0x1001a86e8`：记录 `current_dts <= previous_dts` 的 stream index、current、previous；命中即对应 `+0x6c4`。
- `+0x5d4`=`0x1001a87cc`：记录 EOF 原 rc、有效包数、成功写包数、audio包数、d8/d9/d10。
- `+0x664`=`0x1001a885c`：记录 `duration_ok(w10)`、audio-present flag、audio-packet flag、counts gate(w8)、最终是否进入 trailer。
- `+0x698`=`0x1001a8890`：记录最终 `w26`，确认是否为 `0xbebbb1b7`。

推荐观测记录字段：`stage_va, stream_index, codec_type, codec_id, tb_num, tb_den, pts, dts, duration, pkt_duration, format_duration_us, min_end, max_start, valid_pts_count, written_count, audio_packet_count, selected_video, selected_audio, branch_target, rc`。不得通过修改条件分支来“验证”。

## 补丁结论

目前没有足够 branch evidence 支持关闭任何校验，也不应改 `0x1001a8878`、`0x1001a86e0` 或 duration 比较。精准补丁需求是：先在独立 dylib 通过上述 stage 采集确认**实际命中的 branch target**。若命中 `+0x6c4`，修复输入 PTS/DTS/跨片连续性或 resolver 的媒体排序；若命中 `+0x698`且 `duration_ok=0`，修正 iOS 输入/时间基或建立受证据支持的容差修复；若命中 `+0x13c`且 `w25=0`，核实 codecpar 布局/版本 ABI，而不是改 codec 门。任何补丁必须保留原检查并只修正已观测的根因。

## 样本完整性

`/tmp/pvx-device-20261028/installed-Agent` 与原 rootfs Agent 的 wrapper 字节区 `0x1a81f8..0x1a88cf` SHA-256 均为 `9a2a685fde3ab6443174c17fcc9cbb8e620ae3d4fef67175d6d4c9c3bd490da8`（wrapper 长 1752 bytes；两个文件整体 hash 不同）。分析未修改 production 或设备文件。

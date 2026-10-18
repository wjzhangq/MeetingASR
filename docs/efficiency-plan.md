# MeetingASR 效率分析与架构建议

本文回答三个问题：

1. 这个项目现在**实际**在跑什么（和文档描述有出入的地方）；
2. 时间花在哪里，瓶颈在哪；
3. 针对"降低录音质量 / 录音过程提前切分 / 异步 ASR"这几个方向，什么值得做、什么不值得做，以及建议的落地顺序。

结论先行：

- **最大的一笔收益是把 ASR 和声纹提取搬到录音期间去做**。段流水线改造之后，VAD 段之间完全独立，这件事从"要改算法"变成了"只要改调度"，1 小时会议停止录音后的等待可以从 ~8 分钟压到 ~1 分钟量级。
- **录音直接写 16 kHz 值得做**，但它是个辅助项（省掉整个预处理重采样、磁盘 I/O 降到 1/3），不是主项。
- **不建议按 HANDOFF 里写的那样在录音期间切分录音文件**。该切的是"段流"，不是"文件"；切文件会把 `TrackInfo` schema、暂停对齐、异常恢复三处都搅乱，换来的收益为零。
- **在做性能优化之前，有几处功能已经悄悄失效了**（预计人数、设置里的三个聚类滑块、录音时分离的缓存），它们直接影响用户对"快不快、准不准"的感受，建议一并处理。

---

## 1. 现状：代码里实际跑的是什么

### 1.1 录音链路

```
麦克风  AVAudioEngine tap ─ mono ─ Resampler(设备率→48k) ─┐
                                                          ├─ AlignedTrackWriter ─ .raw/*.wav（48 kHz / int16 / 单声道）
会议软件 Process Tap IOProc ─ mono ─ Resampler(48k→48k) ──┘
```

`RecordingSession.trackSampleRate = 48_000`（`Sources/MeetingASRApp/Capture/RecordingSession.swift:8`）。两条轨各自 48 kHz int16 单声道，约 96 KB/s，即每轨 **346 MB/小时**，双轨 **691 MB/小时**。

与此同时，`LiveDiarizationRunner` 每 20 秒 tick 一次，凑够 2 分钟音频就跑一遍 pyannote 切分 + CAM++ 声纹 + 聚类，把结果写进 `.raw/diarization_<track>.json`。

### 1.2 识别链路（`MeetingProcessor.runSegmentStream`）

```
预处理（两遍扫全文件：第一遍统计响度，第二遍重采样 48k→16k + 增益）→ work/<track>_16k.wav
   ↓
按轨串行：readAllMono()（整轨读进内存）→ Silero VAD（单线程，扫全轨）→ SegmentPipeline
                                                                        ├─ ASR worker  ×1
                                                                        └─ 声纹 worker ×1
   ↓
球面 K-Means 聚类 → 回声过滤 → 轮次合并 → 热词 → 标点 → 特征片段 → 人物匹配 → 写出 → 删 .raw/
```

### 1.3 文档说的 ≠ 代码做的

这一节是读代码 + 跑测试得到的，不是推测。`swift test` 在 main 上 **103 个测试中有 5 个失败**，失败点正好落在下面几条上。

| 文档/UI 的说法 | 代码里的实际情况 |
|---|---|
| "录音时分离：停止后只需分离最后不足 5 分钟的部分，1 小时会议分离从 6 分钟降到半分钟" | `DiarizationCache` **没有任何生产代码读取**（只有测试读）。`runSegmentStream` 根本不调用 `diarizer`。录音期间烧掉的那些 CPU 全部作废。`PipelineTests.testReusesBlocksDiarizedDuringRecording` 失败即为此。 |
| 停止录音后立刻开始识别 | `AppState.stop()` 走 `live.finish { queue.enqueue(m) }`（`AppState.swift:267-274`），**要等正在跑的那一块 pyannote 跑完**才排队识别。也就是说这个无用功还反过来延迟了出结果。 |
| "开始录音时填写预计人数最稳定" | `meta.expectedSpeakers` 写进了 meta，但 `runSegmentStream` 从来不读。`PipelineTests.testSingleTrackFileWithRangeAndExpectedSpeakers` 失败即为此。 |
| 设置 › 识别 › 高级："聚类阈值 / 相似说话人合并 / 发言少于 N 秒并入" | 三个滑块对应的 `clusterThreshold`、`clusterMergeSimilarity`、`minSpeakerSec` 在段流水线里**全是空操作**（它们是 pyannote 时代的参数）。真正生效的是 `segmentClustering.mergeSimilarity` / `minClusterSec`，而这两个只能从 CLI 传。 |
| `transcript.json` 的 `models.segmentation: "pyannote-segmentation-3.0"` | 段流水线不跑 pyannote。这个字段现在是错的，会误导"换模型后重新提取"的复现逻辑。 |
| README："录音时每录满约 5 分钟分离一块" | `BlockDiarizationConfig.blockSec = 120`，是 2 分钟。 |
| README 识别流程图里的 pyannote 分块、跨块关联、进度心跳 | 都已不在路径上。`ProgressTicker` 无人调用。 |
| "三种识别方式（段流水线 / 先识别再分配 / 按说话人段）" | `RecognitionMode` 只剩一个 case，另外两条路径已在 `24874e6` 物理删除。 |

另外两个失败测试 `SegmentVADTests.testBasicSegmentation` / `testPadding` 指向 `SegmentVAD`（流式分段器）——这个类写好了、有测试、但**生产代码里没接**，而它恰好是 §3 主方案最需要的零件。

### 1.4 死代码盘点

| 文件 | 行数 | 状态 |
|---|---|---|
| `People/FastDiarization.swift` + `MeetingASREngine/SherpaFastDiarizer.swift` | 544 | `DiarizationStrategy.fast` 没有任何调用点传入 |
| `People/LiveDiarization.swift` + `People/BlockDiarization.swift` | 284 | 只写不读 |
| `People/SpeakerClusterMerger.swift` | 156 | pyannote 时代的簇合并，段流水线用的是 `SegmentClusterer` |
| `Pipeline/ProgressTicker.swift` | 79 | 无调用点 |
| `Processing/Segmenter.swift` 的 `Segmenter` 部分 | ~115 | 只有里面的 `ASRSegment` / `RawSpan` 结构体还在用 |
| `Pipeline/SegmentVAD.swift` + `SherpaStreamingVAD` | 127 | 写好未接——**不要删，§3 主方案要用** |
| `EngineSet.diarizer` / `IdleDiarizer` | — | 为了不留空槽而存在的占位 |

合计约 1200 行不可达代码。这不只是洁癖问题：`LiveDiarizationRunner` 持有一个 `static` 的 `SherpaDiarizer`，一旦录过音就常驻内存（pyannote + 第二份 CAM++），白占内存。

---

## 2. 时间花在哪里

目前仓库里没有分阶段的实测数据（README 的 "分离 368s / 识别 102s" 是 pyannote 时代的数字，HANDOFF 的 RTF 0.211 是整体数字）。按代码结构推断，1 小时双轨会议的后处理大致是：

| 阶段 | 量级 | 说明 |
|---|---|---|
| 预处理 | 几十秒 | 每轨**扫两遍全文件**（响度统计 + 重采样写盘），2 轨 × 2 遍 × 346 MB |
| VAD | 每轨约 40~80 秒 | `numThreads: 1` 写死（`Engine.swift:211`），且**扫全轨**（含静音），完全串行在 ASR 之前 |
| ASR + 声纹 | **主体，数百秒** | 唯一真正吃 CPU 的部分；两个 worker 并行，但 ASR 是关键路径 |
| 聚类 / 轮次 / 标点 / 片段 / 匹配 | 几十秒 | k ≤ 20，矩阵很小；标点是每个 turn 一次推理 |

结构性的浪费有这么几处，都是读代码能确认的：

1. **两条轨串行**。`for (ti, track) in tracks.enumerated()`（`MeetingProcessor.swift:292`）。mic 轨和 system 轨之间没有依赖，却排队跑。
2. **worker 只有两个，而且线程分配是反的**。`asrThreads = (n+1)/2`、`embedThreads = n/2`（`Engine.swift:262-263`）。CAM++ 是个极小的模型，声纹 worker 绝大多数时间在 `dequeue()` 上阻塞，却拿走了一半线程；ASR 是关键路径，只拿到一半。
3. **单个 recognizer 实例靠 intra-op 线程扩展**。对 12 秒以内的短句，ONNX intra-op 的扩展性很差；K 个各占 1~2 线程的 recognizer 实例并发消费同一个队列，通常比 1 个占 K 线程的实例快 1.3~1.8 倍。
4. **整轨读进内存**。`readAllMono()`（`MeetingProcessor.swift:294`）：16 kHz float32，1 小时 ≈ 230 MB/轨，双轨期间两份同时存活。
5. **回声段白跑了 ASR**。回声判定在第 4 步，ASR 在第 2 步。外放场景下麦克风轨很大一部分是远端回声，识别完再扔掉。而回声判定本身是在 20 ms 包络上做互相关（`EchoDetector`），一段 10 秒音频约一万次乘加，**便宜到可以放在 ASR 之前当预筛**。
6. **双轨时麦克风轨的子窗口声纹是白提的**。`twoTrack && track == .mic` 时整轨强制 `cluster = "mic-speaker"`（`MeetingProcessor.swift:341-344`），既不聚类也不拆混合段；但 `SegmentPipeline` 仍然对每个 >4s 的麦克风段按 2s/1s 滑窗提声纹。最终只有一个时长加权平均值被用到。
7. **`SpeechRangeSplitter.split` 跑了两遍**。`SherpaVAD.detect(_:config:progress:)` 里一次（`Engine.swift:199`），`runSegmentStream` 里又一次（`MeetingProcessor.swift:300`）。第二遍结果必然是恒等的，纯扫描开销。
8. **进度在最长的阶段里完全不动**。`progress(.at(.diarization, ...))` 只在**一整轨跑完之后**调用一次（`MeetingProcessor.swift:328`）。单轨会议的体感就是"0% 卡死几分钟，然后跳到 62%"。另外 `ProcessingStage.weight` 还是 pyannote 时代的配比（分离 62% / 识别 30%），而现在"分离"这个阶段其实包含了 VAD+ASR+声纹，占了 95% 的实际耗时。

---

## 3. 主方案：把 ASR 搬进录音期间（在线段流水线）

### 3.1 为什么现在能做，而以前不能

pyannote 时代，分离必须看到整段音频才能聚类，所以只能"录完再算"，录音期间顶多提前算一点分离。段流水线之后，情况完全变了：

- VAD 段是**独立解码**的。`SegmentPipeline` 对每段单独调 `recognizer.recognize(audio)`，段与段之间没有任何上下文传递。
- 声纹也是按段（或段内子窗口）提的，同样独立。
- 真正需要"全局"的只有：K-Means 聚类、跨轨回声过滤、轮次合并、标点、特征片段挑选、人物匹配。这几步**加起来是秒级**（k ≤ 20，段数 ~1000）。

也就是说，**占 95% 耗时的那部分天然可以边录边算，剩下 5% 留到停止之后**。"录音过程提前切分 + 异步 ASR"这个思路对准的就是这里。

### 3.2 建议的架构

```
录音中：
  .raw/system.wav（持续增长）
        │  每 2~5 秒 tail 一次新增样本
        ▼
  SegmentVAD(SherpaStreamingVAD)   ← 已存在，只是没接
        │  吐出"已经闭合"的 VAD 段（带 padBefore/padAfter）
        ▼
  SegmentWorkerPool  ──→ ASR 实例 ×K  /  声纹实例 ×1~2
        │
        ▼
  SegmentLog.append → .raw/segments_<track>.jsonl   ← 已存在，只是没接
       （首行是参数指纹：VAD 参数 + ASR 模型 + 声纹模型 + 采样率）

停止后：
  flush VAD 尾巴 → 处理剩余段 → SegmentLog.usableSegments() 读回
        │
        ▼
  聚类 → 回声过滤 → 轮次合并 → 热词 → 标点 → 特征片段 → 人物匹配 → 写出 → 删 .raw/
```

关键在于：**`SegmentLog` 和 `SegmentVAD`/`StreamingVAD`/`SherpaStreamingVAD` 这三块零件仓库里已经写好了，还带单元测试，只是从来没接到生产路径上。** 这个方案不是从零造轮子，更像是把上一轮改造做了一半的事情接完。

`MeetingProcessor` 这边的改动面也不大：`runSegmentStream` 的第 2 步从"VAD 全轨 + 跑 SegmentPipeline"改成"先用指纹校验 `SegmentLog`，命中的段直接复用，只对未覆盖的尾部走原路径"。缓存全部失效时（换了模型、改了 VAD 参数）行为与现在完全一致，这是天然的回退路径。

### 3.3 必须处理的五个细节

这几点是方案能不能落地的关键，建议在动手前先定下来：

**(a) 响度归一化的时机。** 现在 `Preprocessor` 是两遍扫描：第一遍算全轨增益，第二遍套用。边录边算拿不到"全轨"。三种选择：

- 按段归一（每个 VAD 段独立算增益）—— 推荐。段内响度本来就比全轨一致，对 ASR 反而更友好；`LiveDiarizer.normalized()` 已经是按块归一的先例。
- 用前 N 秒估一个增益然后冻结 —— 简单，但遇到中途换设备/换人会偏。
- 完全不归一 —— Paraformer 的 fbank + CMVN 对电平有一定鲁棒性，但不建议赌。

注意增益会影响回声判定（`EchoDetector` 要用 `micGain` / `systemGain` 还原能量比），所以**每段用的增益要记进 `Segment`**，不能只记一个全局值。这是 `Segment` 结构需要加的唯一字段。

**(b) 补边需要前瞻。** `padAfter` 要用语音结束之后的样本。流式 VAD 只有在看到 `minSilenceDuration`（0.4s）的静音之后才会吐段，所以尾部天然有余量；但 tail 读文件时要保证已经读到 `speechEnd + padAfter` 之后再处理该段。实现上就是"文件已写入长度 ≥ 段尾 + padAfter + 余量"才出队。

**(c) 暂停/恢复。** `AlignedTrackWriter` 在暂停期间不写数据，文件时间轴是连续的"已录时长"。流式 VAD 看不到暂停，可能把暂停前后两句话粘成一段。建议在 `pause()` 时 `flush()`、`resume()` 时 `reset()`。（现在的全量 VAD 其实有同样的问题，所以这不算回归，但顺手修掉。）

**(d) 崩溃恢复。** `segments_*.jsonl` 是追加写的，异常退出后下次启动读回已完成的段、从最后一段的 `end` 继续即可。比现在"整个重跑"好得多。注意追加写要能容忍半行（读的时候 `compactMap` 解析失败就丢弃最后一行）。

**(e) 什么时候不要在录音期间算。** 建议加一个退让策略而不是无脑常开：电池供电且电量低于阈值时暂停、系统处于热压力（`ProcessInfo.thermalState`）时暂停、积压段数超过阈值时降频。队列积压本身是安全的——停止后补算即可，只是等待变长。

### 3.4 预期收益与代价

| | 现在 | 在线段流水线 |
|---|---|---|
| 1 小时会议停止后的等待 | 约 8 分钟 | 尾段 + 全局阶段，**约 1 分钟量级** |
| 录音期间 CPU | pyannote 2 线程常跑（无用功） | ASR 只在有语音时跑；按 RTF 0.15、语音占比 70% 估算，平均约 0.4~0.6 核 |
| 识别阶段峰值内存 | 整轨 `readAllMono`，双轨 ~460 MB | 滑动窗口，几十 MB |
| 失败恢复 | 全部重跑 | 从段日志续跑 |
| 实时字幕 | 明确不做 | **代价降到接近零**，想做随时可以做（见 §5） |

代价：录音期间多耗一点电；`Segment` 加一个 `gain` 字段；`AppState` 的 stop 路径要重写；要新增一个 `LiveSegmentRunner`（替掉 `LiveDiarizationRunner`）。

### 3.5 为什么**不要**切分录音文件

HANDOFF 的"阶段 B"写的是"录音期间按 VAD 边界切分文件，每段 ≤5 分钟"，并且自己也列了代价：`TrackInfo` schema 从单文件变多文件、`prepareTracks` 要拼接、暂停对齐和异常恢复都要改。

但这些代价换不来任何东西：

- `WavReader` 已经支持**随机读 + 头部未回填的增长中文件**（`WavFile.swift:179-182` 专门处理了这种情况），tail 一个不断增长的单文件完全没问题。
- 要"提前算"的是段，不是文件。段一旦进了 `segments_*.jsonl`，音频文件怎么组织就无关紧要了。
- 切文件唯一的理论收益是"处理完就能删前面的音频"，但停止后还要用原始音频挑特征片段、失败了还要能重试，所以删不掉。真想省磁盘，§4.1 的 16 kHz 直接把占用砍到 1/3，比切文件划算得多。

**建议：录音仍然写单个增长中的 WAV，把"提前切分"落在段流上。**

---

## 4. 二级优化（按性价比排序）

### 4.1 录音直接写 16 kHz —— 做

所有模型（Paraformer / CAM++ / Silero VAD / CT-Transformer）都是 16 kHz 输入，48 kHz 录完再降采样是纯开销。

改动极小：`RecordingSession.trackSampleRate` 48_000 → 16_000。`MicRecorder` 和 `ProcessTapRecorder` 都已经写好了 `rate == writer.sampleRate ? nil : Resampler(...)` 的分支，改完重采样自动生效。`Resampler` 是带窗 sinc（32 抽头、截止频率按输出奈奎斯特收缩，`Resampler.swift:25`），48k→16k 的抗混叠是正确的，不会有降采样 aliasing；算力约 50 万次乘加/秒，而且跑在 `ioQueue` / IOProc 的 dispatch 队列上而不是实时线程里，安全。

收益：

- 预处理阶段的重采样消失（输入输出同率，`Resampler` 直接 passthrough），两遍扫描的数据量降到 1/3；
- `.raw/` 双轨从 691 MB/小时 → 230 MB/小时，录音期间写盘降到 1/3；
- 在线段流水线 tail 文件的成本同步降到 1/3。

代价与注意点：

- 原始音频不可逆地降到 16 kHz。考虑到项目本来就"识别成功后立即删除原始音频"，这个代价是和既有设计一致的；但要明确：以后想换成 24 kHz 宽带模型重跑旧录音是不可能的（现在也不可能，因为音频已删）。
- `prepareTracks` 里的两遍扫描在同率情况下还可以进一步简化（第二遍只剩套增益 + 写盘，甚至可以把增益延迟到读段的时候套用，省掉一整个中间文件）。这是 16 kHz 之后的顺手优化。
- 对已有录音要向后兼容：`TrackInfo.sampleRate` 已经记在 meta 里，`Preprocessor` 按源文件采样率工作，老数据不受影响。

关于"再降一点行不行"：不行。8 kHz 会显著掉准确率（模型是 16 kHz 训的）；已经是单声道 int16；压成 Opus/AAC 要付解码成本还要冒质量风险，而音频反正会被删，省不下什么。**16 kHz / int16 / 单声道就是底线。**

### 4.2 ASR worker 池 + 按长度分桶的批量解码 —— 做

两步走：

1. **worker 池**：把 `SegmentPipeline` 的"1 个 ASR worker + 1 个声纹 worker"换成"K 个 ASR 实例 + 1~2 个声纹实例"消费同一队列，每个实例 1~2 个 intra-op 线程。线程分配也要翻过来：ASR 是关键路径，应该拿大头（`Engine.swift:262-263` 现在是对半分）。
2. **批量解码**：sherpa-onnx C API 有 `SherpaOnnxDecodeMultipleOfflineStreams`，但 `Sources/SherpaOnnx/SherpaOnnx.swift` 的 Swift 封装没有暴露（只有 `decode(stream:)`）。补上之后把长度相近的段凑成一批（按长度分桶，避免 padding 浪费），encoder 变成批量 GEMM，对 12 秒以内的短句收益明显。

这一项在"文件识别"和"积压补算"场景下价值最高——在线流水线如果已经跟上实时，吞吐就不是瓶颈了。

### 4.3 回声前置过滤 —— 做

把 `EchoDetector.isEcho` 从第 4 步挪到入队之前：麦克风段先和同时段的系统轨比一次包络互相关，判定为回声的直接跳过 ASR（声纹也跳过）。判定成本是微秒级，省下的是整段的 ASR。

外放场景下麦克风轨可能有相当比例是远端回声，这一项等于直接砍掉那部分算力。戴耳机时收益接近零，但也不亏。

注意：现在还有一层"文本层回声兜底"（`TextEchoFilter`），它依赖 ASR 结果，所以**不能**全部前置。建议保留两层：声学层前置做粗筛（阈值可以调保守一点，宁可漏不可错杀），文本层仍在后面兜底。

### 4.4 双轨时麦克风轨跳过子窗口声纹 —— 做

两轨场景下麦克风轨被强制当成一个人，子窗口声纹和混合段检测的结果全部被丢弃。给 `SegmentPipeline` 加一个"只要整段均值、不要子窗口"的模式，双轨的 mic 轨用它。省下的 CPU 直接让给 ASR。

人物匹配需要的说话人声纹仍然有（整段均值的时长加权平均，`MeetingProcessor.swift:438`）。

### 4.5 两轨并行 / 合并成一个队列 —— 做

`for (ti, track) in tracks.enumerated()` 改成两轨共用一个 worker 池。比起"两个轨各开一套池"更好，因为后者会互相抢核。

### 4.6 标点并行 —— 小改

CT-Transformer 现在是每个 turn 一次推理，几百个 turn 就是几百次小推理，串行跑。turn 之间独立，直接 `concurrentPerform` 即可（注意 `SherpaPunctuator` 实例不能跨线程共享，要么加锁要么开实例池）。

### 4.7 进度回报 —— 必修

`SegmentPipeline` 应该按"已完成段数 / 总段数"回调进度，`runSegmentStream` 把它映射到阶段进度上；同时把 `ProcessingStage.weight` 按段流水线的真实配比重标（现在的 62/30 是 pyannote 时代的）。

这不省一秒 CPU，但"0% 卡几分钟"和"平滑走到 100%"的体感差距，比很多真实优化都大。接上在线流水线之后更重要——停止录音时进度应该从"已经算完的比例"起步，而不是从 0 开始。

### 4.8 值得评估但需要先测量的两项

**(a) `inferenceProvider` 默认值是 `.coreml`，但模型是 int8。** `AppSettings.swift:178` 默认 CoreML，而 HANDOFF 记录说实际用的是 `cpu`（"避免 CoreML 内存泄漏"）。int8 量化模型在 CoreML EP 上基本跑不到 ANE，大概率整图回退 CPU，还要付一次 EP 分图的开销。**建议实测一次，如果证实无收益就把默认值改回 `cpu`**——默认值和已知可用配置不一致，这本身就是个坑。

**(b) 换 ASR 模型。** sherpa-onnx 的 SenseVoice-Small 在中文上通常不弱于 Paraformer-zh，而速度快不少，且支持中英日韩粤。它在离线识别器里能输出时间戳，满足段流水线对字级时间戳的依赖。值得按现有的 `AsrModelKind` 机制加一个选项做 A/B。这是**唯一可能在不改架构的前提下把 ASR 成本砍掉一半以上**的手段，优先级不低。

---

## 5. 不建议做的事

- **换流式 ASR 模型（streaming zipformer 之类）做真实时**。项目的设计原则写得很清楚"准确率优先，不做实时字幕"，流式模型的准确率明显低于离线 Paraformer。在线段流水线已经能把延迟压到"一句话说完几秒内"，没必要牺牲准确率。
- **录音期间切分文件**。见 §3.5。
- **音频压缩存储**。见 §4.1 末尾。
- **提高 `maxSpeechDuration` 来减少段数**。Paraformer 的 encoder 注意力是 O(n²)，更长的段反而更贵，还会增加单段混入多人的概率。12 秒是合理的。

顺带一个**可选的产品升级**：在线段流水线跑起来之后，"录音中显示滚动逐字稿"的额外成本几乎为零（文本已经算出来了，只是还没有说话人标签）。README 现在把"不做实时字幕"写成设计原则，但这条原则的成本前提已经变了，值得重新决定一次。建议作为开关，默认关。

---

## 6. 建议一并修掉的正确性问题

这些不直接省 CPU，但直接影响"用户觉得这个工具好不好用"，而且其中两条已经有失败的测试在报警：

1. **`expectedSpeakers` 接回聚类**。用户填了预计人数却不生效，是目前"说话人分得太细/太粗"最直接的解药被拔掉了。`SegmentClusterer` 可以在已知人数时把合并条件从"相似度 ≥ 阈值"改成"合并到恰好 k 个簇"。
2. **设置界面的三个高级滑块对齐到真正生效的参数**（`segmentClustering.mergeSimilarity` / `minClusterSec`），或者干脆收起来，换成"分得更细 / 更粗"这样一个两三档的预设。20 多个可调参数对终端用户没有意义，对调参倒是有——那就留在 CLI 里。
3. **`models.segmentation` 不该再写 pyannote**。段流水线没跑它，写进 transcript 会让"换模型后重新提取声纹"的判断出错。
4. **`SegmentClusterer.reassignToFinalCenters` / `mergeTinyClusters` 遍历的是 Dictionary**，并列相似度时的胜者取决于哈希顺序。项目把"固定种子、结果可复现"当卖点，这里应该排序后再比。
5. **删掉 `SpeechRangeSplitter.split` 的重复调用**（`Engine.swift:199` 和 `MeetingProcessor.swift:300` 二选一）。

---

## 7. 分阶段落地建议

每一阶段都应该独立可验证、可回滚。

### 阶段 0：先能测量（前置）

没有分阶段耗时数据，后面所有优化都是盲猜。

- 在 `SegmentPipeline` 里统计并输出：段数、语音总时长、ASR 累计耗时、声纹累计耗时、两个 worker 各自的空闲比例。
- CLI 已经会打印各阶段耗时和 RTF，补上上面这些，跑一次真实的 1 小时双轨录音存档作为基线。
- 修掉 5 个失败测试（它们标记的都是真实缺陷，不是测试写错了）。

**验收**：拿到一份 baseline，能回答"ASR 占多少、声纹占多少、VAD 占多少、预处理占多少"。

### 阶段 1：低风险的纯收益项（不动录音端）

- 16 kHz 录音（`trackSampleRate` 一行 + 回归验证两条采集链路）
- 回声前置过滤
- 双轨 mic 轨跳过子窗口
- 两轨合并进一个 worker 池 + ASR 实例池 + 线程分配翻转
- 进度回报修复 + 阶段权重重标
- 删掉 `SpeechRangeSplitter` 重复调用

**验收**：同一段录音，端到端耗时下降，`transcript.json` 的文本和说话人划分与基线一致（或有据可查的差异）。

### 阶段 2：在线段流水线（主项）

- `Segment` 加 `gain` 字段，`SegmentPipeline` 支持按段归一
- 新增 `LiveSegmentRunner`：tail 文件 → `SegmentVAD` → worker 池 → `SegmentLog.append`
- `MeetingProcessor.runSegmentStream` 支持从 `SegmentLog` 续跑（指纹不匹配则完整重算，这是天然回退）
- `AppState`：删掉 `LiveDiarizationRunner`，`stop()` 不再等待任何后台推理
- 暂停/恢复时 flush/reset VAD
- 加退让策略（电量、热压力、积压）

**验收**：1 小时双轨录音，停止到出结果 ≤ 1 分钟；结果与"关掉在线处理、全量重算"的结果一致；录音期间 CPU 和内存在可接受范围；中途杀进程后能从段日志续跑。

### 阶段 3：清理与模型评估

- 删掉 §1.4 列的约 1200 行死代码（`SegmentVAD` 系列除外，阶段 2 要用）
- README / `docs/segment-pipeline.md` 按实际行为重写（现在的识别流程图、性能章节、FAQ 都是 pyannote 时代的）
- `expectedSpeakers` 接回聚类；高级设置改成预设
- CoreML vs CPU 实测；SenseVoice A/B
- Swift 封装补 `DecodeMultipleOfflineStreams` + 分桶批量解码

---

## 8. 附：怎么测

本文的结论里，"代码里实际跑的是什么"全部来自读代码并在 Linux 容器里编译、运行测试（`swift build` + `swift test`，103 个测试 5 个失败）；**耗时的分解是按结构推断的估计值，没有实测**。动手之前建议先按阶段 0 拿到真实数字。

```bash
# Linux 容器里就能跑核心逻辑和 CLI（App 目标需要 macOS）
scripts/fetch-sherpa-onnx.sh
swift build -c release
swift test

# 基线：对一段存档录音跑完整流程，stderr 会输出各阶段耗时与 RTF
export MEETINGASR_MODELS=$PWD/Resources/models
.build/release/meetingasr-cli recognize 存档会议.wav --keep-work

# 参数对比
.build/release/meetingasr-cli sweep meetings.txt > results.csv
```

对比两次运行是否等价，直接 diff `transcript.json` 的 `segments[].text` 和 `speakers[]`；段流水线用固定种子，同输入同参数应当逐字一致（修掉 §6.4 的字典序问题之后）。

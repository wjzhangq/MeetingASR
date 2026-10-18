# 段流水线：VAD 分段驱动的说话人分离

## 概述

段流水线（Segment Stream Pipeline）是 MeetingASR 的新识别模式，用 VAD 切出的语音段作为调度单元，实现 ASR 与声纹提取的并行处理。

**核心改进：**
- ✅ 并行化：ASR 和声纹同时处理同一段，CPU 利用率提升
- ✅ 可复现：固定随机种子，同一录音每次结果完全一致  
- ✅ 边界对齐：VAD 段即 ASR 段，说话人切换点与字级时间戳天然对齐
- ✅ 参数集中：21 个可调参数便于标定

## 流水线阶段

```
┌─────────────┐
│ 音频输入    │ 16kHz 单声道
└──────┬──────┘
       │
┌──────▼──────────────────────────────────────────┐
│ Stage 1: VAD 分段                                │
│  - Silero VAD（512 帧窗口）                      │
│  - 环形缓冲 → 前后补边（0.15s / 0.1s）           │
│  - 产出：Segment（id/track/start/end）           │
└──────┬──────────────────────────────────────────┘
       │
┌──────▼──────────────────────────────────────────┐
│ Stage 2: 并行 ASR + 声纹                         │
│                                                  │
│  ┌─────────────┐        ┌─────────────┐         │
│  │ ASR Worker  │        │ 声纹 Worker  │         │
│  │ Paraformer  │  并行  │ 3D-Speaker  │         │
│  │ text/tokens │        │ embedding   │         │
│  └─────────────┘        └─────────────┘         │
│                                                  │
│  声纹策略：                                       │
│  - <1s: 整段，标记 isShort                       │
│  - 1-4s: 整段                                    │
│  - >4s: 2s 窗口 / 1s 步长 → 子窗口 + 混合段检测  │
└──────┬──────────────────────────────────────────┘
       │
┌──────▼──────────────────────────────────────────┐
│ Stage 3: 球面 K-Means 聚类（每轨独立）           │
│  1. 筛选：duration ≥ 1s && !isMixed              │
│  2. K-Means++：k = min(20, 段数)                 │
│  3. 迭代合并：相似度 ≥ threshold → 合并一对      │
│  4. 小簇吸收：总时长 < 3s → 并入最相似簇         │
│  5. 重新分配：按最终中心重归属                    │
└──────┬──────────────────────────────────────────┘
       │
┌──────▼──────────────────────────────────────────┐
│ Stage 4: 短段 & 混合段处理                       │
│  - 短段：相似度 ≥ 0.25 → 归簇；否则时间就近      │
│  - 混合段：子窗口标签 → 平滑 → 切分              │
└──────┬──────────────────────────────────────────┘
       │
┌──────▼──────────────────────────────────────────┐
│ Stage 5: 双轨合并 & 回声过滤                     │
│  - 按时间合并两轨段                              │
│  - 声学回声检测（能量包络相关）                   │
│  - 文本回声检测（编辑距离）                       │
└──────┬──────────────────────────────────────────┘
       │
┌──────▼──────────────────────────────────────────┐
│ Stage 6: 轮次合并 & 标点                         │
│  - 同说话人、间隔 < 1s → 合并为一轮              │
│  - 轮次级标点（CT-Transformer）                  │
│  - 热词纠错 + 缩写规范                           │
└──────┬──────────────────────────────────────────┘
       │
┌──────▼──────────────────────────────────────────┐
│ Stage 7: 特征片段 & 人物匹配                     │
│  - 每人选 3 段：相似度 × 时长 打分               │
│  - 匈牙利算法一对一匹配人物库                    │
└──────┬──────────────────────────────────────────┘
       │
       ▼
  transcript.json

```

## 参数表

### VAD 参数（SegmentVADConfig）

| 参数 | 默认值 | 范围 | 说明 |
|-----|-------|------|------|
| `threshold` | 0.5 | 0.3-0.7 | 判定为语音的概率阈值 |
| `minSilenceDuration` | 0.4s | 0.2-1.0s | 停顿超过该时长才切段 |
| `minSpeechDuration` | 0.25s | 0.1-0.5s | 过滤短噪声（咳嗽、敲键盘） |
| `maxSpeechDuration` | 12s | 5-30s | 超长段强制切开 |
| `padBefore` | 0.15s | 0.1-0.3s | 前补边（保留起音） |
| `padAfter` | 0.1s | 0.05-0.2s | 后补边（保留收音） |

**调参建议：**
- `minSilenceDuration` 越小切得越碎，短段越多
- `maxSpeechDuration` 过大会增加混合段概率
- 补边量影响 ASR 准确率（边界切字）

### 聚类参数（SegmentClusteringConfig）

| 参数 | 默认值 | 范围 | 说明 |
|-----|-------|------|------|
| `shortSegmentSec` | 1.0s | 0.5-2.0s | 短于此值不参与聚类 |
| `longSegmentSec` | 4.0s | 3-10s | 长于此值提取子窗口 |
| `subwindowSec` | 2.0s | 1.5-3.0s | 子窗口长度 |
| `subwindowStepSec` | 1.0s | 0.5-2.0s | 子窗口步长 |
| `mixedValley` | 0.3 | 0.2-0.5 | 相邻子窗口相似度低谷 |
| `mixedSideSimilarity` | 0.5 | 0.4-0.7 | 低谷两侧内部相似度下限 |
| `maxClusters` | 20 | 5-50 | K-Means 的 k 上限 |
| `kmeansMaxIterations` | 50 | 20-100 | K-Means 最大迭代次数 |
| `kmeansSeed` | 20251017 | - | 固定种子（保证可复现） |
| `mergeSimilarity` | 0.38 | 0.3-0.5 | 簇合并阈值 |
| `minClusterSec` | 3.0s | 1-10s | 小簇合并下限 |
| `minClusterSimilarity` | 0.45 | 0.3-0.6 | 小簇并入的最低相似度 |
| `shortAssignSimilarity` | 0.25 | 0.2-0.4 | 短段归属阈值 |
| `shortAssignNearbySec` | 2.0s | 1-5s | 短段就近归属窗口 |
| `smoothRunSec` | 1.5s | 1-3s | 混合段标签平滑长度 |
| `turnMergeGap` | 1.0s | 0.5-2.0s | 轮次合并间隔 |

**关键参数：**
- `mergeSimilarity`：最敏感，建议 0.36-0.40 范围扫描
- `minClusterSec`：影响说话人数量，太小易过分
- `shortAssignSimilarity`：影响短段归属准确率

## CLI 使用

### 单次处理（指定参数）

```bash
meetingasr-cli recognize audio.wav \
  --mode segment-stream \
  --vad-min-silence 0.4 \
  --merge-similarity 0.38 \
  --min-cluster-sec 3.0
```

### 参数扫描（M0 评估）

1. 准备会议列表文件 `meetings.txt`：
```
meeting-20251017-001
meeting-20251017-002
meeting-20251017-003
# meeting-old-skip  （# 开头为注释）
```

2. 运行扫描：
```bash
meetingasr-cli sweep meetings.txt > results.csv
```

3. 分析结果：
```python
import pandas as pd
df = pd.read_csv("results.csv")

# 按平均处理时间排序
df.groupby(["vad_min_silence", "merge_similarity", "min_cluster_sec"])["processing_sec"].mean().sort_values()

# 按说话人数量分布
df.groupby(["merge_similarity", "min_cluster_sec"])["num_speakers"].describe()
```

4. 选定参数后，更新 `AppSettings` 默认值或通过 CLI 传参。

## 性能

**M1 Max (10核) 测试：**
- 1 小时双轨会议：10-15 分钟（RTF 0.17-0.25）
- 并行加速：相比旧模式提速 30-50%
- 内存：峰值 1.5-2GB

**瓶颈：**
- ASR 和声纹提取均为 CPU 密集
- CoreML provider 可加速声纹提取（GPU）
- 聚类本身很快（< 1s）

## 对比旧模式

| 维度 | asrFirst | segment | segmentStream（新） |
|-----|----------|---------|---------------------|
| 分离方式 | pyannote 滑窗 | FastDiarizer 固定窗口 | VAD 段 |
| ASR 粒度 | 长句（上下文完整） | 说话人段 | VAD 段 |
| 并行度 | 无 | 无 | ASR ∥ 声纹 |
| 边界对齐 | 字级事后分配 | 窗口与字不对齐 | 天然对齐 |
| 可复现性 | 是 | 否（在线聚类） | 是（固定种子） |
| 长会议性能 | 慢（pyannote） | 中 | 快 |

**推荐场景：**
- `segmentStream`：默认，适合所有场景
- `asrFirst`：需要最佳 ASR 准确率（长句上下文）
- `segment`：兼容旧流程或对比测试

## 常见问题

**Q: 说话人数量不对？**  
A: 调整 `mergeSimilarity`（太小会过分）和 `minClusterSec`（太小碎簇多）

**Q: 短段（"嗯"、"对"）归属错误？**  
A: 降低 `shortAssignSimilarity` 或增大 `shortAssignNearbySec`

**Q: 混合段（两人交叠）没拆开？**  
A: 降低 `mixedValley` 或 `mixedSideSimilarity`

**Q: 轮次切得太碎？**  
A: 增大 `turnMergeGap`（默认 1s）

**Q: 如何恢复旧模式？**  
A: `--mode asr-first` 或 `--mode segment`

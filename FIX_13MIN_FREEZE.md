# 13分钟卡死问题 - 修复说明

## 问题总结

**现象：** 停止录音后，应用显示"正在处理"状态长达 13 分钟。

**根本原因：**
1. **VAD 输出超长段** - sherpa-onnx 的 `maxSpeechDuration` 配置失效，可能输出数百秒的连续段
2. **LiveSegmentCoordinator 串行处理瓶颈** - 同时只处理一个段，避免共享识别器
3. **会后处理的 ASR 耗时** - 如果有超长段（如780秒），在 RTF=1.0 时需要13分钟

## 修复内容

### 1. 改进 LiveSegmentCoordinator.enforceCap（关键修复）

**文件：** `Sources/MeetingASRCore/Pipeline/LiveSegmentCoordinator.swift`

**修改：** 移除 `guard lane.ordered.isEmpty` 守卫，即使有段在处理也强制切分超长未覆盖音频

**效果：** 防止一个超长段阻塞后续所有段的切分，避免内存积压

```swift
// 修改前：只有队列空时才切分
guard lane.ordered.isEmpty else { return }

// 修改后：立即检查并切分
let uncovered = lane.totalFileSec - lane.coveredUntil
guard uncovered > maxSec + 1 else { return }
```

### 2. 添加监控日志

#### LiveSegmentCoordinator.finish
- 记录等待的段数量
- 超过 5 秒时输出警告日志
- 帮助定位是否是实时处理阻塞

#### LiveSegmentCoordinator.enforceCap
- 当未覆盖音频超过 2 倍上限时输出警告
- 格式：`⚠️ [mic] 未覆盖音频 XX.X秒，强制切分`

#### MeetingProcessor.runSegmentStream
- 记录整体处理耗时和 RTF（Real-Time Factor）
- 分别记录：
  - 录音期间已复用的段数量
  - 补充识别尾段的耗时和 RTF
  - VAD + ASR/声纹总耗时
  - 整体处理完成时的总耗时和 RTF

**日志示例：**
```
[system] 复用录音期间已识别的 45 个段（覆盖到 120.5秒）
[system] 补充识别尾段 15.3秒，耗时 18.7秒（RTF=1.22）
VAD + ASR/声纹 总耗时 42.3秒
✓ 会议处理完成，总耗时 65.8秒（会议时长 135.8秒，RTF=0.48）
```

### 3. 更新配置文档

**文件：** `Sources/MeetingASRCore/Models/SegmentConfig.swift`

添加注释说明 sherpa-onnx VAD 的 `maxSpeechDuration` 可能失效的问题。

## 如何验证修复

### 1. 查看日志输出

运行应用后，在控制台或日志中查找：

**实时处理阶段：**
```
⚠️ [system] 未覆盖音频 XXX秒，强制切分
LiveSegmentCoordinator.finish: 等待 X 个段完成...
⚠️ LiveSegmentCoordinator.finish 耗时 XX秒
```

**会后处理阶段：**
```
[system] 复用录音期间已识别的 X 个段
[system] 补充识别尾段 XX秒，耗时 XX秒（RTF=X.XX）
段 #X: 音频 XXX.Xs 超过 ASR 上限 60s，切成 X 段且不重叠
✓ 会议处理完成，总耗时 XX秒（会议时长 XX秒，RTF=X.XX）
```

### 2. 关键指标

- **RTF < 1.0** ✅ 好 - 处理速度快于实时
- **RTF ≈ 1.0** ⚠️ 注意 - 处理耗时接近会议时长
- **RTF > 1.5** ❌ 问题 - 处理速度过慢

### 3. 测试场景

1. **正常会议（10-30分钟）**
   - 预期：RTF < 0.8，处理时间 < 会议时长的80%

2. **长时间连续说话**
   - 故意录制 5-10 分钟连续语音（无停顿）
   - 检查是否有"强制切分"日志
   - finish() 耗时应 < 10 秒

3. **背景音乐或噪音**
   - 播放音乐录制 2-3 分钟
   - 检查未覆盖音频是否被及时切分

## 预期效果

### 修复前
- 一个超长段（如780秒）会阻塞整个流程
- `finish()` 可能等待数分钟
- 会后处理 RTF 接近 1.0，耗时 = 会议时长

### 修复后
- 超长未覆盖音频被强制切分为 12 秒片段
- `finish()` 等待时间显著减少（< 10秒）
- 更多段在录音期间已完成识别，会后只需补充尾段
- 整体 RTF 降低

## 长期改进建议

### 1. 并行处理多段（根本解决）
允许同时处理多个段，每个 worker 使用独立的识别器实例。

**挑战：** 需要重构识别器管理，支持多实例并行。

### 2. 模型性能优化
- 测量 int8 SenseVoice 的实际 RTF
- 如果显著慢于 Paraformer，考虑：
  - 使用 CoreML 后端（神经引擎加速）
  - 回退到非量化模型
  - 优化 numThreads 配置

### 3. 流式处理改进
- 不等待所有段完成才返回
- 边处理边输出已完成的部分
- 用户可以提前查看部分结果

### 4. 超时保护
在 `finish()` 中添加超时机制：
- 超过阈值（如 60 秒）自动放弃等待
- 记录未完成的段到日志
- 允许会后处理继续补全

## 相关文件

- `ISSUE_13MIN_FREEZE.md` - 详细问题分析
- `Sources/MeetingASRCore/Pipeline/LiveSegmentCoordinator.swift` - 实时段协调器
- `Sources/MeetingASRCore/Pipeline/MeetingProcessor.swift` - 会后处理器
- `Sources/MeetingASRCore/Models/SegmentConfig.swift` - VAD 配置
- `Sources/MeetingASREngine/Engine.swift:210` - VAD 问题说明

## 回滚方案

如果修复导致新问题，可以回滚关键修改：

```bash
git diff HEAD Sources/MeetingASRCore/Pipeline/LiveSegmentCoordinator.swift
git checkout HEAD -- Sources/MeetingASRCore/Pipeline/LiveSegmentCoordinator.swift
```

主要回滚点是 `enforceCap` 中的 `guard lane.ordered.isEmpty` 守卫。

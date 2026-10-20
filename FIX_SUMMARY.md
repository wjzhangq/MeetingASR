# 13分钟卡死问题 - 修复完成

## 问题确认

**现象：** 停止录音后，应用"正在处理"状态持续 13 分钟

**根本原因：**
1. VAD 输出超长段（可达数百秒），`maxSpeechDuration=12` 配置在 sherpa-onnx 中失效
2. LiveSegmentCoordinator 的 `enforceCap` 只在队列空时才切分，导致超长段阻塞
3. 会后处理遇到超长段时，串行 ASR 处理耗时 = 音频时长（RTF≈1.0）

**13分钟的数学：**
- 如果 VAD 输出 780 秒（13分钟）的连续段
- int8 SenseVoice 的 RTF = 1.0
- 处理时间 = 780 秒 = 13 分钟

## 已实施的修复

### ✅ 1. 移除 enforceCap 的阻塞守卫
**文件：** `Sources/MeetingASRCore/Pipeline/LiveSegmentCoordinator.swift:168`

```swift
// 修改前：只有队列空时才切分
guard lane.ordered.isEmpty else { return }

// 修改后：移除守卫，立即检查并切分
let uncovered = lane.totalFileSec - lane.coveredUntil
guard uncovered > maxSec + 1 else { return }
```

**效果：** 即使有段在处理，超过 12 秒的未覆盖音频也会被立即切分

### ✅ 2. 添加性能监控日志

**LiveSegmentCoordinator.finish：**
- 显示等待的段数量
- 超过 5 秒输出警告：`⚠️ LiveSegmentCoordinator.finish 耗时 XX秒`

**LiveSegmentCoordinator.enforceCap：**
- 未覆盖音频超过 24 秒时警告：`⚠️ [system] 未覆盖音频 XX秒，强制切分`

**MeetingProcessor.runSegmentStream：**
- 显示录音期间已完成的段数
- 显示补充识别的 RTF
- 显示整体处理的总耗时和 RTF

**日志示例：**
```
[system] 复用录音期间已识别的 45 个段（覆盖到 120.5秒）
[system] 补充识别尾段 15.3秒，耗时 18.7秒（RTF=1.22）
⚠️ [system] 未覆盖音频 78.5秒，强制切分
VAD + ASR/声纹 总耗时 42.3秒
✓ 会议处理完成，总耗时 65.8秒（会议时长 135.8秒，RTF=0.48）
```

## 验证方法

### 查找关键日志

**问题复现时应该看到：**
```
⚠️ [system] 未覆盖音频 XXX秒，强制切分  ← 超长段被检测到
段 #X: 音频 XXX.Xs 超过 ASR 上限 60s，切成 X 段  ← 会后处理切分
⚠️ LiveSegmentCoordinator.finish 耗时 XX秒  ← 实时处理阻塞时间
✓ 会议处理完成，总耗时 XX秒（RTF=X.XX）  ← 整体性能
```

### RTF 指标

- **RTF < 0.8** ✅ 优秀 - 处理速度快
- **RTF ≈ 1.0** ⚠️ 临界 - 需要优化
- **RTF > 1.5** ❌ 问题 - 处理过慢

### 测试建议

1. **录制 5-10 分钟连续语音**（无停顿）
   - 检查是否有"强制切分"日志
   - finish() 耗时应 < 10 秒

2. **查看会后处理日志**
   - 检查"复用录音期间已识别"的段数
   - 补充识别的 RTF 应合理

3. **对比修复前后**
   - 修复前：可能卡死 10+ 分钟
   - 修复后：大部分在录音时已完成，会后只需补充尾段

## 已修改的文件

```
Sources/MeetingASRCore/Pipeline/LiveSegmentCoordinator.swift
Sources/MeetingASRCore/Pipeline/MeetingProcessor.swift
Sources/MeetingASRCore/Models/SegmentConfig.swift (注释更新)
```

## 编译验证

```bash
✓ MeetingASRCore 编译成功
```

## 详细文档

- `ISSUE_13MIN_FREEZE.md` - 完整的问题分析
- `FIX_13MIN_FREEZE.md` - 修复说明和验证方法

## 后续建议

如果问题仍然出现：

1. **收集日志** - 查看上述关键日志，确认瓶颈在哪个阶段
2. **测量 RTF** - 确认 int8 SenseVoice 的实际性能
3. **考虑并行处理** - 允许多个段同时识别（需要重构识别器管理）
4. **尝试 CoreML 后端** - 可能比 CPU 更快：`inferenceProvider = .coreml`

---

**修复完成时间：** 2025-01-XX  
**修复范围：** 实时录音的超长段切分 + 会后处理性能监控  
**预期效果：** finish() 等待时间从分钟级降低到秒级

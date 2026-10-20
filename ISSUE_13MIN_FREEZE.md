# 13分钟卡死问题分析

## 问题现象
停止录音后，应用显示"正在处理"状态长达13分钟，用户感觉卡死。

## 根本原因

### 1. VAD maxSpeechDuration 配置失效
- 配置值：`maxSpeechDuration = 12` 秒
- 实际情况：sherpa-onnx 的 VAD 仍可能输出长达数分钟的连续段
- 代码注释（Engine.swift:210）：**"maxSpeechDuration 在当前 sherpa-onnx 上压不住长语音（实测出现 216s）"**

### 2. 超长段触发串行处理瓶颈
- 如果 VAD 输出一个 780 秒（13分钟）的连续段
- LiveSegmentCoordinator 采用**串行处理**：`running == 0` 才能处理下一段
- 原因：避免多个任务共享同一个 ASR 识别器实例

### 3. int8 量化模型速度影响
- 最近切换到 SenseVoice int8 量化模型（commit 3a59c97）
- 如果模型 RTF（Real-Time Factor）= 1.0：
  - 处理 1 秒音频需要 1 秒实际时间
  - 处理 780 秒音频需要 780 秒 = **13 分钟**

### 4. finish() 等待所有段完成
```swift
// LiveSegmentCoordinator.swift:137
func finish() {
    idle.lock()
    lock.lock()
    for lane in lanes.values where !lane.stalled {
        lane.segmenter.flush()
        collect(lane)
    }
    lock.unlock()
    while true {
        lock.lock()
        let idleNow = running == 0 && waiting.isEmpty && overflow.isEmpty
        lock.unlock()
        if idleNow { break }
        idle.wait()  // 无限等待，直到所有段处理完
    }
    // ...
}
```

## 为什么恰好是13分钟

**场景重现：**
1. 录音过程中，VAD 误判或遇到长时间连续语音（无停顿）
2. VAD 输出一个 780 秒的超长段
3. LiveSegmentCoordinator 将其切成 13 个 60 秒子段（见 SegmentPipeline.swift:135 日志）
4. 串行处理这 13 个子段，每个耗时约 60 秒（RTF=1.0）
5. 总耗时：13 × 60 = 780 秒 = **13 分钟**

## 日志验证

应该能在日志中看到：
```
段 #X: 音频 780.0s 超过 ASR 上限 60s，切成 13 段且不重叠
```

## 解决方案

### 方案 1：降低 maxSpeechDuration（快速修复）
将 `maxSpeechDuration` 从 12 秒降低到 6-8 秒：

```swift
// SegmentConfig.swift:12
public var maxSpeechDuration: Float = 8  // 从 12 改为 8
```

**优点：**
- 改动最小
- 即使 VAD 输出超长段，enforceCap 会更早强制切分

**缺点：**
- 可能会在长句中间切断
- 仍然依赖 enforceCap 机制

### 方案 2：enforceCap 更激进（推荐）
修改 LiveSegmentCoordinator 的 enforceCap 逻辑，不要等到 `ordered.isEmpty`：

```swift
// LiveSegmentCoordinator.swift:169
private func enforceCap(_ lane: Lane) {
    let maxSec = Double(vadConfig.maxSpeechDuration)
    // 移除这个守卫，让正在处理的段也能被切分
    // guard lane.ordered.isEmpty else { return }
    
    // 如果当前未覆盖的音频超过阈值，立即切分
    let uncovered = lane.totalFileSec - lane.coveredUntil
    guard uncovered > maxSec + 1 else { return }
    
    let cut = min(lane.totalFileSec, lane.coveredUntil + maxSec)
    // ... 后续切分逻辑保持不变
}
```

### 方案 3：并行处理多段（根本解决）
允许同时处理多个段，为每个 worker 创建独立的识别器实例：

```swift
// LiveSegmentCoordinator.swift
private let maxWorkers = 2  // 允许2个并发 worker

private func pumpWorkers() {
    while running < maxWorkers, !waiting.isEmpty {
        let job = waiting.removeFirst()
        running += 1
        workQueue.async { [weak self] in
            guard let self else { return }
            // 需要为每个 worker 创建独立的识别器
            let result = self.execute(job)
            self.finishJob(job, result: result)
        }
    }
}
```

**注意：** 需要解决识别器共享问题，可能需要为每个 worker 创建独立的 SherpaRecognizer 实例。

### 方案 4：添加超时和进度反馈
在 finish() 中添加超时机制和进度显示：

```swift
func finish(_ completion: @escaping @MainActor () -> Void, timeout: TimeInterval = 60) {
    queue.async {
        let start = Date()
        self.coordinator?.finish()
        let elapsed = Date().timeIntervalSince(start)
        if elapsed > 10 {
            print("⚠️ finish() 耗时 \(elapsed)秒，可能存在超长段")
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { completion() } }
    }
}
```

## 临时缓解措施

1. **检查日志** 确认是否有 "超过 ASR 上限" 的警告
2. **避免超长录音** 遇到长时间会议时，手动暂停再继续
3. **等待完成** 如果已经卡住，耐心等待13分钟让它完成

## 长期建议

1. 升级 sherpa-onnx 版本，检查 VAD maxSpeechDuration 问题是否已修复
2. 测量 int8 模型的实际 RTF，如果显著慢于原模型，考虑：
   - 回退到非量化模型
   - 使用 CoreML 后端（神经引擎加速）
3. 实现真正的流式识别，不要等待所有段完成才返回

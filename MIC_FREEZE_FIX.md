# MicRecorder 主线程卡死问题修复

## 问题诊断

**现象：** 应用在 10月28日 启动后主线程卡死 13 天，菜单栏无响应，进程 CPU 占用 34%。

**根因：** `MicRecorder.scheduleRebuild` → `buildEngine()` 在**主线程同步调用** `AVAudioEngine.inputNode`，该调用通过 `dispatch_barrier_sync` 同步查询音频硬件：

```
Main Thread (BLOCKED 13天):
  scheduleRebuild(reason:) → tryBuild()
    → buildEngine()
      → AVAudioEngine.inputNode
        → AVAudioIOUnit::GetHWFormat
          → AVAEHalUtil::GetSubDevices
            → mach_msg to coreaudiod (never returns)
```

sample 证据：2393 个样本（5秒，1ms间隔）100% 卡在同一个栈，其中 960 个在 `GetSubDevices`，494 个阻塞在 `mach_msg2_trap`。

**触发条件：**
- 第三方 HAL 插件响应慢或卡死（`MSTeamsAudioDevice.driver`、`ParrotAudioPlugin.driver`、`BlackHole2ch.driver`）
- 聚合设备（Aggregate Device）子设备枚举超时
- 蓝牙/USB 设备状态异常
- coreaudiod 守护进程无响应

## 修复方案

### 原则
1. **buildEngine 移出主线程** — 避免 UI 冻结
2. **增加超时保护** — HAL 查询超时后放弃并报错
3. **限制重试频率** — 避免失败时无限重建

### 实现

#### 1. 使用专用串行队列

```swift
final class MicRecorder {
    // ...
    private let engineQueue = DispatchQueue(label: "meetingasr.mic.engine", qos: .userInitiated)
    private var rebuildWorkItem: DispatchWorkItem?
    
    func start() throws {
        running = true
        let sema = DispatchSemaphore(value: 0)
        var startError: Error?
        engineQueue.async {
            do {
                try self.buildEngine()
                sema.signal()
            } catch {
                startError = error
                sema.signal()
            }
        }
        // 首次启动允许等待 10 秒
        let timeout = sema.wait(timeout: .now() + 10)
        guard timeout == .success, startError == nil else {
            throw startError ?? CoreAudioError(kAudioHardwareUnspecifiedError, "mic start timeout")
        }
        // 监听设备变化
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in 
            self?.scheduleRebuild(reason: "默认输入设备变化") 
        }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(.system, &defaultInputAddress, .main, block)
    }
    
    func stop() {
        running = false
        rebuildWorkItem?.cancel()
        rebuildWorkItem = nil
        if let block = deviceListener {
            AudioObjectRemovePropertyListenerBlock(.system, &defaultInputAddress, .main, block)
        }
        deviceListener = nil
        engineQueue.sync { teardownEngine() }
    }
}
```

#### 2. 后台重建 + 超时

```swift
private func scheduleRebuild(reason: String) {
    guard running else { return }
    
    // 取消待执行的重建
    rebuildWorkItem?.cancel()
    
    let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.log.info("rebuild mic: \(reason, privacy: .public)")
        self.teardownEngine()
        
        var attempt = 0
        func tryBuild() {
            guard self.running else { return }
            
            // 创建超时监控
            let sema = DispatchSemaphore(value: 0)
            var buildError: Error?
            var success = false
            
            self.engineQueue.async {
                do {
                    try self.buildEngine()
                    success = true
                    sema.signal()
                } catch {
                    buildError = error
                    sema.signal()
                }
            }
            
            // 等待最多 8 秒（HAL 查询可能慢但通常不超过 5 秒）
            let timeout = sema.wait(timeout: .now() + 8)
            
            if timeout == .success, success {
                DispatchQueue.main.async {
                    self.onDeviceChange?(self.deviceName)
                }
                self.log.info("mic rebuild succeeded")
            } else {
                attempt += 1
                let msg = timeout == .timedOut ? "timeout" : (buildError?.localizedDescription ?? "unknown")
                self.log.error("rebuild failed (\(attempt)/3): \(msg, privacy: .public)")
                
                // 超时时记录警告，但不杀死 engineQueue 上的卡住任务（它会在后台继续或最终完成）
                if timeout == .timedOut {
                    self.log.warning("⚠️ buildEngine() stuck >8s, likely HAL plugin deadlock")
                }
                
                if attempt < 3, self.running {
                    DispatchQueue.global().asyncAfter(deadline: .now() + Double(attempt) * 2) {
                        tryBuild()
                    }
                } else {
                    self.log.error("mic rebuild exhausted, check HAL plugins")
                }
            }
        }
        tryBuild()
    }
    
    rebuildWorkItem = work
    // 合并短时间内的多次通知，延迟 0.5 秒执行
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5, execute: work)
}
```

#### 3. buildEngine 保持在 engineQueue

```swift
// 已经移出主线程，无需改动内部逻辑
private func buildEngine() throws {
    dispatchPrecondition(condition: .onQueue(engineQueue))
    let engine = AVAudioEngine()
    let input = engine.inputNode  // ← 可能慢，但不再阻塞主线程
    
    // ... 原有逻辑保持不变
}
```

### 3. 关键改进点

1. **start() 初次超时保护**：首次启动允许等待 10 秒，超时抛错
2. **scheduleRebuild 非阻塞**：在后台队列重建，超时不影响 UI
3. **超时后继续重试**：超时的任务在后台继续（可能最终完成），新重试另起炉灶
4. **重试退避**：第 1 次失败等 2 秒，第 2 次等 4 秒，最多 3 次
5. **日志可观测**：超时时打印警告，方便定位 HAL 插件问题

## 长期建议

### 1. 用户可见错误提示
重建失败 3 次后，在菜单栏或通知中提示：
```
"麦克风采集失败，可能是音频设备或第三方音频插件问题。请尝试：
1. 拔掉外接音频设备后重试
2. 在系统设置中更换默认输入设备
3. 禁用第三方音频插件（如 MSTeams、Parrot Audio）"
```

### 2. HAL 插件诊断工具
设置面板中添加"音频设备诊断"按钮，后台运行：
```bash
system_profiler SPAudioDataType
ls -la /Library/Audio/Plug-Ins/HAL/
```
输出设备列表和已安装插件，帮助用户定位问题插件。

### 3. Fallback 模式
连续重建失败后，提供"仅录制会议软件声音"模式（跳过麦克风，`MicRecorder` 不启动），让用户至少能录制远端音频。

## 验证场景

### 1. 正常设备切换
- 开始录音 → 插拔蓝牙耳机 → 确认自动重建成功且无 UI 卡顿

### 2. 模拟 HAL 慢响应
- 安装 BlackHole 2ch
- 创建聚合设备（Audio MIDI Setup.app）包含 10+ 子设备
- 开始录音 → 确认不卡主线程，最多等待 8 秒后显示错误

### 3. coreaudiod 异常
```bash
sudo killall coreaudiod  # 强制重启音频守护进程
```
- 录音期间执行 → 确认自动重建或优雅降级

## 回滚方案

如果新方案导致问题，回滚到当前 HEAD：
```bash
git diff HEAD Sources/MeetingASRApp/Capture/MicRecorder.swift
git checkout HEAD -- Sources/MeetingASRApp/Capture/MicRecorder.swift
```

## 相关资料

- Thread stack sample: `/tmp/masr_sample.txt`
- Hung process PID: 67703 (已于 2026-11-10 13:35 kill)
- Launch time: 2026-10-28 17:14:40
- Binary: `/Users/wj/Downloads/meeting/MeetingASR.app` (落后 HEAD 约 20 commits)
- HAL plugins: MSTeamsAudioDevice, ParrotAudioPlugin, BlackHole2ch, ByteviewAudioDevice

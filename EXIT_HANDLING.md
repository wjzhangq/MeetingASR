# CLI 优雅退出功能

## 实现内容

为 `meetingasr-cli` 添加了优雅退出处理，解决了 CLI 工具在处理过程中无法正常退出的问题。

## 修改文件

### 1. `Sources/meetingasr-cli/main.swift`
- 通过 `DispatchSource.makeSignalSource` 监听 SIGINT 与 SIGTERM
  （不在信号上下文中执行，因此可以安全加锁并写 stderr）
- 当用户按 Ctrl+C 时，发送取消信号给正在运行的处理器
- 如果再次按 Ctrl+C，强制退出
- 当前处理器的引用与退出标志由 `shutdownLock` 保护，供信号回调线程读取

### 2. `Sources/MeetingASRCore/Pipeline/MeetingProcessor.swift`
- 添加了公开的 `cancel()` 方法，允许外部取消正在进行的处理
- `process()` 把本次运行的取消标志登记到 `activeCancel`，`cancel()` 取消的正是
  调用方传入的那一个；流水线内部仍然只使用调用方的标志，
  因此 `ProcessingQueue`（GUI 取消按钮）的既有取消路径保持不变
- 没有任务在运行时 `cancel()` 无副作用，处理器不会进入永久取消状态
- 取消时会更新会议状态为 `.cancelled`，保留原始音频以便重试

## 使用方式

### 正常退出
在 CLI 运行过程中按 `Ctrl+C`：
```
正在退出，请稍候...
已取消，中间结果可能已保存
```

### 强制退出
如果第一次 Ctrl+C 后仍未退出，再次按 `Ctrl+C`：
```
强制退出
```

## 退出代码
- 130: 用户取消（SIGINT）
- 143: 终止信号（SIGTERM）

## 特性
- ✅ 优雅取消正在进行的处理任务
- ✅ 保留中间结果和原始音频
- ✅ 更新会议状态为已取消
- ✅ 支持强制退出（双击 Ctrl+C）
- ✅ 线程安全的取消机制

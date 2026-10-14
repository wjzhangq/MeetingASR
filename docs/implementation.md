# 实现说明

## 需求对照

| PRD | 实现位置 |
|---|---|
| FR-A1/A2/A6 Process Tap、子进程、重挂 | `MeetingASRApp/Capture/ProcessTapRecorder.swift`、`AudioProcessMonitor.swift` |
| FR-A3/A8/R8 麦克风、回声消除、设备重建 | `MeetingASRApp/Capture/MicRecorder.swift` |
| FR-A4 两轨、首帧主机时间、对齐 | `MeetingASRCore/Recording/SessionClock.swift`（`AlignedTrackWriter`） |
| FR-A5 未运行提示、仅录麦克风 | `AppState.preflight`、`StatusBarController.start` |
| FR-A7/A9 采集源、Bundle ID 配置 | `AppSettings`（`CaptureApp`）、设置 › 采集 |
| FR-R1~R4 状态与控制 | `AppState`、`StatusBarController`、`MenuPanelView` |
| FR-R5 标题与人数 | `StartRecordingForm` |
| FR-R6 快捷键 | `HotkeyManager`（Carbon，不需要辅助功能权限） |
| FR-R7 睡眠 | `SleepGuard` |
| FR-R9 异常退出恢复 | `MeetingStore.recoverInterruptedRecording/unfinishedMeetings`、`AppDelegate.promptUnfinished` |
| FR-P1~P7 流水线、进度、通知、热词、标点、删除、取消 | `MeetingProcessor`、`ProcessingQueue`、`Notifier`、`HotwordCorrector` |
| FR-V1~V5 预览 | `PreviewView`、`PreviewModel` |
| FR-N1~N11 人物标注 | `ClipSelector`、`SpeakerMatcher`、`PeopleStore`、`SpeakerNaming` |
| FR-S1~S5 存储 | `StorageLayout`、`MeetingStore`、`TranscriptWriter` |
| FR-F1~F5 文件识别 | `MeetingFactory.createFileMeeting`、`FileRecognizeView`、菜单栏拖放 |
| FR-C1~C6 设置 | `SettingsView` |

## 第 11 章待确认项的默认处理

| 项目 | 当前处理（均可在代码/设置中调整） |
|---|---|
| 特征片段数量与时长 | 每人 3 段，单段 3~8 秒（设置可调 1~6 段）；不足 3 秒时退而取最长段 |
| 识别失败或取消 | 保留 `.raw/` 原始音频，meta 状态为 failed/cancelled，菜单与启动时提示重新识别；中间文件删除 |
| 麦克风轨说话人 | 与其他说话人相同：挑片段、算声纹、参与自动匹配与命名 |
| 人物库改名是否回溯 | 默认不回溯；`SpeakerNaming.refreshNames` 提供按会议刷新的能力 |
| 人物库管理 | 设置 › 人物库：查看样本来源、试听、改名、合并、删除 |
| 预计说话人数（线上会议） | 用户填写的人数包含本人，会议软件轨按 人数−1 聚类 |

## 热词（R1 验证结论）

sherpa-onnx 的 contextual biasing 仅支持 Transducer + modified_beam_search，离线 Paraformer 不支持。按 PRD 备选方案 1 实现后处理纠错：中文热词按无声调拼音匹配同长度片段（三字以上允许一个模糊音：平翘舌、n/l、h/f、r/l、前后鼻音），英文热词忽略大小写与空格规范写法；等长替换保证字级时间戳仍一一对应。人物库姓名自动加入热词。

## 时间轴与对齐

所有音轨按同一个会话时钟写入：暂停期间的数据丢弃；输入出现空档（暂停恢复、Tap 重新挂载、输入设备重建）时补静音；时钟回退时裁掉重叠部分。各轨首帧主机时间写入 meta，识别时以最早首帧为 0 点换算各轨偏移。暂停位置以"已录音频时长"记录，Markdown 中在对应位置插入"（暂停）"。

## 性能实测（Linux x86 容器，4 线程，release）

10 分 25 秒单轨中文音频：模型加载 6.5s，预处理 0.4s，说话人分离 75.5s，语音识别 24.2s，人物匹配 2.8s，总计 103s（RTF 0.16）。分离是主要耗时；Apple Silicon 预期明显更快，M0 需在 M1 上用 1 小时双轨录音实测。可调参数：`numThreads`、pyannote `window_shift_ratio`（当前为上游默认 0.1）。

## 验证

- `swift test`：52 个单元测试，覆盖存储、音频、分段、回声、输出、匹配、人物库、命名、热词、流水线（模拟引擎的双轨会议、自动认人与改正、取消重试、队列）、会话时钟与录音恢复。
- `meetingasr-cli` 已用真实模型在 sherpa-onnx 官方 4 人中文测试音频上验证：分离与转写正确；命名后再次识别时，已命名人物被自动标注（相似度 0.98/0.99），未命名人物最佳相似度 0.45 保持未命名。
- macOS 采集与 UI 代码由 CI（`.github/workflows/build.yml`，macos-15）编译验证；Process Tap、权限弹窗、通知等需在真机验证。

# MeetingASR

本地会议识别 App（macOS 14.2+，Apple Silicon）。录制腾讯会议 / Microsoft Teams 的会议声音和本机麦克风，会后离线完成说话人分离与中文语音识别，输出带说话人、带时间戳的逐字稿，并通过人物声纹库在后续会议中自动标注真实姓名。

- **全本地**：录音、推理、结果存储都在本机，运行时不联网，模型随 App 打包。
- **最小留存**：识别成功并校验结果文件后立即删除原始录音，只保留文本和每位说话人的少量特征片段。
- **轻量**：纯 Swift + sherpa-onnx（C API），无 Python 依赖，CPU 运行。

## 功能

| 模块 | 内容 |
|---|---|
| 音频采集 | Core Audio Process Tap 采集会议软件（同一软件的多个子进程纳入同一个 Tap；进程重启/新增子进程自动重新挂载）；AVAudioEngine 采集麦克风（可选输入设备、系统回声消除、设备变化自动重建）；两轨独立录制，记录首帧主机时间，暂停/断流按会话时钟补静音对齐 |
| 录音控制 | 菜单栏状态（空闲/录音中红色+时长/已暂停/处理中+进度）、开始（可填标题与预计人数）、暂停/继续、停止后自动识别、全局快捷键、录音时阻止空闲睡眠，强制睡眠自动暂停并在唤醒后询问、异常退出后提示继续识别 |
| 识别流程 | 预处理（重采样 16k + 响度归一）→ 说话人分离（pyannote 3.0 + CAM++ + 聚类）→ 分段 ASR（Paraformer-zh，字级时间戳）→ 标点（CT-Transformer）→ 热词纠错 → 特征片段与人物匹配 → 输出 → 删除原始音频；串行队列，可取消，失败/取消保留原始音频以便重试 |
| 线上会议 | 麦克风轨整轨一个说话人只做 VAD；会议软件轨做分离；回声判定（麦克风段与系统轨能量包络高度相关且更弱时丢弃）；外放时提示使用耳机 |
| 结果预览 | 说话人卡片（姓名/标签、发言时长、“自动识别/未命名/已标注”、特征片段试听）、按说话人分段的逐字稿、搜索高亮、一键复制、在 Finder 中显示、独立窗口打开 |
| 人物标注 | 输入新姓名或从人物库联想选择、确认/改正自动识别（撤销原人物样本并加入正确人物）、同名即合并、标为“多人”、清除；三种结果文件同步更新 |
| 人物库 | 匈牙利算法一对一分配，相似度 ≥ 阈值直接标注；样本上限淘汰最旧；保留代表片段，声纹模型升级时可重新提取；设置中可改名、合并、删除 |
| 文件识别 | wav/m4a/mp3/aac/flac，可指定时间范围与人数，支持拖拽到菜单栏图标 |
| 设置 | 采集源、输入设备、回声消除、会议软件 Bundle ID 列表（可扩展飞书/Zoom 等）、默认人数、聚类/匹配阈值、热词表、快捷键、开机自启、人物库管理 |

## 数据目录

```
~/Documents/MeetingASR/
├── meetings/<YYYY-MM-DD_HHmmss_标题>/
│   ├── meta.json          # 来源、时长、暂停区间、模型版本、处理状态、原始音频删除时间
│   ├── transcript.json    # 主数据（结构见 PRD 3.6）
│   ├── transcript.md
│   ├── transcript.srt
│   └── speakers/{speakers.json, S1_01.wav, …}
└── people/{people.json, <person-id>/01.wav …}
```

热词表：`~/Library/Application Support/MeetingASR/hotwords.txt`（一行一个词）；设置：同目录 `settings.json`。

## 构建

需要 macOS 14.2+、Xcode 15.1+（Apple Silicon）。

```bash
scripts/fetch-sherpa-onnx.sh     # 下载 sherpa-onnx 预编译库到 Vendor/
scripts/fetch-models.sh          # 下载模型到 Resources/models/（约 550MB）
scripts/build-app.sh             # 生成 dist/MeetingASR.app（ad-hoc 签名）

# Developer ID 签名 + 公证
SIGN_IDENTITY="Developer ID Application: XXX (TEAMID)" NOTARY_PROFILE=<keychain-profile> scripts/build-app.sh
```

开发调试：`swift build`、`swift test`；`swift run MeetingASR` 运行菜单栏 App（需设置 `MEETINGASR_MODELS=$PWD/Resources/models`；Process Tap 与通知需要以 .app 形式运行才能正常申请权限）。

### 命令行

`meetingasr-cli` 无界面执行完整流程，用于 M0 评估和批量处理（macOS 与 Linux 均可）：

```bash
swift build -c release
.build/release/meetingasr-cli recognize 会议.m4a --from 60 --to 1800 --speakers 4
.build/release/meetingasr-cli name 2026-10-14_143000_周会 S2 张三
.build/release/meetingasr-cli list | show <会议> | people | process <会议>
```

Linux 上可用 `scripts/docker-test.sh` 在 `swift:6.0` 容器中运行单元测试。

## 代码结构

| 目标 | 说明 |
|---|---|
| `MeetingASRCore` | 与平台无关：数据结构、存储、WAV/重采样/预处理、分段与回声判定、匹配与人物库、命名、热词纠错、输出、流水线与任务队列、会话时钟 |
| `MeetingASREngine` | sherpa-onnx 适配（ASR、标点、分离、声纹、VAD） |
| `SherpaOnnx` / `SherpaOnnxC` | 上游 Swift 封装与 C API 模块 |
| `MeetingASRApp` | macOS 菜单栏 App：采集、录音会话、UI、系统服务 |
| `meetingasr-cli` | 命令行 |

更多设计说明与待确认项的默认处理见 [docs/implementation.md](docs/implementation.md)。

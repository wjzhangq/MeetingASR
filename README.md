# MeetingASR

[![build](https://github.com/wjzhangq/MeetingASR/actions/workflows/build.yml/badge.svg)](https://github.com/wjzhangq/MeetingASR/actions/workflows/build.yml)

**完全本地运行的会议识别工具（macOS 菜单栏应用）**。录制腾讯会议、Microsoft Teams 的会议声音与本机麦克风，会后离线完成说话人分离和中文语音识别，输出带说话人、带时间戳的逐字稿；通过人物声纹库，在之后的会议中自动把说话人标注为真实姓名。

| 项目 | 内容 |
|---|---|
| 平台 | macOS 14.2+，仅 Apple Silicon（arm64） |
| 语言 | Swift（SwiftUI + AppKit + Core Audio） |
| 推理 | [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)（C API），CPU 运行，无 Python 依赖 |
| 模型 | Paraformer-zh（ASR）、3D-Speaker CAM++（声纹）、CT-Transformer（标点）、Silero VAD |
| 流程 | VAD 段驱动，ASR 与声纹并行提取，球面 K-Means 聚类（可复现） |

## 设计原则

- **全本地**：录音、推理、结果存储都不出本机，运行时不发起任何网络请求，模型随 App 打包。
- **最小留存**：识别成功、结果文件写入并校验通过后，**立即删除原始录音**，只保留文字结果和每位说话人的少量特征片段。
- **非实时**：不做实时字幕，停止后批处理出结果，准确率优先；录音期间只在后台提前做说话人分离，缩短会后等待。
- **原生轻量**：纯 Swift，单个 `.app` 分发。

---

## 目录

- [功能概览](#功能概览)
- [快速开始](#快速开始)
- [使用指南](#使用指南)
- [数据与隐私](#数据与隐私)
- [识别流程](#识别流程)
- [命令行工具](#命令行工具)
- [开发](#开发)
- [代码结构](#代码结构)
- [性能](#性能)
- [已知局限](#已知局限)
- [常见问题](#常见问题)

---

## 功能概览

### 录音
- **两轨独立录制**：会议软件声音（Core Audio Process Tap）与麦克风（AVAudioEngine）分轨保存，以 **16 kHz** 采样率录制（与模型匹配），记录各轨首帧主机时间用于对齐。
- **会议软件识别**：按 Bundle ID 匹配，默认支持腾讯会议（`com.tencent.meeting`）与新/旧版 Teams（`com.microsoft.teams2` / `com.microsoft.teams`）；同一软件的多个音频子进程纳入同一个 Tap。可在设置中扩展飞书、Zoom 等。
- **健壮性**：会议软件中途重启/退出时自动重新挂载 Tap，不中断麦克风轨；插拔耳机等输入设备变化时自动重建采集链路；断流区间补静音，保证两轨时间轴一致。
- **会议检测**：已启用的会议软件（如 Teams、腾讯会议）持续占用麦克风 5 秒即视为会议开始，在屏幕右上角弹出提示询问是否录音（不切走会议窗口）：按 **回车** 或全局快捷键 **⌥⌘R** 开始录音，**Esc** 关闭，**5 秒**无操作自动关闭（本次不录）；会议结束（会议软件不再采集也不再播放声音 15 秒）后自动停止录音并开始识别。只会自动停止检测到会议的录音；两项均可在 设置 › 采集 › 会议检测 中关闭。
- **控制**：开始（可填会议标题与预计人数）、暂停/继续（暂停区间记入元数据）、停止后自动识别；全局快捷键（默认 ⌥⌘R 开始/停止、⌥⌘P 暂停/继续）。
- **系统集成**：录音期间阻止空闲睡眠；系统强制睡眠时自动暂停，唤醒后询问是否继续；异常退出后下次启动提示继续识别。
- **回声**：可选开启系统回声消除；检测到扬声器外放时提示使用耳机；识别时自动丢弃串入麦克风轨的远端回声段。

### 识别
- **录音时识别**：录音期间语音段（由 VAD 切出）闭合后，立即在后台（低优先级、2 线程）做 ASR 识别和声纹提取，结果写入段日志；停止后只需补识别尾段并做聚类、回声处理，长会议的会后等待大幅缩短。可在 设置 › 识别 › 录音时识别 中关闭。
- 预处理 → 按 VAD 段识别与声纹提取 → 聚类分配说话人 → 回声判定 → 特征提取与人物匹配 → 输出 → 删除原始音频，后台串行队列执行（处理中可以开始新的录音）。
- 菜单栏显示当前阶段与进度百分比，完成后发送系统通知，点击直接打开结果。
- 输出带标点，有字级时间戳；支持热词表；可取消任务，失败或取消时保留原始音频以便重试。

### 结果预览与人物标注
- 顶部**说话人卡片**：姓名或 S1/S2 标签（颜色区分）、发言时长、“自动识别 / 未命名 / 已标注”标记、特征片段试听。
- 卡片上可**输入新姓名**或**从人物库联想选择**；改正错误的自动识别；为两个标签填同一姓名即**合并**；可标为“多人”或清除。
- 每次改动同步更新 `transcript.json / md / srt` 和人物库。
- 逐字稿按说话人分段展示，支持搜索高亮、一键复制全文、在 Finder 中显示、在独立窗口打开。
- **会议管理**：在“最近会议”中右键某条会议，或在结果预览右上角的 ⋯ 菜单中，可**重命名**（同步更新逐字稿中的标题，会议目录名不变）或**删除**会议（永久删除逐字稿、特征片段和未识别的原始录音，人物库中的声纹样本保留）。录音或识别中的会议需完成后再操作。

### 人物声纹库
- 人物库非空时自动比对：匈牙利算法一对一分配（同一场会议两个说话人不会匹配到同一人），相似度 ≥ 阈值（默认 0.6）直接标注姓名。
- 用户确认的标注、以及未被改动的自动识别结果都会作为样本加入人物库；改正时撤销原样本。每人最多 20 条样本，超出淘汰最旧的。
- 人物库保留代表片段而不只是向量，将来更换声纹模型时可用片段重新提取，人物库不失效。
- **声纹库窗口**（菜单“声纹库…”，或 设置 › 通用 › 打开声纹库…）：单独管理所有人物——查看样本来源并试听、改名、合并、删除，以及**设置人物颜色**。
- **人物颜色**：新建人物时自动从 12 色色板中取一个尚未使用的颜色；可在声纹库中点选色板或用取色器自定义，也可“恢复默认”。该颜色在所有会议的说话人卡片和逐字稿中保持一致，改动后已打开的预览立即刷新。

### 文件识别
- 菜单“识别音频文件…”或把文件**拖到菜单栏图标**上；支持 wav、m4a、mp3、aac、flac；可指定识别的时间范围与说话人数。源文件不会被修改或删除。

---

## 快速开始

### 从 Release 安装（推荐）

1. 在 [Releases](https://github.com/wjzhangq/MeetingASR/releases) 下载 `MeetingASR-<版本>-macos-arm64.zip`，解压后把 `MeetingASR.app` 拖到“应用程序”文件夹。
2. Release 包只做了 ad-hoc 签名、未经 Apple 公证，从网上下载后直接打开会被 Gatekeeper 拦截（提示“已损坏”或“无法验证开发者”）。在终端执行：

```bash
cd /Applications

# 1. 移除隔离属性：清除下载文件的 quarantine 标记
xattr -dr com.apple.quarantine MeetingASR.app

# 2. Ad-hoc 签名：在本机重新签名（包括 Contents/Frameworks 中的 sherpa-onnx 动态库）
codesign --force --deep --sign - MeetingASR.app

# 3. 验证签名：输出 “valid on disk” 和 “satisfies its Designated Requirement” 即通过
codesign --verify --deep --strict --verbose=2 MeetingASR.app
```

3. 签名验证通过后，应用即可在本机正常运行：`open /Applications/MeetingASR.app`，或在“应用程序”中双击打开。

> - 每次下载新版本覆盖安装后，都需要重新执行以上三步。
> - 重新签名后，系统可能会把它当作新应用，再次询问麦克风 / 系统录音权限；如录不到声音，到 系统设置 › 隐私与安全性 › 麦克风 / 屏幕与系统录音 中删掉旧的 MeetingASR 条目后重新允许。
> - 模型较大，未随 App 打包时首次启动会提示下载（也可手动下载 Release 中的 `meetingasr-models.tar.bz2`）。

### 从源码构建

#### 环境要求
- Apple Silicon Mac，macOS 14.2 或更新
- Xcode 15.1+（或对应的 Swift 5.9+ 工具链）
- 约 1 GB 磁盘空间（模型约 550 MB）

#### 构建 App

```bash
git clone https://github.com/wjzhangq/MeetingASR.git
cd MeetingASR
scripts/build-app.sh          # 下载依赖与模型、编译、打包、ad-hoc 签名
open dist/MeetingASR.app
```

`build-app.sh` 会依次执行：

1. `scripts/fetch-sherpa-onnx.sh`：下载 sherpa-onnx 预编译共享库（v1.13.8）到 `Vendor/sherpa-onnx/`
2. `scripts/fetch-models.sh`：下载模型到 `Resources/models/`
3. `swift build -c release --arch arm64`
4. 组装 `dist/MeetingASR.app`（模型放入 `Contents/Resources/models`，动态库放入 `Contents/Frameworks`），启用 Hardened Runtime 签名

#### 正式分发（Developer ID 签名 + 公证）

```bash
xcrun notarytool store-credentials meetingasr-notary   # 首次：保存公证凭据
SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" \
NOTARY_PROFILE=meetingasr-notary \
scripts/build-app.sh
# 产物：dist/MeetingASR.app 与已公证的 dist/MeetingASR.zip
```

---

## 使用指南

### 首次启动
App 只在菜单栏显示图标（不出现在 Dock）。首次启动会显示引导页：
- **麦克风权限**：点击“允许”。
- **系统录音权限**：第一次录制会议软件声音时由系统弹窗请求（`NSAudioCaptureUsageDescription`），请选择允许。
- 阅读隐私与声纹信息告知后点击“开始使用”。

如权限被拒绝，可在 **系统设置 › 隐私与安全性 › 麦克风 / 屏幕与系统录音** 中重新开启。

### 录制一场线上会议
**自动检测（推荐）**：打开 Teams 或腾讯会议并入会，开麦约 5 秒后屏幕右上角弹出“检测到 … 会议，开始录音？”：
- 按 **回车** 或 **⌥⌘R**（设置中的“开始 / 停止”快捷键，会议窗口在前台时也有效）→ 开始录音；
- 按 **Esc** 或点“本次不录” → 关闭；
- **5 秒**内不操作 → 提示自动关闭，本次不录（之后仍可手动开始）。

会议结束后自动停止录音并开始识别。

**手动开始**：
1. 打开腾讯会议或 Teams 并入会。
2. 点击菜单栏图标 → **开始录音**，可填写会议标题和预计说话人数（含本人），也可以“跳过并开始”。
3. 录音中菜单栏图标变红并显示已录时长；可随时 **暂停 / 继续**。
4. 点击 **停止**，自动进入识别；菜单栏显示“处理中 xx%”。
5. 完成后收到系统通知，点击即可打开结果预览。

> 若开始录音时会议软件未运行，会提示“仅录麦克风”或“开始并等待会议软件”——选择后者时，会议软件一启动就会自动开始采集。

### 线下会议
在 设置 › 采集 中把采集源设为“仅麦克风”，录制后会对单轨音频做说话人分离。

### 重命名 / 删除会议
- 菜单栏弹层的“最近会议”中**右键**某条会议 → 重命名… / 在 Finder 中显示 / 删除…
- 或打开结果预览，点击右上角 **⋯** → 重命名… / 删除会议…

重命名只改标题（菜单、预览、`transcript.json/md/srt` 中的标题），会议目录名保持不变。删除会弹出确认，删除后无法恢复；人物库中已保存的声纹样本不受影响。正在录音、排队或识别中的会议需等完成后再操作。

### 标注人物
1. 打开结果预览（菜单“查看最近结果”或“最近会议”中的任意一条）。
2. 在说话人卡片上点击 ▶ 试听特征片段，确认是谁。
3. 点击“命名”，输入姓名（会联想人物库中已有的人）或从候选中选择，回车确认。
4. 自动识别正确时可点“确认”；错误时点“修改”改成正确的人，人物库随之更新。
5. 分离把同一人拆成了两个标签时，给它们填同一个姓名即可合并。

之后的会议中，已命名的人物会被自动标注，卡片显示“自动识别”。

### 管理声纹库与人物颜色
菜单栏 → **声纹库…** 打开独立窗口：左侧为人物列表（带颜色圆点与样本数），右侧可改名、合并到另一人、选择颜色（色板或自定义取色，“默认”恢复按会议内顺序取色）、试听各条样本、删除人物。改名不回溯修改历史逐字稿；颜色是显示属性，所有会议中立即生效。

### 设置

| 页面 | 内容 |
|---|---|
| 通用 | 登录时自动启动、全局快捷键、存储目录、打开声纹库 |
| 采集 | 采集源（仅麦克风 / 仅会议软件 / 两者）、麦克风输入设备、回声消除、会议软件 Bundle ID 列表 |
| 识别 | 识别模型、识别方式（段流水线 / 先识别再分配 / 按说话人段）、执行后端（CPU / 神经引擎）、录音时识别；默认说话人数；高级：VAD 与聚类参数、声纹匹配阈值、特征片段数、每人样本上限、推理线程数 |
| 热词 | 一行一个词（项目名、产品名、人名） |

---

## 数据与隐私

所有数据保存在本机：

```
~/Documents/MeetingASR/
├── meetings/
│   └── 2026-10-14_143000_周会/
│       ├── meta.json              # 来源、时长、暂停区间、模型版本、处理状态、原始音频删除时间
│       ├── transcript.json        # 结构化结果（主数据）
│       ├── transcript.md          # 阅读用
│       ├── transcript.srt         # 字幕
│       └── speakers/
│           ├── speakers.json      # 各说话人声纹向量、匹配结果、片段列表
│           ├── S1_01.wav          # 特征片段，16kHz 单声道
│           └── S2_01.wav
└── people/
    ├── people.json                # 人物库：ID、姓名、颜色、声纹样本、来源会议
    └── <person-id>/01.wav …       # 人物代表片段

~/Library/Application Support/MeetingASR/
├── settings.json                  # 设置
└── hotwords.txt                   # 热词表
```

- 录音进行中及识别完成前，原始音频临时存放在会议目录的 `.raw/` 中；识别成功并校验结果后**直接删除**（不进废纸篓），删除时间记入 `meta.json`。
- 识别失败或被取消时保留 `.raw/`，可在菜单中“重新识别”。
- 录音时菜单栏图标为红色。请在录音前告知与会者。

`transcript.json` 示例：

```json
{
  "version": 2,
  "title": "周会",
  "created_at": "2026-10-14T14:30:00+08:00",
  "duration_sec": 3605.2,
  "speakers": [
    { "id": "S1", "track": "mic",    "person_id": "p_8f2a", "name": "李四", "source": "auto" },
    { "id": "S2", "track": "system", "person_id": "p_31c0", "name": "张三", "source": "user" },
    { "id": "S3", "track": "system", "person_id": null,     "name": "S3",   "source": "none" }
  ],
  "segments": [
    { "speaker": "S2", "start": 12.34, "end": 18.90, "text": "我们先过一下上周的进度。",
      "tokens": [ { "t": "我", "start": 12.40 }, { "t": "们", "start": 12.58 } ] }
  ],
  "models": { "asr": "sherpa-onnx-paraformer-zh", "segmentation": "pyannote-segmentation-3.0", "embedding": "3dspeaker-campplus-zh-cn-16k" }
}
```

`source`：`auto` 自动识别、`user` 用户标注、`none` 未命名。

---

## 识别流程

默认使用**段流水线**（`segmentStream`）：以 Silero VAD 切出的语音段为调度单元，ASR 与声纹提取并行执行。开启“录音时识别”后，切段、识别、声纹提取都在**录音期间**完成，停止后只补尾段再做聚类与收尾。详见 [docs/segment-pipeline.md](docs/segment-pipeline.md)。

```
【录音期间】采集已是 16kHz 单声道，边写 .raw/*.wav 边送进流式 VAD
                                                     │
          Silero VAD 切段（静音 >0.4s 切开，单段 ≤12s）→ 前补 0.15s、后补 0.1s
                                                     │
          有界队列（最多 2 个在排、4 个待命）：段闭合即送后台 utility 队列
          队列满 / 窗口超限 → 该轨让位，未覆盖的部分留给会后从文件补
                                                     │
                     ┌───────────────┴───────────────┐
              ASR Worker（Paraformer）        声纹 Worker（CAM++）
              文本 + 字级时间戳                <1s 整段 / 1~4s 整段 / >4s 子窗口
                     └───────────────┬───────────────┘   （子窗口相似度低谷 → 标记混合段）
                                                     │
          回声预判（麦克风段 vs 系统轨）→ 段结果追加 segments_<轨>.jsonl
                                      已识别到的文件时间写 segments_<轨>.cover
                                                     │
【停止录音】等在队列里的段写完 → 按 .cover 只对未覆盖部分补切段、补识别
                                                     │
      球面 K-Means 聚类（每轨独立，固定种子）：k=min(20,段数) → 迭代合并（相似度 ≥0.38）
                      → 小簇吸收（<3s）→ 按最终中心重新分配
                      麦克风轨（线上会议双轨时）跳过聚类，整轨一人
                                                     │
      短段（<1s）：相似度 ≥0.25 归簇，否则归 ±2s 内时间最近的同轨说话人
      混合段：子窗口各自归簇 → 标签平滑（<1.5s 的游程并入邻侧）→ 在切点按字级时间戳拆分
                                                     │
                 回声判定：麦克风段与系统轨能量包络高度相关且更弱 → 丢弃
                                                     │
            文本层回声兜底（双轨）：麦克风轨与会议软件轨同时（滞后 ≤1s）同字成片 → 删除
                                                     │
          轮次合并：同一说话人、间隔 <1s 的相邻段合并为一轮（标点在轮次上做，上下文更完整）
                                                     │
                       热词纠错 → 英文缩写规范（a s r → ASR）→ CT-Transformer 标点
                                                     │
          每位说话人：挑选特征片段（声纹代表性 × 信噪比，时间分散，3~8 秒）→ 声纹均值
                                                     │
                       与人物库匹配（匈牙利一对一，≥ 阈值直接标注）→ 自动样本入库
                                                     │
               写出 transcript.json / md / srt、speakers/ → 校验 → 删除 .raw/
```

**为什么以段为单元**：按说话人切出的段与 ASR 的分段彼此独立时，说话人边界和字边界对不齐；分离与识别串行执行时两个 CPU 密集阶段谁也用不满核。改以 VAD 段驱动后，ASR 与声纹并行处理同一段，说话人边界天然与字级时间戳对齐，聚类用固定种子的球面 K-Means 保证同一录音每次结果一致。**录音时识别**进一步把识别和声纹提取前移到录音期间，语音段闭合后立即处理，停止后只剩聚类与后处理，长会议的会后等待时间从分钟级降到秒级。

**三种识别方式**（设置 › 识别，或 CLI `--mode`）：

| 模式 | 说明 |
|---|---|
| `segment-stream` | 默认。VAD 段驱动，ASR ∥ 声纹并行，结果可复现 |
| `asr-first` | 按音轨组合成 10~25s 长句块识别，再按字级时间戳分配说话人；ASR 上下文最完整 |
| `segment` | 先分离（pyannote / 固定窗口）再按说话人段逐段识别；兼容旧流程与对比测试 |

模型不输出字级时间戳（FireRedASR-AED）时自动退回按段识别。

**热词**：sherpa-onnx 的热词（contextual biasing）不支持离线 Paraformer / FireRedASR，因此采用后处理纠错——中文热词按拼音近似匹配同长度片段（三字以上允许一个模糊音：平翘舌、n/l、h/f、r/l、前后鼻音），英文热词忽略大小写规范写法。人物库中的姓名自动加入热词。

---

### 识别模型：FireRedASR（可选）

默认使用 Paraformer-zh。对中英混说、技术术语要求更高时，可在 设置 › 识别 › 识别模型 中选择 FireRedASR 并点击“下载安装”（从 sherpa-onnx 发布页下载到 `~/Library/Application Support/MeetingASR/models/`），从下一次识别生效：

| 模型 | 目录 | 字级时间戳 | 说明 |
|---|---|---|---|
| Paraformer-zh | `asr/` | 有 | 默认，随 App 下载 |
| FireRedASR2-CTC 中英 | `asr-firered-ctc/`（model.int8.onnx、tokens.txt） | 有 | 推荐的升级选项，支持“先识别再分配说话人” |
| FireRedASR-AED Large 中英 | `asr-firered-aed/`（encoder/decoder.int8.onnx、tokens.txt） | 无 | 准确率最高、最慢，自动按段识别 |

开发时也可以用脚本下载：`scripts/fetch-models.sh --with-asr firered-ctc`（或 `firered-aed`）。所选模型未安装时自动使用 Paraformer，结果的 `models.asr` 记录实际使用的模型。

---

## 命令行工具

`meetingasr-cli` 无界面执行完整流程，适合批量处理和调参评估（macOS / Linux 均可运行）：

```bash
swift build -c release
export MEETINGASR_MODELS=$PWD/Resources/models

.build/release/meetingasr-cli recognize 会议.m4a                     # 识别整个文件
.build/release/meetingasr-cli recognize 会议.m4a --from 60 --to 1800 --speakers 4
.build/release/meetingasr-cli recognize 会议.m4a --asr-model firered-ctc   # 指定识别模型
.build/release/meetingasr-cli recognize 会议.m4a --mode asr-first          # 先识别再分配（对比用）

# 参数调优（段流水线模式）
.build/release/meetingasr-cli recognize 会议.m4a --vad-min-silence 0.4 --merge-similarity 0.38

# M0 评估：参数网格扫描（需准备会议列表文件）
echo -e "meeting-001\nmeeting-002\nmeeting-003" > meetings.txt
.build/release/meetingasr-cli sweep meetings.txt > results.csv

.build/release/meetingasr-cli list                                   # 最近会议
.build/release/meetingasr-cli show 2026-10-14_143000_周会             # 打印 Markdown
.build/release/meetingasr-cli name 2026-10-14_143000_周会 S2 张三      # 命名（姓名为空则清除）
.build/release/meetingasr-cli rename 2026-10-14_143000_周会 产品评审     # 改标题（目录名不变）
.build/release/meetingasr-cli delete 2026-10-14_143000_周会           # 删除会议（不可恢复）
.build/release/meetingasr-cli people                                 # 人物库
.build/release/meetingasr-cli process 2026-10-14_143000_周会          # 重新识别未完成的会议
```

通用选项：`--root <数据目录>`、`--models <模型目录>`、`--threads N`、`--threshold X`（聚类阈值）、`--match X`（声纹匹配阈值）、`--keep-work`（保留中间文件）。运行时会在 stderr 输出各阶段耗时与 RTF。

---

## 开发

```bash
scripts/fetch-sherpa-onnx.sh     # 首次必须：下载 sherpa-onnx 头文件与动态库
swift build                      # 编译全部目标
swift test                       # 运行单元测试
```

- 在 Xcode 中直接打开 `Package.swift` 即可开发调试。
- `swift run MeetingASR` 可启动菜单栏 App（需设置 `MEETINGASR_MODELS`）；Process Tap、通知、开机自启等需要以签名后的 `.app` 运行才能正常申请权限。
- Linux 上可用 `scripts/docker-test.sh` 在 `swift:6.0-noble` 容器中编译并运行与平台无关的测试与 CLI。
- CI（`.github/workflows/build.yml`）在 macOS 15 上编译 App 与 CLI 并运行测试，在 Linux 容器中运行测试。

### 测试覆盖

100 多个单元测试，覆盖：存储与 JSON 格式、WAV 读写（含异常退出的未回填头部）、重采样与预处理、分段规则、回声判定、三种输出格式、匈牙利算法与匹配、人物库（上限淘汰/撤销/合并/重新提取/颜色）、命名与合并、热词纠错、会话时钟与对齐写入、录音中断恢复、录音时增量分离与缓存复用，以及使用模拟引擎的完整流水线（双轨会议、自动认人、改正、取消重试、任务队列）。

---

## 代码结构

```
Sources/
├── MeetingASRCore/        与平台无关的业务逻辑（可在 Linux 测试）
│   ├── Models/            transcript / meta / speakers / people / 设置
│   ├── Storage/           目录布局、会议读写、未完成检测、会议创建
│   ├── Audio/             WAV 读写、AVFoundation 解码、重采样、预处理
│   ├── Processing/        分段后处理、回声判定
│   ├── People/            向量运算、匈牙利算法、匹配、片段挑选、人物库、命名
│   ├── Text/              热词表与纠错
│   ├── Output/            json / md / srt / 纯文本
│   ├── Pipeline/          引擎协议、流水线、进度与取消、任务队列
│   └── Recording/         会话时钟、对齐音轨写入
├── MeetingASREngine/      sherpa-onnx 适配：ASR、标点、分离、声纹、VAD、模型路径
├── SherpaOnnx/            上游 Swift 封装（Apache-2.0）
├── SherpaOnnxC/           C API 模块映射
├── MeetingASRApp/         macOS 菜单栏 App
│   ├── Capture/           Process Tap、麦克风、进程枚举、录音会话
│   ├── App/               入口、状态中心、菜单栏控制器
│   ├── UI/                面板、结果预览、说话人卡片、设置、引导、文件识别
│   └── System/            睡眠、全局快捷键、通知、开机自启
└── meetingasr-cli/        命令行工具
App/                       Info.plist、entitlements
scripts/                   依赖/模型下载、打包签名公证、Docker 测试
docs/implementation.md     需求对照与实现说明
```

---

## 性能

| 指标 | 目标 | 现状 |
|---|---|---|
| 1 小时双轨会议处理 | M1 上 ≤ 10 分钟 | Linux x86 4 线程容器实测 1 小时单轨 476 秒（RTF 0.13）：说话人分离 368 秒、识别 102 秒；需在 M1 上实测确认 |
| 处理进度 | 不长时间停住 | 长音频按 5 分钟分块分离，推理库无回调的阶段由进度心跳按实测速度推进 |
| 录音时 CPU / 内存 | ≤ 5% / ≤ 150MB | 录音本身只写 16kHz 单声道 WAV；开启“录音时识别”后语音段闭合即在后台低优先级识别（2 线程、同时只跑 1 段），平均 CPU 会高一些，可在设置中关闭 |
| 识别内存峰值 | ≤ 1.5GB | 录音时识别只保留最近几十秒的音频窗口；会后补段按段读取 |

可调：设置中的推理线程数。

**长会议**：sherpa-onnx 的分离一次处理整段音频，前半程（pyannote 切分）没有进度回调、中途无法取消（1 小时会议在测试机上进度停住近 3 分钟）。超过 7.5 分钟的音轨按约 5 分钟分块（切点选在附近最安静处），每块独立分离，块之间更新进度、响应取消；之后用 CAM++ 声纹中心跨块统一说话人编号（同一块内的不同说话人不会被合并），再做簇合并。无回调的阶段（VAD 之外的切分、聚类、跨块关联）由进度心跳按本机实测速度持续推进。

**录音时识别**：开启后，语音段闭合后立即在后台（低优先级、2 线程，最多同时 1 个段）做 ASR 和声纹提取，结果写入 `.raw/segments_<轨>.jsonl`，已覆盖的文件时间写 `.raw/segments_<轨>.cover`。停止录音时等队列里的段处理完，识别时按 `.cover` 只补未覆盖的尾段（通常不到半分钟音频），然后直接用段日志做聚类与后处理。参数（VAD 配置、模型）变化时段日志自动作废，按原流程整段识别。队列有界（最多 2 个在排、4 个待命），队列满或内存窗口超限时该轨让位，未识别的部分留到会后从文件补。长会议（1 小时+）停止后的识别从原先的数分钟降到十几秒。

**处理中录下一场会议**：识别在后台低优先级（utility）队列串行执行，录音走 Core Audio 实时线程，互不阻塞；录完的会议自动排队。

---

## 已知局限

- 原始音频识别后即删除：如果分离把两个人合成了一个说话人，事后无法拆分，只能整体命名或标为“多人”；也无法修改参数后重新识别。
- 不支持实时字幕、会前声纹注册、云同步、逐字稿手动编辑。
- 热词为后处理纠错，对同音异形的覆盖有限。
- 会议软件的 Bundle ID 以实际安装版本为准，如采集不到声音，请在 设置 › 采集 中补充（子进程会按前缀自动匹配）。

---

## 常见问题

**录不到会议软件的声音？**
确认已在 系统设置 › 隐私与安全性 › 屏幕与系统录音 中允许 MeetingASR；确认会议软件在设置的 Bundle ID 列表中且已启用；录音中菜单面板会显示“正在采集：<Bundle ID>”。

**远端声音也出现在“我”的发言里？**
使用扬声器外放时远端声音会串入麦克风。建议戴耳机，或在 设置 › 采集 中开启回声消除；识别时也会自动丢弃判定为回声的段。

**会议提示一闪就没了？**
提示 5 秒无操作会自动关闭（本次不录）。来不及点按钮时直接按 ⌥⌘R（或在设置中自定义的“开始 / 停止”快捷键）即可确认开始；错过了也可以随时从菜单栏手动开始录音。

**会议检测没有弹出提示？**
检测依据的是会议软件进程是否在采集麦克风，需要该软件在 设置 › 采集 的会议软件列表中且已启用（会按 Bundle ID 前缀匹配子进程）。入会后静音、但会议软件仍保持麦克风采集时不受影响；若某个版本静音时完全释放麦克风，则在入会且开麦后才会提示。

**长会议识别时进度很慢？**
会后处理原本的两大头是说话人分离和语音识别。开启 设置 › 识别 › 录音时识别（默认开启）后，两者都在录音期间按语音段完成，停止后只剩补尾段、聚类和标点等后处理。菜单中显示的是当前阶段内的百分比（括号内为总进度），会持续前进；处理期间可以照常开始新的录音。

**说话人分得太细 / 太粗？**
开始录音时填写预计人数最稳定；或在 设置 › 识别 › 高级 中调整聚类阈值（越小分得越细）。人数未知时，分离后还会自动合并声纹相近的说话人、把发言极短的碎片说话人并入最相近者，与人物库中同一人匹配的多个说话人也会合并（可调“相似说话人合并”阈值）。

**自动识别认错人 / 认不出？**
在预览中改正即可，人物库会撤销错误样本、加入正确样本。整体偏严或偏松时调整声纹匹配阈值。

**识别失败怎么办？**
原始音频会保留，菜单中该会议显示 ⚠️，打开后点击“重新识别”；失败原因记录在 `meta.json` 的 `error` 字段。

---

## 致谢

- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)（Apache-2.0）及其提供的预训练模型
- FunASR Paraformer、pyannote.audio、3D-Speaker、Silero VAD 等模型作者

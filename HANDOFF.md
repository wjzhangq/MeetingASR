# MeetingASR 段流水线优化 - 交接文档

**交接时间**: 2026-10-18  
**分支**: `claude/segment-stream-pipeline`  
**最新提交**: `24874e6` - 删除旧识别模式，修复 VAD 配置接通

---

## 已完成的工作

### 1. 段流水线实现（提交 `29f1609`）

**新增模块**（8 个文件，~1300 行）：
- `SegmentPipeline.swift` - VAD 驱动的并行 ASR + 声纹提取
- `SphericalKMeans.swift` - 球面 K-Means 聚类算法
- `SegmentClusterer.swift` - 段级声纹聚类
- `SegmentAssigner.swift` - 最终说话人分配（含混合段处理、短段归属）
- `SegmentMerger.swift` - 簇合并与小簇吸收
- `MixedSegmentDetector.swift` - 多人混说检测
- `ShortSegmentAssigner.swift` - 孤立短段归属
- `SegmentConfig.swift` - 配置数据结构

**流程**:
```
音频 → VAD 切段 → [ASR worker ∥ 声纹 worker] → K-Means 聚类 
     → 迭代合并 → 小簇吸收 → 混合段标签平滑 → 短段归属 → 输出
```

**性能特点**:
- ASR 和声纹提取真正并行（两个 DispatchQueue）
- 2 分钟音频 RTF 0.156（验证通过）

### 2. CLI 增强（提交 `7584495`）

**新增参数**:
```bash
--vad-min-silence X    # VAD 最小静音（秒，默认 0.4）
--vad-max-speech X     # VAD 最大段长（秒，默认 12）
--merge-similarity X   # 簇合并阈值（默认 0.38）
--min-cluster-sec X    # 小簇合并下限（秒，默认 3.0）
--short-assign-sim X   # 短段归属阈值（默认 0.25）
--mixed-valley X       # 混合段检测低谷（默认 0.3）
--smooth-run-sec X     # 混合段标签平滑长度（秒，默认 1.5）
```

**新增子命令**:
```bash
meetingasr-cli sweep <会议列表文件>  # 参数网格搜索
```

### 3. 代码清理（提交 `24874e6`）

**删除的旧代码**（-648 行）:
- `RecognitionMode.asrFirst` / `.segment` 枚举值
- `MeetingProcessor` 旧流程主体（241 行）
- `AsrChunker`、`SpeakerAssigner`、`OverlapDeduplicator`、`TimedToken`（237 行）
- `TranscriptAssemblyTests.swift` 整个文件
- CLI `--mode` 参数解析

**结果**: `RecognitionMode` 现在只有一个 case（`segmentStream`），旧路径已物理删除。

**修复的 bug**:
- ✅ VAD 配置硬编码问题：`SherpaVAD.detect` 忽略 `SegmentVADConfig`，现在正确接通
- ✅ CLI 参数顺序：`--vad-*` 在引擎创建前应用
- ✅ 编译警告：`SphericalKMeans` 误用 `var`、`SegmentPipeline` 未使用的闭包捕获

---

## 已解决的问题

### ✅ 关键问题：FireRedASR-CTC 长音频崩溃（已修复）

**提交**: `4edd17c` - 2026-10-18  
**详细报告**: `docs/fix-firered-crash.md`

**原始症状**:
- 62 分钟音频处理到 334 秒时崩溃（退出码 134 = SIGABRT）
- 错误：ONNX Runtime 维度广播失败
  ```
  Attempting to broadcast an axis by a dimension other than 1. 206 by 5411
  at /encoder/layer_stack.0/mhsa/Add_4
  ```

**根本原因**:
VAD 实际产生的某些段超过 60 秒（最长达 216 秒），触发 FireRedASR-CTC 模型在 ONNX Runtime 层的维度广播错误。

**修复方案**:
实施 60 秒段长限制：
- 在 ASR 入队前检测段长，超过 60s 自动切分为多个子段
- 子段独立识别后自动合并回原段
- 声纹处理仍使用完整段（无需切分）
- 添加日志记录切分操作和超长输入警告

**验证结果**:
- ✅ 62 分钟音频完整处理成功（RTF 0.211，788.9s）
- ✅ 10+ 个长段（最长 216s）正确切分和合并
- ✅ 无 ONNX Runtime 错误，无崩溃
- ✅ 输出：316 段，2 位说话人，文本连贯

---

## 未解决的问题

### 🟡 次要问题

1. **测试无法在本机运行**  
   环境：macOS CommandLineTools，缺 XCTest  
   影响：`PipelineTests` 只验证了编译，未实际执行

2. **Paraformer 未充分测试**  
   已切换配置但未完整运行（被手动停止）

3. **sweep 子命令的 VAD 参数扫描**  
   当前 sweep 只扫 clustering 参数，VAD 参数（如 `vadMinSilence`）在网格点间共享一个 engine，无法每点独立配置

---

## 下一步建议

### 优先级 1：性能验证与对比测试

**待验证**:
- [ ] Paraformer vs FireRedASR 性能对比（准确率、速度、内存）
- [ ] 双轨会议测试（mic + system 并行）
- [ ] 内存占用与 CPU 利用率曲线
- [ ] 子段边界处 token 时间戳连续性检查

**建议**: 使用不同音频样本（单人、多人、高重叠）全面验证段切分方案的鲁棒性。

---

### 优先级 2：录音端改造（阶段 B）

**需求**（来自用户）:
1. 录音默认 16kHz（跳过后续重采样，减少预处理耗时）
2. 录音期间按 VAD 边界切分文件，每段 ≤5 分钟

**影响范围**:
- `Sources/MeetingASRApp/Capture/RecordingSession.swift`
- `Sources/MeetingASRApp/Capture/AlignedTrackWriter.swift`
- `Sources/MeetingASRCore/Models/MeetingMeta.swift` - `TrackInfo` schema 变更（单文件 → 多文件）
- `Sources/MeetingASRCore/Pipeline/MeetingProcessor.swift` - `prepareTracks` 需要读取并拼接多段
- `Sources/MeetingASRApp/Live/LiveDiarizer.swift` - 实时预览需要处理多文件增长

**挑战**:
- `MeetingASRApp` 目标无法在 CommandLineTools 环境编译（缺 SwiftUIMacros 插件）
- 代码可以写，但无法验证编译和运行

**建议**: 在 Xcode 环境中进行，或等项目迁移到新构建系统。

---

### 优先级 3：性能验证与文档

**待验证**:
- [ ] 62 分钟音频完整处理（修复崩溃后）
- [ ] 双轨会议测试（mic + system 并行）
- [ ] Paraformer vs FireRedASR 性能对比
- [ ] 内存占用与 CPU 利用率曲线

**文档更新**:
- [ ] `docs/segment-stream-pipeline.md` - 添加故障排查章节
- [ ] `README.md` - 更新默认模式说明
- [ ] `CHANGELOG.md` - 记录 breaking changes（删除旧模式）

---

## 技术债务

1. **sweep 命令的 VAD 参数扫描**  
   当前只能扫 clustering 参数，VAD 参数需要每个网格点重建 engine（代价高）。  
   方案：让 `SherpaVAD.detect` 接受可选的配置覆盖参数。

2. **测试覆盖率**  
   新增的 8 个模块（`SphericalKMeans`、`SegmentClusterer` 等）没有单元测试。  
   建议：为核心算法添加测试（K-Means、混合段检测、短段归属）。

3. **错误处理**  
   ONNX Runtime 崩溃时没有优雅降级，整个会议识别失败。  
   方案：捕获单段识别失败，标记为 `[识别失败]` 继续处理其他段。

4. **日志可观测性**  
   无法知道哪个段触发崩溃，缺少每段的输入长度日志。  
   方案：在 ASR worker 内打印 `段 #X: 音频 Y 秒，Z 帧` 日志。

---

## 环境与依赖

**构建**:
```bash
swift build -c release --target meetingasr-cli
```

**依赖**:
- sherpa-onnx 1.13.8
- 模型目录: `$HOME/Library/Application Support/MeetingASR/models`
- 获取模型: `scripts/fetch-models.sh`

**配置文件**:
- 全局设置: `$HOME/Library/Application Support/MeetingASR/settings.json`
- 会议数据: `$HOME/Documents/MeetingASR/meetings/`

**当前 settings.json 状态**:
```json
{
  "recognition": {
    "asrModel": "paraformer",          // 已切换（避免 FireRedASR 崩溃）
    "inferenceProvider": "cpu",         // 已切换（避免 CoreML 内存泄漏）
    "segmentVAD": {
      "threshold": 0.5,
      "minSilenceDuration": 0.4,
      "minSpeechDuration": 0.25,
      "maxSpeechDuration": 12,          // 已修复（之前硬编码 30）
      "padBefore": 0.15,
      "padAfter": 0.1
    }
  }
}
```

---

## 关键代码位置

**段流水线入口**:
- `Sources/MeetingASRCore/Pipeline/MeetingProcessor.swift:119` - `runSegmentStream`
- `Sources/MeetingASRCore/Pipeline/SegmentPipeline.swift:23` - `process` 方法

**VAD 配置传递链**:
1. CLI 参数解析: `Sources/meetingasr-cli/main.swift:79-88`
2. 引擎创建: `Sources/meetingasr-cli/main.swift:110` 传入 `vadConfig`
3. 工厂方法: `Sources/MeetingASREngine/Engine.swift:235` 接受并传递
4. VAD 初始化: `Sources/MeetingASREngine/Engine.swift:182-186`
5. 实际使用: `Sources/MeetingASREngine/Engine.swift:196-201` 在 `detect` 方法内

**崩溃位置**（推测）:
- `Sources/MeetingASRCore/Pipeline/SegmentPipeline.swift:85-95` ASR worker
- 某个段的音频切片超过模型安全长度触发 ONNX Runtime 错误

---

## 快速上手

**验证当前状态**:
```bash
cd /Users/wj/Downloads/work/MeetingASR
swift build -c release --target meetingasr-cli

# 2 分钟切片测试（已验证通过）
export MEETINGASR_MODELS="$HOME/Library/Application Support/MeetingASR/models"
.build/release/meetingasr-cli recognize \
  "/Users/wj/Documents/MeetingASR/meetings/2026-10-16_135951/.raw/system.wav" \
  --from 0 --to 120
```

**重现崩溃**:
```bash
# 使用 FireRedASR-CTC（会崩溃）
.build/release/meetingasr-cli recognize \
  "/Users/wj/Documents/MeetingASR/meetings/2026-10-16_135951/.raw/system.wav" \
  --asr-model firered-ctc
```

**实施方案 A（60 秒限制）后测试**:
1. 修改 `SegmentPipeline.swift` 添加段切分逻辑
2. 重新编译
3. 运行完整 62 分钟音频
4. 检查日志中是否有 ">60s 段被切分" 的记录
5. 验证不再崩溃

---

## 联系信息

**分支**: `claude/segment-stream-pipeline`  
**基础分支**: `main`（假设，未在输出中显示）  
**提交历史**:
- `29f1609` - 实现段流水线（2024-10-17）
- `7584495` - CLI 参数 + sweep（2024-10-17）
- `24874e6` - 删除旧模式 + 修复配置（2024-10-18）

**关键文件**（新增或大幅修改）:
```
Sources/MeetingASRCore/Pipeline/
  ├── SegmentPipeline.swift          (新增 270 行)
  └── MeetingProcessor.swift         (净删 122 行，简化)

Sources/MeetingASRCore/People/
  ├── SphericalKMeans.swift          (新增 218 行)
  ├── SegmentClusterer.swift         (新增 176 行)
  ├── SegmentAssigner.swift          (新增 247 行)
  ├── SegmentMerger.swift            (新增 91 行)
  ├── MixedSegmentDetector.swift     (新增 92 行)
  └── ShortSegmentAssigner.swift     (新增 89 行)

Sources/MeetingASRCore/Models/
  └── SegmentConfig.swift            (新增 124 行)

Sources/MeetingASREngine/
  └── Engine.swift                   (VAD 配置接通)

Tests/MeetingASRCoreTests/
  └── TranscriptAssemblyTests.swift  (删除 167 行)
```

---

## 总结

**成果**:
- ✅ 新段流水线已实现并通过短音频测试
- ✅ 旧识别模式彻底删除，代码简化 648 行
- ✅ VAD 配置 bug 修复，CLI 参数真正生效
- ✅ **FireRedASR-CTC 长音频崩溃已修复（60s 段长限制方案）**
- ✅ **62 分钟音频完整处理验证通过（RTF 0.211）**

**阻塞点**:
- 🟡 录音端改造需要 Xcode 环境（优先级降低）

**下一步**:
1. 性能验证与对比测试（Paraformer vs FireRedASR）
2. 双轨会议测试
3. 录音端改造（在 Xcode 中进行）

**预期时间线**:
- 性能对比测试: 2-3 小时
- 双轨会议验证: 1 小时
- 录音端改造: 4-6 小时（schema 变更波及面大）

---

**修复完成！** 🎉

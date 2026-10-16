import Foundation
import MeetingASRCore
import MeetingASREngine

/// 使用快速说话人分离的示例代码
func exampleUsage() throws {
    // 1. 创建模型路径
    let modelPaths = ModelPaths(root: URL(fileURLWithPath: "/path/to/models"))

    // 2. 使用快速分离策略创建引擎
    let engines = try SherpaEngineFactory.make(
        paths: modelPaths,
        numThreads: 4,
        diarizationStrategy: .fast  // 关键：选择快速策略
    )

    // 3. 读取音频文件
    let audioURL = URL(fileURLWithPath: "/path/to/audio.wav")
    // ... 读取音频数据到 samples: [Float]

    // 4. 执行说话人分离
    let options = DiarizationOptions(
        numSpeakers: nil,           // nil = 自动确定人数
        threshold: 0.5,             // 聚类阈值
        minDurationOn: 0.3,         // VAD 最小语音段
        minDurationOff: 0.5         // VAD 最小静音段
    )

    let spans = engines.diarizer.diarize(samples, options: options) { progress in
        print("分离进度: \(Int(progress * 100))%")
        return true  // 返回 false 可取消
    }

    // 5. 处理结果
    for span in spans {
        print("\(span.speaker): \(span.start)s - \(span.end)s")
    }
}

/// 自定义配置示例
func exampleCustomConfig() throws {
    let modelPaths = ModelPaths(root: URL(fileURLWithPath: "/path/to/models"))

    // 创建 VAD 和声纹提取器
    let vad = try SherpaVAD(paths: modelPaths)
    let embedder = try SherpaEmbedder(paths: modelPaths, numThreads: 4)

    // 自定义快速分离配置
    var config = FastDiarizationConfig()
    config.windowSec = 2.0           // 窗口 2 秒（更稳定，精度更低）
    config.stepSec = 1.0             // 步长 1 秒（向量更少）
    config.coarseThreshold = 0.70    // 粗分阈值更高（簇更多）
    config.fineThreshold = 0.75      // 细化阈值更高（最终簇更多）
    config.minSpeakerDuration = 3.0  // 3秒以下视为碎簇

    // 创建自定义分离器
    let diarizer = SherpaFastDiarizer(
        vad: vad,
        embedder: embedder,
        config: config
    )

    // 使用自定义分离器
    let options = DiarizationOptions(threshold: 0.5)
    // let spans = diarizer.diarize(samples, options: options) { _ in true }
}

/// 与人物库配合使用
func exampleWithPeopleDatabase() throws {
    let modelPaths = ModelPaths(root: URL(fileURLWithPath: "/path/to/models"))

    // 使用快速策略
    let engines = try SherpaEngineFactory.make(
        paths: modelPaths,
        diarizationStrategy: .fast
    )

    // 加载人物库
    let peopleDB = try loadPeopleDatabase()  // 自定义加载函数

    // 执行分离
    let options = DiarizationOptions()
    // let spans = engines.diarizer.diarize(samples, options: options) { _ in true }

    // 在 FastDiarizer.diarize() 内部会自动：
    // 1. 先与人物库匹配
    // 2. 只对未识别窗口聚类
    // 3. 结果中已识别的窗口直接带人物 ID
}

/// 性能对比测试
func performanceComparison() throws {
    let modelPaths = ModelPaths(root: URL(fileURLWithPath: "/path/to/models"))

    // pyannote 策略
    let pyannoteEngines = try SherpaEngineFactory.make(
        paths: modelPaths,
        diarizationStrategy: .pyannote
    )

    // 快速策略
    let fastEngines = try SherpaEngineFactory.make(
        paths: modelPaths,
        diarizationStrategy: .fast
    )

    let options = DiarizationOptions()
    // let samples = ... // 1 小时音频

    // 测试 pyannote
    let start1 = Date()
    // _ = pyannoteEngines.diarizer.diarize(samples, options: options) { _ in true }
    let duration1 = Date().timeIntervalSince(start1)
    print("pyannote 耗时: \(duration1)s")

    // 测试快速策略
    let start2 = Date()
    // _ = fastEngines.diarizer.diarize(samples, options: options) { _ in true }
    let duration2 = Date().timeIntervalSince(start2)
    print("快速策略耗时: \(duration2)s")
    print("加速比: \(duration1 / duration2)x")
}

func loadPeopleDatabase() throws -> PeopleDatabase {
    // 实际实现：从文件加载人物库
    return PeopleDatabase(people: [])
}

import Foundation
import MeetingASRCore

/// 快速说话人分离适配器：实现 SpeakerDiarizer 协议，使用 VAD + 固定窗口 + 两阶段聚类。
/// 相比 SherpaDiarizer（pyannote 切分），这个实现：
/// - 用 VAD 找语音段，避免 pyannote 的滑窗推理
/// - 在语音段内按固定窗口提取声纹（1.5s 窗口，0.75s 步长），向量数量可控
/// - 粗分时窗口数量降低 80%+，聚类几乎瞬间完成
/// - 代价是失去重叠语音检测，说话人切换点精度降至 0.5~1 秒
public final class SherpaFastDiarizer: SpeakerDiarizer {
    private let vad: VoiceActivityDetector
    private let embedder: SpeakerEmbedder
    private let config: FastDiarizationConfig

    /// 可选：人物库。非空时先与库中声纹匹配，只对未识别窗口聚类
    public var people: [Person] = []
    /// 人物匹配阈值
    public var matchThreshold: Double = 0.6
    /// 人物匹配的聚合方式
    public var matchAggregation: SampleAggregation = .max

    public init(vad: VoiceActivityDetector, embedder: SpeakerEmbedder,
                config: FastDiarizationConfig = FastDiarizationConfig()) {
        self.vad = vad
        self.embedder = embedder
        self.config = config
    }

    public func diarize(_ samples: [Float], options: DiarizationOptions,
                       progress: @escaping (Double) -> Bool) -> [RawSpan] {
        guard samples.count > 16_000 / 2 else { return [] }

        let sampleRate = 16_000
        let totalDuration = Double(samples.count) / Double(sampleRate)

        // 1. VAD 检测语音区间（约占 10% 时间）
        var vadProgress = 0.0
        let speechRanges = vad.detect(samples) { p in
            vadProgress = p * 0.1
            _ = progress(vadProgress)
        }

        guard !speechRanges.isEmpty else { return [] }

        // 2. 在语音段内按固定窗口提取声纹（约占 80% 时间）
        let diarizer = FastDiarizer(config: config)
        var windowCount = 0
        var processedWindows = 0

        // 预估窗口数量
        for range in speechRanges {
            let duration = range.upperBound - range.lowerBound
            windowCount += Int(ceil((duration - config.windowSec) / config.stepSec)) + 1
        }
        windowCount = max(1, windowCount)

        let windows = diarizer.extractWindows(
            speechRanges: speechRanges,
            totalDuration: totalDuration
        ) { start, end in
            defer {
                processedWindows += 1
                let embProgress = 0.1 + Double(processedWindows) / Double(windowCount) * 0.8
                _ = progress(min(0.9, embProgress))
            }

            let startSample = Int(start * Double(sampleRate))
            let endSample = min(samples.count, Int(end * Double(sampleRate)))
            guard endSample > startSample else { return nil }

            return embedder.embed(Array(samples[startSample..<endSample]))
        }

        guard !windows.isEmpty else { return [] }

        // 3-6. 聚类与后处理（约占 10% 时间）
        let finalWindows = clusterWindows(windows, numSpeakers: options.numSpeakers)
        _ = progress(1.0)

        return diarizer.windowsToSpans(finalWindows)
    }

    private func clusterWindows(_ windows: [FastDiarizer.Window], numSpeakers: Int?) -> [FastDiarizer.Window] {
        let diarizer = FastDiarizer(config: config)

        // 人物库优先匹配：命中的窗口不参与聚类
        var result = windows
        if !people.isEmpty {
            result = diarizer.matchKnownSpeakers(result, people: people,
                                                 threshold: matchThreshold,
                                                 aggregation: matchAggregation)
        }

        // 粗分
        result = diarizer.coarseClustering(result)

        // 细化
        result = diarizer.fineClustering(result, numSpeakers: numSpeakers)

        // 合并碎簇
        result = diarizer.mergeTinyClusters(result)

        return result
    }
}

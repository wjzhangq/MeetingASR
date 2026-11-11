import Foundation

/// ASR 结果。
public struct RecognitionResult: Sendable {
    public var text: String
    /// 字级时间戳（相对输入音频起点，秒）；模型不输出时为空
    public var tokens: [TranscriptToken]

    public init(text: String, tokens: [TranscriptToken] = []) {
        self.text = text
        self.tokens = tokens
    }
}

extension RecognitionResult {
    /// 有文本却没有字级时间戳时（模型不支持或解码异常），把文本按字/英文词均匀铺在 [start, end] 上，
    /// 保证“先识别再分配说话人”不丢字（时间精度降为块级）。
    public func tokensOrEstimated(start: Double, end: Double) -> [TranscriptToken] {
        guard tokens.isEmpty else { return tokens }
        var units: [String] = []
        var word = ""
        for c in text {
            if c.isASCII && (c.isLetter || c.isNumber || c == "'") {
                word.append(c)
                continue
            }
            if !word.isEmpty { units.append(word); word = "" }
            if !c.isWhitespace && !c.isPunctuation { units.append(String(c)) }
        }
        if !word.isEmpty { units.append(word) }
        guard !units.isEmpty else { return [] }
        let step = max(0, end - start) / Double(units.count)
        return units.enumerated().map { TranscriptToken(t: $1, start: start + Double($0) * step) }
    }
}

/// 离线语音识别（Paraformer-zh / SenseVoice）。输入 16kHz 单声道。
public protocol SpeechRecognizer: AnyObject {
    var modelName: String { get }
    /// 是否输出字级时间戳（“先识别再分配说话人”需要）
    var providesTimestamps: Bool { get }
    func recognize(_ samples: [Float]) -> RecognitionResult
}

extension SpeechRecognizer {
    public var providesTimestamps: Bool { true }
}

/// 标点恢复。
public protocol Punctuator: AnyObject {
    func punctuate(_ text: String) -> String
}

/// 声纹提取（CAM++）。
public protocol SpeakerEmbedder: AnyObject {
    var modelName: String { get }
    /// 失败（音频过短等）返回 nil
    func embed(_ samples: [Float]) -> [Float]?
}

/// 语音活动检测（Silero VAD）。
public protocol VoiceActivityDetector: AnyObject {
    /// - Returns: 语音区间（秒，相对输入起点）
    func detect(_ samples: [Float]) -> [ClosedRange<Double>]
    /// 带进度（0...1）的检测，长音频用
    func detect(_ samples: [Float], progress: (Double) -> Void) -> [ClosedRange<Double>]
    /// 使用本次任务的 VAD 参数，而不是引擎创建时的快照。
    func detect(_ samples: [Float], config: SegmentVADConfig, progress: (Double) -> Void) -> [ClosedRange<Double>]
}

extension VoiceActivityDetector {
    public func detect(_ samples: [Float], progress: (Double) -> Void) -> [ClosedRange<Double>] {
        let r = detect(samples)
        progress(1)
        return r
    }

    public func detect(_ samples: [Float], config: SegmentVADConfig, progress: (Double) -> Void) -> [ClosedRange<Double>] {
        detect(samples, progress: progress)
    }

    public func detect(_ samples: [Float], config: SegmentVADConfig) -> [ClosedRange<Double>] {
        detect(samples, config: config) { _ in }
    }
}

/// 一套推理引擎。模型加载较慢，由应用创建一次并在任务间复用（任务串行执行）。
public struct EngineSet {
    public var recognizer: SpeechRecognizer
    public var punctuator: Punctuator?
    public var embedder: SpeakerEmbedder
    public var vad: VoiceActivityDetector
    public var models: ModelVersions

    public init(recognizer: SpeechRecognizer, punctuator: Punctuator?, embedder: SpeakerEmbedder, vad: VoiceActivityDetector, models: ModelVersions = .bundled) {
        self.recognizer = recognizer
        self.punctuator = punctuator
        self.embedder = embedder
        self.vad = vad
        self.models = models
    }
}

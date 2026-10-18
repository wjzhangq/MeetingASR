import Foundation

/// 采集源（FR-A7）。
public enum CaptureSource: String, Codable, Sendable, CaseIterable {
    case micOnly
    case appOnly
    case both

    public var includesMic: Bool { self != .appOnly }
    public var includesApp: Bool { self != .micOnly }

    public var displayName: String {
        switch self {
        case .micOnly: return "仅麦克风"
        case .appOnly: return "仅会议软件"
        case .both: return "两者"
        }
    }
}

/// 需要采集输出音频的会议软件（Bundle ID 做成配置项，FR-A9）。
public struct CaptureApp: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    /// 匹配的 Bundle ID（含前缀匹配，用于覆盖 helper 子进程）
    public var bundleIDs: [String]
    public var enabled: Bool

    public init(name: String, bundleIDs: [String], enabled: Bool = true) {
        self.name = name
        self.bundleIDs = bundleIDs
        self.enabled = enabled
    }

    public static let defaults: [CaptureApp] = [
        CaptureApp(name: "腾讯会议", bundleIDs: ["com.tencent.meeting"]),
        CaptureApp(name: "Microsoft Teams", bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"]),
        CaptureApp(name: "飞书", bundleIDs: ["com.bytedance.macos.feishu", "com.electron.lark"], enabled: false),
        CaptureApp(name: "Zoom", bundleIDs: ["us.zoom.xos"], enabled: false),
    ]

    /// 进程 Bundle ID 是否属于本应用（包含 `com.microsoft.teams2.helper` 之类子进程）。
    public func matches(bundleID: String) -> Bool {
        bundleIDs.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }
}

public struct HotkeySetting: Codable, Sendable, Hashable {
    /// Carbon 虚拟键码
    public var keyCode: UInt32
    /// Carbon 修饰键（cmdKey/optionKey/controlKey/shiftKey 组合）
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// 识别方式。
public enum RecognitionMode: String, Codable, Sendable, CaseIterable {
    /// VAD 切段 + 并行 ASR/声纹 + 球面 K-Means 聚类
    case segmentStream

    public var displayName: String {
        "段流水线（VAD 驱动）"
    }
}

/// 推理后端（Execution Provider）。
public enum InferenceProvider: String, Codable, Sendable, CaseIterable {
    /// CPU（默认，变长音频上更稳）
    case cpu
    /// CoreML / Apple Neural Engine（Apple Silicon 硬件加速）
    case coreml

    public var displayName: String {
        switch self {
        case .cpu: return "CPU（默认）"
        case .coreml: return "神经引擎"
        }
    }

    /// 传给 sherpa-onnx 的 provider 字符串
    public var providerString: String { rawValue }
}

/// 语音识别模型。
public enum AsrModelKind: String, Codable, Sendable, CaseIterable {
    /// Paraformer-zh（随 App 下载，默认）
    case paraformer
    /// FireRedASR2-CTC 中英（输出字级时间戳）
    case fireRedAsrCtc
    /// FireRedASR-AED large 中英（准确率更高、更慢，不输出字级时间戳）
    case fireRedAsrAed
    /// SenseVoice 中英日韩粤（输出字级时间戳，ITN）
    case senseVoice

    public var displayName: String {
        switch self {
        case .paraformer: return "Paraformer-zh（默认）"
        case .fireRedAsrCtc: return "FireRedASR2-CTC 中英"
        case .fireRedAsrAed: return "FireRedASR-AED Large 中英"
        case .senseVoice: return "SenseVoice 中英日韩粤"
        }
    }

    /// 模型目录名（位于模型根目录下）
    public var directory: String {
        switch self {
        case .paraformer: return "asr"
        case .fireRedAsrCtc: return "asr-firered-ctc"
        case .fireRedAsrAed: return "asr-firered-aed"
        case .senseVoice: return "asr-sensevoice"
        }
    }

    /// 模型目录中需要的文件
    public var requiredFiles: [String] {
        switch self {
        case .paraformer, .fireRedAsrCtc: return ["model.int8.onnx", "tokens.txt"]
        case .fireRedAsrAed: return ["encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt"]
        case .senseVoice: return ["model.onnx", "tokens.txt"]
        }
    }

    /// sherpa-onnx 发布的模型包（asr-models 发布页），解压后的顶层目录同名
    public var releasePackage: String {
        switch self {
        case .paraformer: return "sherpa-onnx-paraformer-zh-2023-09-14"
        case .fireRedAsrCtc: return "sherpa-onnx-fire-red-asr2-ctc-zh_en-int8-2026-02-25"
        case .fireRedAsrAed: return "sherpa-onnx-fire-red-asr-large-zh_en-2025-02-16"
        case .senseVoice: return "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
        }
    }

    public var releaseURL: URL {
        URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(releasePackage).tar.bz2")!
    }

    /// 写入结果的模型标识
    public var modelName: String {
        switch self {
        case .paraformer: return "sherpa-onnx-paraformer-zh"
        case .fireRedAsrCtc: return "sherpa-onnx-fire-red-asr2-ctc-zh_en"
        case .fireRedAsrAed: return "sherpa-onnx-fire-red-asr-large-zh_en"
        case .senseVoice: return "sherpa-onnx-sense-voice-zh-en-ja-ko-yue"
        }
    }

    /// 是否输出字级时间戳
    public var providesTimestamps: Bool { self != .fireRedAsrAed }

    /// 单次送入 ASR 的音频上限（秒）。FireRedASR-CTC 超过约 60 秒会在 ONNX 里崩溃。
    public var maxASRSegmentSec: Double { 60 }

    /// 命令行与脚本中的名称
    public var cliName: String {
        switch self {
        case .paraformer: return "paraformer"
        case .fireRedAsrCtc: return "firered-ctc"
        case .fireRedAsrAed: return "firered-aed"
        case .senseVoice: return "sensevoice"
        }
    }

    public init?(cliName: String) {
        guard let k = Self.allCases.first(where: { $0.cliName == cliName }) else { return nil }
        self = k
    }
}

/// 识别相关参数（FR-C3 高级选项）。
public struct RecognitionSettings: Codable, Sendable, Equatable {
    /// 默认说话人数，nil 为自动
    public var defaultSpeakerCount: Int?
    /// 识别方式；模型不输出字级时间戳时自动退回按段识别
    public var recognitionMode: RecognitionMode = .segmentStream
    /// VAD 分段参数（仅 segmentStream 模式使用）
    public var segmentVAD = SegmentVADConfig()
    /// 段级聚类参数（仅 segmentStream 模式使用）
    public var segmentClustering = SegmentClusteringConfig()
    /// 语音识别模型；所选模型未安装时使用 Paraformer
    public var asrModel: AsrModelKind = .paraformer
    /// 推理后端（CPU / 神经引擎）。新安装默认 CPU。
    public var inferenceProvider: InferenceProvider = .cpu
    /// 聚类阈值（人数未知时使用，越小分得越细）
    public var clusterThreshold: Float = 0.5
    public var minDurationOn: Float = 0.3
    public var minDurationOff: Float = 0.5
    /// 声纹匹配阈值
    public var matchThreshold: Double = 0.6
    /// 分离后合并相似簇的声纹相似度阈值（人数未知时使用，0 关闭）
    public var clusterMergeSimilarity: Double = 0.65
    /// 发言总时长短于该值（秒）的说话人并入最相近的说话人（0 关闭）
    public var minSpeakerSec: Double = 2
    /// 每个说话人保存的特征片段数
    public var clipsPerSpeaker: Int = 3
    public var clipMinSec: Double = 3
    public var clipMaxSec: Double = 8
    /// 每个人物的样本上限
    public var maxSamplesPerPerson: Int = 20
    /// 推理线程数（默认按 CPU 核数，2~8）
    public var numThreads: Int = RecognitionSettings.defaultThreads

    public static var defaultThreads: Int { min(8, max(2, ProcessInfo.processInfo.activeProcessorCount)) }

    public init() {}

    public var clusterMerge: ClusterMergeConfig {
        var c = ClusterMergeConfig()
        c.similarity = clusterMergeSimilarity
        c.minSpeakerSec = minSpeakerSec
        return c
    }
}

/// 设置（保存在 ~/Library/Application Support/MeetingASR/settings.json）。
public struct AppSettings: Codable, Sendable, Equatable {
    public var captureSource: CaptureSource = .both
    /// 麦克风输入设备 UID，nil 为系统默认
    public var micDeviceUID: String?
    /// 麦克风系统回声消除（FR-A8）
    public var micVoiceProcessing: Bool = false
    public var captureApps: [CaptureApp] = CaptureApp.defaults
    public var recognition = RecognitionSettings()
    public var hotkeyStartStop: HotkeySetting? = HotkeySetting(keyCode: 15, modifiers: 0x0800 | 0x0100) // ⌥⌘R
    public var hotkeyPauseResume: HotkeySetting? = HotkeySetting(keyCode: 35, modifiers: 0x0800 | 0x0100) // ⌥⌘P
    public var launchAtLogin: Bool = false
    /// 已完成首次启动引导
    public var onboardingDone: Bool = false
    /// 会议检测：会议软件开始通话时提示是否录音
    public var meetingDetection: Bool = true
    /// 会议结束（会议软件停止通话）时自动停止录音并识别
    public var autoStopOnMeetingEnd: Bool = true
    /// 录音期间按 VAD 段提前做识别和声纹。不再跑 pyannote。
    public var liveDiarization: Bool = true

    public init() {}

    public static var fileURL: URL { AppSupport.dir.appendingPathComponent("settings.json") }

    public static func load(from url: URL = fileURL) -> AppSettings {
        (try? JSONIO.read(AppSettings.self, from: url)) ?? AppSettings()
    }

    public func save(to url: URL = fileURL) throws {
        try JSONIO.write(self, to: url)
    }

    /// 已启用的全部 Bundle ID。
    public var enabledBundleIDs: [String] {
        captureApps.filter(\.enabled).flatMap(\.bundleIDs)
    }
}

extension AppSettings {
    // 新增字段时保持向后兼容：缺失字段取默认值。
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        captureSource = try c.decodeIfPresent(CaptureSource.self, forKey: .captureSource) ?? captureSource
        micDeviceUID = try c.decodeIfPresent(String.self, forKey: .micDeviceUID)
        micVoiceProcessing = try c.decodeIfPresent(Bool.self, forKey: .micVoiceProcessing) ?? micVoiceProcessing
        captureApps = try c.decodeIfPresent([CaptureApp].self, forKey: .captureApps) ?? captureApps
        recognition = try c.decodeIfPresent(RecognitionSettings.self, forKey: .recognition) ?? recognition
        hotkeyStartStop = try c.decodeIfPresent(HotkeySetting.self, forKey: .hotkeyStartStop)
        hotkeyPauseResume = try c.decodeIfPresent(HotkeySetting.self, forKey: .hotkeyPauseResume)
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        onboardingDone = try c.decodeIfPresent(Bool.self, forKey: .onboardingDone) ?? onboardingDone
        meetingDetection = try c.decodeIfPresent(Bool.self, forKey: .meetingDetection) ?? meetingDetection
        autoStopOnMeetingEnd = try c.decodeIfPresent(Bool.self, forKey: .autoStopOnMeetingEnd) ?? autoStopOnMeetingEnd
        liveDiarization = try c.decodeIfPresent(Bool.self, forKey: .liveDiarization) ?? liveDiarization
    }
}

extension RecognitionSettings {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultSpeakerCount = try c.decodeIfPresent(Int.self, forKey: .defaultSpeakerCount)
        recognitionMode = (try? c.decodeIfPresent(RecognitionMode.self, forKey: .recognitionMode)) ?? recognitionMode
        segmentVAD = try c.decodeIfPresent(SegmentVADConfig.self, forKey: .segmentVAD) ?? segmentVAD
        segmentClustering = try c.decodeIfPresent(SegmentClusteringConfig.self, forKey: .segmentClustering) ?? segmentClustering
        asrModel = (try? c.decodeIfPresent(AsrModelKind.self, forKey: .asrModel)) ?? asrModel
        inferenceProvider = (try? c.decodeIfPresent(InferenceProvider.self, forKey: .inferenceProvider)) ?? inferenceProvider
        clusterThreshold = try c.decodeIfPresent(Float.self, forKey: .clusterThreshold) ?? clusterThreshold
        minDurationOn = try c.decodeIfPresent(Float.self, forKey: .minDurationOn) ?? minDurationOn
        minDurationOff = try c.decodeIfPresent(Float.self, forKey: .minDurationOff) ?? minDurationOff
        matchThreshold = try c.decodeIfPresent(Double.self, forKey: .matchThreshold) ?? matchThreshold
        clusterMergeSimilarity = try c.decodeIfPresent(Double.self, forKey: .clusterMergeSimilarity) ?? clusterMergeSimilarity
        minSpeakerSec = try c.decodeIfPresent(Double.self, forKey: .minSpeakerSec) ?? minSpeakerSec
        clipsPerSpeaker = try c.decodeIfPresent(Int.self, forKey: .clipsPerSpeaker) ?? clipsPerSpeaker
        clipMinSec = try c.decodeIfPresent(Double.self, forKey: .clipMinSec) ?? clipMinSec
        clipMaxSec = try c.decodeIfPresent(Double.self, forKey: .clipMaxSec) ?? clipMaxSec
        maxSamplesPerPerson = try c.decodeIfPresent(Int.self, forKey: .maxSamplesPerPerson) ?? maxSamplesPerPerson
        numThreads = try c.decodeIfPresent(Int.self, forKey: .numThreads) ?? numThreads
    }
}

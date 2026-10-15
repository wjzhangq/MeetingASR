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

/// 识别相关参数（FR-C3 高级选项）。
public struct RecognitionSettings: Codable, Sendable, Equatable {
    /// 默认说话人数，nil 为自动
    public var defaultSpeakerCount: Int?
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
    }
}

extension RecognitionSettings {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultSpeakerCount = try c.decodeIfPresent(Int.self, forKey: .defaultSpeakerCount)
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

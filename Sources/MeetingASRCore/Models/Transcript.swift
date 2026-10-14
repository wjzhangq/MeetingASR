import Foundation

/// 音轨来源。
public enum TrackKind: String, Codable, Sendable, CaseIterable {
    /// Mac 麦克风
    case mic
    /// 会议软件（Process Tap）
    case system
    /// 用户选择的音频文件
    case file
}

/// 说话人姓名来源（transcript.json 中的 `source` 字段）。
public enum NameSource: String, Codable, Sendable {
    /// 声纹库自动识别
    case auto
    /// 用户标注
    case user
    /// 未命名
    case none
}

public struct TranscriptToken: Codable, Equatable, Sendable {
    public var t: String
    public var start: Double

    public init(t: String, start: Double) {
        self.t = t
        self.start = start
    }
}

public struct TranscriptSpeaker: Codable, Equatable, Sendable {
    public var id: String
    public var track: TrackKind
    public var personId: String?
    public var name: String
    public var source: NameSource

    public init(id: String, track: TrackKind, personId: String? = nil, name: String? = nil, source: NameSource = .none) {
        self.id = id
        self.track = track
        self.personId = personId
        self.name = name ?? id
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case id, track, personId = "person_id", name, source
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(track, forKey: .track)
        // person_id 未命名时显式写 null
        try c.encode(personId, forKey: .personId)
        try c.encode(name, forKey: .name)
        try c.encode(source, forKey: .source)
    }

    /// 是否已命名（自动识别或用户标注）。
    public var isNamed: Bool { source != .none }
}

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public var text: String
    public var tokens: [TranscriptToken]?

    public init(speaker: String, start: Double, end: Double, text: String, tokens: [TranscriptToken]? = nil) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.tokens = tokens
    }
}

public struct ModelVersions: Codable, Equatable, Sendable {
    public var asr: String
    public var segmentation: String
    public var embedding: String
    public var punctuation: String?
    public var vad: String?

    public init(asr: String, segmentation: String, embedding: String, punctuation: String? = nil, vad: String? = nil) {
        self.asr = asr
        self.segmentation = segmentation
        self.embedding = embedding
        self.punctuation = punctuation
        self.vad = vad
    }

    public static let bundled = ModelVersions(
        asr: "sherpa-onnx-paraformer-zh",
        segmentation: "pyannote-segmentation-3.0",
        embedding: EmbeddingModel.current,
        punctuation: "ct-transformer-zh-en-vocab272727",
        vad: "silero-vad"
    )
}

public enum EmbeddingModel {
    /// 声纹模型版本标识，写入 people.json，用于将来模型升级时重新提取。
    public static let current = "3dspeaker-campplus-zh-cn-16k"
}

/// 暂停标记：在录音时间轴（已录音频）中的位置。
public struct PauseMark: Codable, Equatable, Sendable {
    /// 暂停发生时已录音频的时长（秒），即逐字稿时间轴上的位置
    public var at: Double

    public init(at: Double) { self.at = at }
}

/// transcript.json 主数据。
public struct Transcript: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var title: String
    public var createdAt: String
    public var durationSec: Double
    public var speakers: [TranscriptSpeaker]
    public var segments: [TranscriptSegment]
    public var pauses: [PauseMark]?
    public var models: ModelVersions

    public init(
        version: Int = Transcript.currentVersion,
        title: String,
        createdAt: String,
        durationSec: Double,
        speakers: [TranscriptSpeaker],
        segments: [TranscriptSegment],
        pauses: [PauseMark]? = nil,
        models: ModelVersions = .bundled
    ) {
        self.version = version
        self.title = title
        self.createdAt = createdAt
        self.durationSec = durationSec
        self.speakers = speakers
        self.segments = segments
        self.pauses = pauses
        self.models = models
    }

    enum CodingKeys: String, CodingKey {
        case version, title, createdAt = "created_at", durationSec = "duration_sec", speakers, segments, pauses, models
    }

    public func speaker(_ id: String) -> TranscriptSpeaker? {
        speakers.first { $0.id == id }
    }

    /// 某说话人的总发言时长（秒）。
    public func speakingDuration(of id: String) -> Double {
        segments.filter { $0.speaker == id }.reduce(0) { $0 + max(0, $1.end - $1.start) }
    }

    /// 显示名：已命名用姓名，否则用标签。
    public func displayName(of id: String) -> String {
        speaker(id)?.name ?? id
    }
}

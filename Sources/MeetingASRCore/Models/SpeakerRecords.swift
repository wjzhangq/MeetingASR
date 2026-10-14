import Foundation

/// 特征片段信息。
public struct FeatureClip: Codable, Equatable, Sendable {
    /// 文件名（位于 speakers/ 下），如 `S1_01.wav`
    public var file: String
    /// 片段在会议时间轴上的起止（秒）
    public var start: Double
    public var end: Double
    /// 挑选得分（声纹相似度 × 信噪比权重）
    public var score: Double

    public init(file: String, start: Double, end: Double, score: Double) {
        self.file = file
        self.start = start
        self.end = end
        self.score = score
    }
}

/// 声纹匹配结果。
public struct SpeakerMatch: Codable, Equatable, Sendable {
    public var personId: String
    public var score: Double

    public init(personId: String, score: Double) {
        self.personId = personId
        self.score = score
    }

    enum CodingKeys: String, CodingKey { case personId = "person_id", score }
}

/// speakers.json 中单个说话人的记录。
public struct SpeakerRecord: Codable, Equatable, Sendable {
    public var id: String
    public var track: TrackKind
    /// 该说话人在本场会议中的声纹（L2 归一化）
    public var embedding: [Float]
    /// 自动匹配结果（不论是否达到阈值都记录最佳候选，便于调参）
    public var bestMatch: SpeakerMatch?
    public var clips: [FeatureClip]
    public var durationSec: Double
    /// 本说话人当前贡献给人物库的样本所属人物（用于改正时撤销，FR-N9）
    public var contributedTo: String?

    public init(id: String, track: TrackKind, embedding: [Float], bestMatch: SpeakerMatch? = nil, clips: [FeatureClip] = [], durationSec: Double = 0, contributedTo: String? = nil) {
        self.id = id
        self.track = track
        self.embedding = embedding
        self.bestMatch = bestMatch
        self.clips = clips
        self.durationSec = durationSec
        self.contributedTo = contributedTo
    }

    enum CodingKeys: String, CodingKey {
        case id, track, embedding, bestMatch = "best_match", clips, durationSec = "duration_sec", contributedTo = "contributed_to"
    }
}

public struct SpeakersFile: Codable, Equatable, Sendable {
    public var embeddingModel: String
    public var matchThreshold: Double
    public var speakers: [SpeakerRecord]

    public init(embeddingModel: String = EmbeddingModel.current, matchThreshold: Double, speakers: [SpeakerRecord]) {
        self.embeddingModel = embeddingModel
        self.matchThreshold = matchThreshold
        self.speakers = speakers
    }

    enum CodingKeys: String, CodingKey {
        case embeddingModel = "embedding_model", matchThreshold = "match_threshold", speakers
    }

    public func record(_ id: String) -> SpeakerRecord? {
        speakers.first { $0.id == id }
    }
}

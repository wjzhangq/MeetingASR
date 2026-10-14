import Foundation

/// 人物库中的一条声纹样本。
public struct PersonSample: Codable, Equatable, Sendable {
    /// 来源会议目录名
    public var meeting: String
    /// 来源会议中的说话人标签
    public var speaker: String
    public var embedding: [Float]
    /// 复制到 people/<person-id>/ 的片段文件名
    public var clips: [String]
    public var addedAt: Date
    /// 样本来源：auto（自动识别未改动）或 user（用户确认/标注）
    public var source: NameSource

    public init(meeting: String, speaker: String, embedding: [Float], clips: [String] = [], addedAt: Date = Date(), source: NameSource = .user) {
        self.meeting = meeting
        self.speaker = speaker
        self.embedding = embedding
        self.clips = clips
        self.addedAt = addedAt
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case meeting, speaker, embedding, clips, addedAt = "added_at", source
    }
}

public struct Person: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var samples: [PersonSample]

    public init(id: String, name: String, createdAt: Date = Date(), samples: [PersonSample] = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.samples = samples
    }

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt = "created_at", samples
    }
}

/// people.json
public struct PeopleDatabase: Codable, Equatable, Sendable {
    public var embeddingModel: String
    public var people: [Person]

    public init(embeddingModel: String = EmbeddingModel.current, people: [Person] = []) {
        self.embeddingModel = embeddingModel
        self.people = people
    }

    enum CodingKeys: String, CodingKey {
        case embeddingModel = "embedding_model", people
    }
}

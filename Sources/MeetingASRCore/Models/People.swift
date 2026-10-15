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
    /// 显示颜色 "#RRGGBB"，用于说话人卡片与逐字稿；nil 时按会议内顺序取默认色
    public var color: String?

    public init(id: String, name: String, createdAt: Date = Date(), samples: [PersonSample] = [], color: String? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.samples = samples
        self.color = color
    }

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt = "created_at", samples, color
    }
}

/// 人物颜色：统一为 "#RRGGBB"（大写），提供新建人物时的默认色板。
public enum PersonColor {
    /// 与界面默认色板对应的 12 种颜色
    public static let palette = [
        "#0A84FF", "#FF9F0A", "#30D158", "#BF5AF2", "#FF375F", "#40C8E0",
        "#AC8E68", "#5E5CE6", "#63E6BE", "#FF453A", "#64D2FF", "#FFD60A",
    ]

    /// 规范化为 "#RRGGBB"；格式不对返回 nil。接受 "#rgb"、"rrggbb" 等写法。
    public static func normalize(_ s: String) -> String? {
        var hex = s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + hex
    }

    /// (r, g, b)，0...1
    public static func components(_ s: String) -> (Double, Double, Double)? {
        guard let hex = normalize(s), let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    public static func hex(r: Double, g: Double, b: Double) -> String {
        func c(_ x: Double) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
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

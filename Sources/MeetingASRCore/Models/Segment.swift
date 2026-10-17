import Foundation

/// VAD 切出的一段，贯穿整条流水线的唯一调度单元。
public struct Segment: Codable, Equatable, Sendable {
    public var id: Int
    public var track: TrackKind

    // 全局时间轴（秒）；start/end 为补边后的实际裁剪范围
    public var start: Double
    public var end: Double
    /// VAD 原始边界（不含补边），用于时长判定与输出
    public var speechStart: Double
    public var speechEnd: Double

    // ASR（不含标点）
    public var text: String = ""
    public var tokens: [TranscriptToken] = []

    // 声纹
    public var embedding: [Float] = []
    public var subwindows: [SubwindowEmbedding] = []

    public var isShort = false
    public var isMixed = false
    public var isEcho = false

    public var cluster: String?
    public var speaker: String?

    public init(id: Int, track: TrackKind, start: Double, end: Double, speechStart: Double, speechEnd: Double) {
        self.id = id
        self.track = track
        self.start = start
        self.end = end
        self.speechStart = speechStart
        self.speechEnd = speechEnd
    }

    public var speechDuration: Double { speechEnd - speechStart }
    public var duration: Double { end - start }
}

public struct SubwindowEmbedding: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var embedding: [Float]
    public var cluster: String?

    public init(start: Double, end: Double, embedding: [Float], cluster: String? = nil) {
        self.start = start
        self.end = end
        self.embedding = embedding
        self.cluster = cluster
    }
}

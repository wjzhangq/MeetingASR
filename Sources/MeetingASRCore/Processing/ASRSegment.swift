import Foundation

/// 送 ASR 的分段。
public struct ASRSegment: Equatable, Sendable {
    public var speaker: String
    public var track: TrackKind
    /// 发言起止（会议时间轴）
    public var start: Double
    public var end: Double
    /// 实际裁剪音频的起止（前后补边后）
    public var cropStart: Double
    public var cropEnd: Double
    /// 与其他说话人重叠的比例（0...1）
    public var overlapRatio: Double = 0
    /// 是否判定为回声（麦克风轨串入的远端声音）
    public var isEcho: Bool = false

    public init(speaker: String, track: TrackKind, start: Double, end: Double, cropStart: Double, cropEnd: Double) {
        self.speaker = speaker
        self.track = track
        self.start = start
        self.end = end
        self.cropStart = cropStart
        self.cropEnd = cropEnd
    }

    public var duration: Double { end - start }
}

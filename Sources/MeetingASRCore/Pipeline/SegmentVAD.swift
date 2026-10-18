import Foundation

/// 流式 VAD：持续送帧，取出完整语音段。
public protocol StreamingVAD: AnyObject {
    /// 送入任意长度样本（内部按 512 帧对齐）
    func accept(_ samples: [Float])
    /// 取出一个完整语音段（相对本轨已送入音频起点的秒数），队列空时返回 nil
    func next() -> ClosedRange<Double>?
    /// 暂停/结束时冲出最后一段
    func flush()
    func reset()
}

/// VAD 分段器：环形缓冲 + 补边 + 产出 Segment。
public final class SegmentVAD {
    private let vad: StreamingVAD
    private let track: TrackKind
    private let config: SegmentVADConfig
    private let sampleRate: Int
    
    /// 已送入音频的总时长（秒）
    private var totalSec: Double = 0
    /// 下一个段的 ID
    private var nextId = 0
    
    public init(vad: StreamingVAD, track: TrackKind, config: SegmentVADConfig, sampleRate: Int = 16_000) {
        self.vad = vad
        self.track = track
        self.config = config
        self.sampleRate = sampleRate
    }
    
    /// 送入新音频。补边只改时间边界，音频在整轨缓冲里切，这里不再复制一份环形缓冲。
    public func accept(_ samples: [Float]) {
        vad.accept(samples)
        totalSec += Double(samples.count) / Double(sampleRate)
    }
    
    /// 取出下一个补边后的段。
    public func nextSegment() -> Segment? {
        guard let raw = vad.next() else { return nil }
        
        let speechStart = raw.lowerBound
        let speechEnd = raw.upperBound
        
        // 补边：前扩 padBefore、后扩 padAfter，裁到 [0, totalSec]
        let start = max(0, speechStart - config.padBefore)
        let end = min(totalSec, speechEnd + config.padAfter)
        
        let seg = Segment(
            id: nextId,
            track: track,
            start: start,
            end: end,
            speechStart: speechStart,
            speechEnd: speechEnd
        )
        nextId += 1
        
        return seg
    }
    
    /// 取出所有待处理的段。
    public func drainSegments() -> [Segment] {
        var segments: [Segment] = []
        while let seg = nextSegment() {
            segments.append(seg)
        }
        return segments
    }
    
    /// 暂停/结束时冲出最后一段。
    public func flush() {
        vad.flush()
    }
    
    public func reset() {
        vad.reset()
        totalSec = 0
        nextId = 0
    }
}

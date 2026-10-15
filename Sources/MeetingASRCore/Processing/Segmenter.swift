import Foundation

/// 分离/VAD 得到的原始说话片段。
public struct RawSpan: Equatable, Sendable {
    /// 本轨内的说话人标签（分离结果的簇编号或固定标签）
    public var speaker: String
    public var start: Double
    public var end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }

    public var duration: Double { end - start }
}

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

/// 分段后处理参数（4.4）。
public struct SegmenterConfig: Sendable {
    /// 同一说话人相邻段间隔小于该值则合并
    public var mergeGap: Double = 0.5
    /// 单段最大时长
    public var maxSegment: Double = 30
    /// 前后补边（不越过相邻段的边界）
    public var padding: Double = 0.25
    /// 短于该值的段丢弃
    public var minSegment: Double = 0.3

    public init() {}
}

/// 说话人段后处理：合并、切分、补边、丢弃，以及双轨合并排序。
public struct Segmenter: Sendable {
    public var config: SegmenterConfig

    public init(config: SegmenterConfig = SegmenterConfig()) {
        self.config = config
    }

    /// 1. 合并同一说话人间隔小于 mergeGap 的相邻段。
    public func merge(_ spans: [RawSpan]) -> [RawSpan] {
        var lastBySpeaker: [String: Int] = [:]
        var out: [RawSpan] = []
        for s in spans.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) where s.end > s.start {
            if let idx = lastBySpeaker[s.speaker], s.start - out[idx].end < config.mergeGap,
               // 中间没有插入其他说话人的段才合并，避免吞掉对话轮次
               !out[(idx + 1)...].contains(where: { $0.speaker != s.speaker && $0.start >= out[idx].end && $0.end <= s.start }) {
                out[idx].end = max(out[idx].end, s.end)
            } else {
                out.append(s)
                lastBySpeaker[s.speaker] = out.count - 1
            }
        }
        return out
    }

    /// 2. 超过 maxSegment 的段，在段内静音点切开。
    /// - Parameter silences: 给定区间返回其中的静音点（秒，全局时间），可为空
    public func split(_ spans: [RawSpan], silences: (Double, Double) -> [Double]) -> [RawSpan] {
        var out: [RawSpan] = []
        for s in spans {
            out.append(contentsOf: splitOne(s, candidates: s.duration > config.maxSegment ? silences(s.start, s.end) : []))
        }
        return out
    }

    private func splitOne(_ s: RawSpan, candidates: [Double]) -> [RawSpan] {
        guard s.duration > config.maxSegment else { return [s] }
        let minPiece = min(config.maxSegment / 3, 5)
        let usable = candidates.filter { $0 > s.start + minPiece && $0 < s.end - minPiece }
        // 在 maxSegment 之内、尽量靠后的静音点切开；没有则在 maxSegment 处硬切
        let limit = s.start + config.maxSegment
        let cut = usable.filter { $0 <= limit }.max() ?? limit
        let head = RawSpan(speaker: s.speaker, start: s.start, end: cut)
        let tail = RawSpan(speaker: s.speaker, start: cut, end: s.end)
        return [head] + splitOne(tail, candidates: usable.filter { $0 > cut })
    }

    /// 3/4. 丢弃过短段，补边，生成 ASR 分段。
    /// 补边不越过本轨相邻段（任意说话人，含被丢弃的短段）的边界，避免把邻段的字裁进来造成重复；
    /// 与本段重叠的段无法避开，不作为边界。
    public func finalize(_ spans: [RawSpan], track: TrackKind, totalDuration: Double, offset: Double = 0) -> [ASRSegment] {
        let ends = spans.map(\.end).sorted()
        let starts = spans.map(\.start).sorted()
        return spans.compactMap { s in
            guard s.duration >= config.minSegment else { return nil }
            var lo = max(0, s.start - config.padding)
            var hi = min(totalDuration, s.end + config.padding)
            // 本段之前结束的最晚段尾、本段之后开始的最早段首
            if let prevEnd = Self.lastLE(ends, s.start) { lo = max(lo, min(prevEnd, s.start)) }
            if let nextStart = Self.firstGE(starts, s.end) { hi = min(hi, max(nextStart, s.end)) }
            return ASRSegment(
                speaker: s.speaker, track: track, start: s.start + offset, end: s.end + offset,
                cropStart: lo + offset,
                cropEnd: hi + offset
            )
        }
    }

    /// 有序数组中 ≤ x 的最大值。
    static func lastLE(_ a: [Double], _ x: Double) -> Double? {
        var l = 0, h = a.count
        while l < h {
            let m = (l + h) / 2
            if a[m] <= x { l = m + 1 } else { h = m }
        }
        return l > 0 ? a[l - 1] : nil
    }

    /// 有序数组中 ≥ x 的最小值。
    static func firstGE(_ a: [Double], _ x: Double) -> Double? {
        var l = 0, h = a.count
        while l < h {
            let m = (l + h) / 2
            if a[m] < x { l = m + 1 } else { h = m }
        }
        return l < a.count ? a[l] : nil
    }

    /// 单轨完整处理：合并 → 切分 → 丢弃短段 → 补边。
    public func process(_ spans: [RawSpan], track: TrackKind, totalDuration: Double, offset: Double = 0, silences: (Double, Double) -> [Double] = { _, _ in [] }) -> [ASRSegment] {
        finalize(split(merge(spans), silences: silences), track: track, totalDuration: totalDuration, offset: offset)
    }

    /// 6. 多轨段列表按起始时间合并排序，重叠段全部保留，并计算重叠比例。
    public static func combine(_ lists: [[ASRSegment]]) -> [ASRSegment] {
        var all = lists.flatMap { $0 }.sorted { ($0.start, $0.end, $0.speaker) < ($1.start, $1.end, $1.speaker) }
        for i in all.indices {
            var overlap = 0.0
            for j in all.indices where j != i && all[j].speaker != all[i].speaker {
                if all[j].start >= all[i].end { break }
                let o = min(all[i].end, all[j].end) - max(all[i].start, all[j].start)
                if o > 0 { overlap += o }
            }
            all[i].overlapRatio = all[i].duration > 0 ? min(1, overlap / all[i].duration) : 0
        }
        return all
    }
}

extension Array where Element == ASRSegment {
    /// 按说话人统计总时长。
    public func durationsBySpeaker() -> [String: Double] {
        reduce(into: [:]) { $0[$1.speaker, default: 0] += $1.duration }
    }
}

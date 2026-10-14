import Foundation

/// 特征片段候选窗口。
public struct ClipCandidate: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var duration: Double { end - start }

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

/// 特征片段挑选（4.6）。
public struct ClipSelector: Sendable {
    public var count: Int
    public var minSec: Double
    public var maxSec: Double
    /// 重叠比例超过该值的段不作为候选
    public var maxOverlap: Double = 0.05

    public init(count: Int = 3, minSec: Double = 3, maxSec: Double = 8) {
        self.count = count
        self.minSec = minSec
        self.maxSec = maxSec
    }

    /// 1. 候选：该说话人的语音段，排除重叠段与回声段；长段切成不超过 maxSec 的窗口。
    /// 不足 minSec 的段仅在没有足够长段时作为后备。
    public func candidates(from segments: [ASRSegment]) -> [ClipCandidate] {
        let clean = segments.filter { !$0.isEcho && $0.overlapRatio <= maxOverlap }
        var long: [ClipCandidate] = []
        var short: [ClipCandidate] = []
        for s in clean {
            if s.duration >= minSec {
                let pieces = max(1, Int((s.duration / maxSec).rounded(.up)))
                let len = s.duration / Double(pieces)
                for k in 0..<pieces {
                    long.append(ClipCandidate(start: s.start + Double(k) * len, end: s.start + Double(k + 1) * len))
                }
            } else if s.duration >= 1 {
                short.append(ClipCandidate(start: s.start, end: s.end))
            }
        }
        if long.count >= count { return long }
        // 后备：重叠段也纳入（仍排除回声），再不够才用短段
        if long.isEmpty {
            let overlapped = segments.filter { !$0.isEcho && $0.overlapRatio > maxOverlap && $0.duration >= minSec }
                .map { ClipCandidate(start: $0.start, end: min($0.end, $0.start + maxSec)) }
            if !overlapped.isEmpty { return overlapped + short.sorted { $0.duration > $1.duration } }
        }
        return long + short.sorted { $0.duration > $1.duration }
    }

    /// 3. 按分数从高到低选取，尽量来自会议中不同时间位置。
    /// - Parameters:
    ///   - scores: 与 candidates 对应的分数
    ///   - meetingDuration: 会议总时长，用于计算时间分散度
    public func select(_ candidates: [ClipCandidate], scores: [Double], meetingDuration: Double) -> [(ClipCandidate, Double)] {
        let ranked = zip(candidates, scores).sorted { $0.1 > $1.1 }
        let minGap = meetingDuration / Double(max(1, count) * 4)
        var picked: [(ClipCandidate, Double)] = []
        for c in ranked where picked.count < count {
            let mid = (c.0.start + c.0.end) / 2
            if picked.allSatisfy({ abs(($0.0.start + $0.0.end) / 2 - mid) >= minGap }) {
                picked.append(c)
            }
        }
        // 时间分散条件放宽后补足
        for c in ranked where picked.count < count && !picked.contains(where: { $0.0 == c.0 }) {
            picked.append(c)
        }
        return picked.sorted { $0.0.start < $1.0.start }
    }

    /// 打分：声纹相似度 × 信噪比权重（SNR 在 5~30 dB 间线性映射到 0.5~1）。
    public static func score(similarity: Double, snrDB: Double) -> Double {
        let w = 0.5 + 0.5 * min(1, max(0, (snrDB - 5) / 25))
        return max(0, similarity) * w
    }
}

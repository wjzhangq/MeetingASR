import XCTest
@testable import MeetingASRCore

final class ClusterMergeTests: XCTestCase {
    /// 单位向量：第 k 维为 1，叠加少量第 j 维（模拟同一人的声纹波动）。
    func vec(_ k: Int, _ j: Int = 7, _ noise: Float = 0) -> [Float] {
        var v = [Float](repeating: 0, count: 8)
        v[k] = 1
        v[j] += noise
        return VectorMath.normalized(v)
    }

    /// 按时间查表的声纹函数。
    func embedder(_ table: [(Double, Double, [Float])]) -> (Double, Double) -> [Float]? {
        { s, e in table.first { s >= $0.0 - 1e-6 && e <= $0.1 + 1e-6 }?.2 }
    }

    func testSimilarClustersMerge() {
        // 簇 0 与簇 2 是同一人（向量相近），簇 1 是另一人
        let spans = [
            RawSpan(speaker: "0", start: 0, end: 5),
            RawSpan(speaker: "1", start: 5, end: 10),
            RawSpan(speaker: "2", start: 10, end: 13),
        ]
        let table: [(Double, Double, [Float])] = [(0, 5, vec(0)), (5, 10, vec(1)), (10, 13, vec(0, 7, 0.3))]
        let out = SpeakerClusterMerger().merge(spans, fixedSpeakerCount: nil, matchThreshold: 0.6, embed: embedder(table), identify: nil)
        XCTAssertEqual(out.map(\.speaker), ["0", "1", "0"])
    }

    func testFixedCountSkipsSimilarityMerge() {
        let spans = [RawSpan(speaker: "0", start: 0, end: 5), RawSpan(speaker: "2", start: 10, end: 13)]
        let table: [(Double, Double, [Float])] = [(0, 5, vec(0)), (10, 13, vec(0, 7, 0.3))]
        let out = SpeakerClusterMerger().merge(spans, fixedSpeakerCount: 2, matchThreshold: 0.6, embed: embedder(table), identify: nil)
        XCTAssertEqual(out.map(\.speaker), ["0", "2"])
    }

    func testTinyClusterAbsorbed() {
        // 簇 3 只有 1.5 秒，与簇 1 中等相似（低于合并阈值，高于碎簇阈值）
        let spans = [
            RawSpan(speaker: "0", start: 0, end: 5),
            RawSpan(speaker: "1", start: 5, end: 10),
            RawSpan(speaker: "3", start: 10, end: 11.5),
        ]
        var mid = [Float](repeating: 0, count: 8)
        mid[1] = 1; mid[4] = 1.2
        let table: [(Double, Double, [Float])] = [(0, 5, vec(0)), (5, 10, vec(1)), (10, 11.5, VectorMath.normalized(mid))]
        let merger = SpeakerClusterMerger()
        let out = merger.merge(spans, fixedSpeakerCount: nil, matchThreshold: 0.6, embed: embedder(table), identify: nil)
        XCTAssertEqual(out.map(\.speaker), ["0", "1", "1"])
        // 关闭碎簇合并时保留
        var cfg = ClusterMergeConfig()
        cfg.minSpeakerSec = 0
        let kept = SpeakerClusterMerger(config: cfg).merge(spans, fixedSpeakerCount: nil, matchThreshold: 0.6, embed: embedder(table), identify: nil)
        XCTAssertEqual(kept.map(\.speaker), ["0", "1", "3"])
    }

    func testTinyDistinctSpeakerKept() {
        let spans = [RawSpan(speaker: "0", start: 0, end: 5), RawSpan(speaker: "1", start: 5, end: 6.5)]
        let table: [(Double, Double, [Float])] = [(0, 5, vec(0)), (5, 6.5, vec(1))]
        let out = SpeakerClusterMerger().merge(spans, fixedSpeakerCount: nil, matchThreshold: 0.6, embed: embedder(table), identify: nil)
        XCTAssertEqual(out.map(\.speaker), ["0", "1"])
    }

    func testSamePersonMergedEvenWithFixedCount() {
        // 两个簇声纹差异较大（不满足相似度合并），但都与人物库中的林涛匹配
        let spans = [
            RawSpan(speaker: "0", start: 0, end: 6),
            RawSpan(speaker: "1", start: 6, end: 10),
            RawSpan(speaker: "2", start: 10, end: 20),
        ]
        let table: [(Double, Double, [Float])] = [(0, 6, vec(0)), (6, 10, vec(1)), (10, 20, vec(2))]
        let identify: SpeakerClusterMerger.Identify = { e in
            if e[0] > 0.9 || e[1] > 0.9 { return ("lintao", 0.7) }
            return ("other", 0.3)
        }
        let out = SpeakerClusterMerger().merge(spans, fixedSpeakerCount: 3, matchThreshold: 0.6, embed: embedder(table), identify: identify)
        // 时长较长的簇 0 保留
        XCTAssertEqual(out.map(\.speaker), ["0", "0", "2"])
    }

    func testSegmenterMergesOverlapAfterRelabel() {
        // 同一人被分成两个簇且时间重叠：重新标注后由 Segmenter 合并为一段，避免重复识别
        let spans = [RawSpan(speaker: "0", start: 25, end: 28), RawSpan(speaker: "0", start: 25.5, end: 27.8)]
        let out = Segmenter().merge(spans)
        XCTAssertEqual(out, [RawSpan(speaker: "0", start: 25, end: 28)])
    }
}

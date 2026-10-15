import XCTest
@testable import MeetingASRCore

final class BlockDiarizationTests: XCTestCase {
    func testShortAudioSingleBlock() {
        var cfg = BlockDiarizationConfig()
        cfg.blockSec = 10
        let x = [Float](repeating: 0.1, count: 16_000 * 14)
        XCTAssertEqual(BlockPlanner.blocks(x, sampleRate: 16_000, config: cfg), [0..<x.count])
    }

    func testCutsAtQuietPoint() {
        var cfg = BlockDiarizationConfig()
        cfg.blockSec = 10
        cfg.searchSec = 3
        let sr = 1000
        // 33 秒；第 11.2 秒和第 19.5 秒附近各有一段静音
        var x = [Float](repeating: 0.3, count: sr * 33)
        for i in Int(11.1 * Double(sr))..<Int(11.5 * Double(sr)) { x[i] = 0 }
        for i in Int(19.4 * Double(sr))..<Int(19.8 * Double(sr)) { x[i] = 0 }
        let b = BlockPlanner.blocks(x, sampleRate: sr, config: cfg)
        XCTAssertEqual(b.count, 3)
        XCTAssertEqual(b.first?.lowerBound, 0)
        XCTAssertEqual(b.last?.upperBound, x.count)
        for (a, c) in zip(b, b.dropFirst()) { XCTAssertEqual(a.upperBound, c.lowerBound) }
        // 切点落在静音内
        XCTAssertEqual(x[b[0].upperBound], 0)
        XCTAssertEqual(x[b[1].upperBound], 0)
    }

    func vec(_ k: Int, _ noise: Float = 0) -> [Float] {
        var v = [Float](repeating: 0, count: 8)
        v[k] = 1
        v[7] += noise
        return VectorMath.normalized(v)
    }

    func testLinkAcrossBlocks() {
        // 块 0：A、B；块 1：B'、A'、C；块 2：A''
        let items = [
            CrossBlockLinker.Item(id: "s-0-0", block: 0, duration: 200, centroid: vec(0)),
            CrossBlockLinker.Item(id: "s-0-1", block: 0, duration: 100, centroid: vec(1)),
            CrossBlockLinker.Item(id: "s-1-0", block: 1, duration: 150, centroid: vec(1, 0.3)),
            CrossBlockLinker.Item(id: "s-1-1", block: 1, duration: 120, centroid: vec(0, 0.4)),
            CrossBlockLinker.Item(id: "s-1-2", block: 1, duration: 50, centroid: vec(2)),
            CrossBlockLinker.Item(id: "s-2-0", block: 2, duration: 300, centroid: vec(0, 0.2)),
        ]
        let m = CrossBlockLinker.link(items, similarity: 0.5, fixedCount: nil)
        XCTAssertEqual(m["s-0-0"], "s-2-0")
        XCTAssertEqual(m["s-1-1"], "s-2-0")
        XCTAssertEqual(m["s-2-0"], "s-2-0")
        XCTAssertEqual(m["s-0-1"], "s-1-0")
        XCTAssertEqual(m["s-1-0"], "s-1-0")
        XCTAssertEqual(m["s-1-2"], "s-1-2")
    }

    func testSameBlockNeverLinkedByThreshold() {
        let items = [
            CrossBlockLinker.Item(id: "s-0-0", block: 0, duration: 10, centroid: vec(0)),
            CrossBlockLinker.Item(id: "s-0-1", block: 0, duration: 10, centroid: vec(0, 0.1)),
        ]
        XCTAssertEqual(Set(CrossBlockLinker.link(items, similarity: 0.5, fixedCount: nil).values).count, 2)
        // 指定 1 人时允许合并
        XCTAssertEqual(Set(CrossBlockLinker.link(items, similarity: 0.5, fixedCount: 1).values).count, 1)
    }

    func testFixedCountMergesDownToCount() {
        let items = (0..<4).map { CrossBlockLinker.Item(id: "s-\($0)-0", block: $0, duration: 10, centroid: vec($0)) }
        XCTAssertEqual(Set(CrossBlockLinker.link(items, similarity: 0.5, fixedCount: 2).values).count, 2)
        XCTAssertEqual(Set(CrossBlockLinker.link(items, similarity: 0.5, fixedCount: nil).values).count, 4)
    }
}

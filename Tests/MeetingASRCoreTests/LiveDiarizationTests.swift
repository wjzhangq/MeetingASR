import XCTest
@testable import MeetingASRCore

/// 每次调用返回一个覆盖整段的说话人 "0"，记录每次输入长度。
private final class CountingDiarizer: SpeakerDiarizer {
    var calls: [Int] = []
    func diarize(_ samples: [Float], options: DiarizationOptions, progress: @escaping (Double) -> Bool) -> [RawSpan] {
        calls.append(samples.count)
        return [RawSpan(speaker: "0", start: 0, end: Double(samples.count) / 16_000)]
    }
}

final class LiveDiarizationTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("masr-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func key(threshold: Float = 0.5) -> DiarizationCache.Key {
        var rec = RecognitionSettings()
        rec.clusterThreshold = threshold
        var cfg = BlockDiarizationConfig()
        cfg.blockSec = 10
        return DiarizationCache.Key(track: .system, recognition: rec, config: cfg, models: .bundled)
    }

    func block(_ s: Int, _ e: Int) -> DiarizationCache.Block {
        DiarizationCache.Block(start: s, end: e, spans: [])
    }

    func testUsableBlocks() {
        var c = DiarizationCache(key: key())
        c.blocks = [block(0, 100), block(100, 220), block(220, 300)]
        XCTAssertEqual(c.usableBlocks(key: key(), totalSamples: 1000, minTail: 50).map(\.end), [100, 220, 300])
        // 参数不同：全部作废
        XCTAssertTrue(c.usableBlocks(key: key(threshold: 0.7), totalSamples: 1000, minTail: 50).isEmpty)
        // 剩余部分过短：去掉最后一块
        XCTAssertEqual(c.usableBlocks(key: key(), totalSamples: 320, minTail: 50).map(\.end), [100, 220])
        // 超出音轨的块不用
        XCTAssertEqual(c.usableBlocks(key: key(), totalSamples: 260, minTail: 10).map(\.end), [100, 220])
        // 不连续时只取前面连续的部分
        c.blocks = [block(0, 100), block(120, 200)]
        XCTAssertEqual(c.usableBlocks(key: key(), totalSamples: 1000, minTail: 50).map(\.end), [100])
    }

    func testPlannerFromOffset() {
        var cfg = BlockDiarizationConfig()
        cfg.blockSec = 10
        cfg.searchSec = 3
        let sr = 1000
        let x = [Float](repeating: 0.2, count: sr * 40)
        let b = BlockPlanner.blocks(x, sampleRate: sr, config: cfg, from: 12_000)
        XCTAssertEqual(b.first?.lowerBound, 12_000)
        XCTAssertEqual(b.last?.upperBound, x.count)
        for (a, c) in zip(b, b.dropFirst()) { XCTAssertEqual(a.upperBound, c.lowerBound) }
        // 剩余不足 1.5 块时整段一块
        XCTAssertEqual(BlockPlanner.blocks(x, sampleRate: sr, config: cfg, from: 30_000), [30_000..<40_000])
        XCTAssertEqual(BlockPlanner.blocks(x, sampleRate: sr, config: cfg, from: 40_000), [])
    }

    func testIncrementalBlocksWhileFileGrows() throws {
        let wav = dir.appendingPathComponent("system.wav")
        let cacheURL = dir.appendingPathComponent("diarization_system.json")
        let sr = 48_000
        let writer = try WavWriter(url: wav, sampleRate: sr)
        var written = 0
        /// 正弦信号，每 10 秒整点前后 0.2 秒静音（切点应落在这里）
        func append(seconds: Double) {
            let n = Int(seconds * Double(sr))
            writer.write((written..<(written + n)).map { i -> Float in
                let t = Double(i) / Double(sr)
                let r = t.truncatingRemainder(dividingBy: 10)
                return (r < 0.2 || r > 9.8) && t > 1 ? 0 : Float(sin(Double(i) * 0.05)) * 0.2
            })
            written += n
            writer.updateHeader()
        }
        var cfg = BlockDiarizationConfig()
        cfg.blockSec = 10
        cfg.searchSec = 3
        let d = CountingDiarizer()
        let live = LiveDiarizer(source: wav, cacheURL: cacheURL, key: key(), recognition: RecognitionSettings(), diarizer: d, config: cfg)

        append(seconds: 8)
        XCTAssertEqual(try live.step(), 0) // 不够一块（需要块长 + 搜索范围）
        append(seconds: 30)               // 共 38 秒：切在 10、20、30 秒
        XCTAssertEqual(try live.step(), 3)
        append(seconds: 6)                // 共 44 秒：切在 40 秒
        XCTAssertEqual(try live.step(), 1)
        try writer.close()

        let cache = try XCTUnwrap(DiarizationCache.load(from: cacheURL))
        XCTAssertEqual(cache.blocks.count, 4)
        XCTAssertEqual(cache.blocks.first?.start, 0)
        for (a, b) in zip(cache.blocks, cache.blocks.dropFirst()) { XCTAssertEqual(a.end, b.start) }
        // 切点落在静音处，片段时间为音轨绝对时间
        for (k, b) in cache.blocks.enumerated() {
            XCTAssertEqual(Double(b.end) / 16_000, Double(k + 1) * 10, accuracy: 0.25)
            XCTAssertEqual(b.spans.first?.start ?? -1, Double(b.start) / 16_000, accuracy: 1e-6)
        }
        XCTAssertEqual(d.calls.count, 4)

        // 停止后不再开始新块
        let stopped = LiveDiarizer(source: wav, cacheURL: dir.appendingPathComponent("x.json"), key: key(), recognition: RecognitionSettings(),
                                   diarizer: d, config: cfg, isStopped: { true })
        XCTAssertEqual(try stopped.step(), 0)
    }
}

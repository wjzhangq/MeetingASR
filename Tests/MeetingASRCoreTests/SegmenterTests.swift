import XCTest
@testable import MeetingASRCore

final class SegmenterTests: XCTestCase {
    let seg = Segmenter()

    func testMergeSameSpeakerSmallGap() {
        let spans = [
            RawSpan(speaker: "A", start: 0, end: 2),
            RawSpan(speaker: "A", start: 2.3, end: 4),
            RawSpan(speaker: "A", start: 5, end: 6),
            RawSpan(speaker: "B", start: 6.2, end: 7),
        ]
        let m = seg.merge(spans)
        XCTAssertEqual(m, [
            RawSpan(speaker: "A", start: 0, end: 4),
            RawSpan(speaker: "A", start: 5, end: 6),
            RawSpan(speaker: "B", start: 6.2, end: 7),
        ])
    }

    func testMergeDoesNotSwallowInterruption() {
        let spans = [
            RawSpan(speaker: "A", start: 0, end: 2),
            RawSpan(speaker: "B", start: 2.05, end: 2.4),
            RawSpan(speaker: "A", start: 2.45, end: 4),
        ]
        XCTAssertEqual(seg.merge(spans).count, 3)
    }

    func testSplitLongSegmentAtSilence() {
        let spans = [RawSpan(speaker: "A", start: 0, end: 70)]
        let out = seg.split(spans) { _, _ in [12, 25, 41, 58] }
        XCTAssertEqual(out.map(\.start), [0, 25, 41])
        XCTAssertEqual(out.map(\.end), [25, 41, 70])
        XCTAssertTrue(out.allSatisfy { $0.duration <= 30 })
    }

    func testSplitHardWhenNoSilence() {
        let out = seg.split([RawSpan(speaker: "A", start: 10, end: 75)]) { _, _ in [] }
        XCTAssertEqual(out.map(\.start), [10, 40, 70])
        XCTAssertEqual(out.last?.end, 75)
    }

    func testFinalizeDropsShortAndPads() {
        let out = seg.finalize([
            RawSpan(speaker: "A", start: 0.05, end: 1),
            RawSpan(speaker: "A", start: 2, end: 2.2),
            RawSpan(speaker: "B", start: 9.95, end: 10),
            RawSpan(speaker: "B", start: 5, end: 9.98),
        ], track: .system, totalDuration: 10, offset: 100)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].cropStart, 100, accuracy: 1e-9)
        XCTAssertEqual(out[0].start, 100.05, accuracy: 1e-9)
        XCTAssertEqual(out[1].cropStart, 104.9, accuracy: 1e-9)
        XCTAssertEqual(out[1].cropEnd, 110, accuracy: 1e-9)
    }

    func testCombineSortsAndMarksOverlap() {
        let mic = [ASRSegment(speaker: "M", track: .mic, start: 5, end: 7, cropStart: 4.9, cropEnd: 7.1)]
        let sys = [
            ASRSegment(speaker: "S1", track: .system, start: 0, end: 6, cropStart: 0, cropEnd: 6.1),
            ASRSegment(speaker: "S2", track: .system, start: 8, end: 9, cropStart: 7.9, cropEnd: 9.1),
        ]
        let all = Segmenter.combine([mic, sys])
        XCTAssertEqual(all.map(\.speaker), ["S1", "M", "S2"])
        XCTAssertEqual(all[0].overlapRatio, 1.0 / 6, accuracy: 1e-9)
        XCTAssertEqual(all[1].overlapRatio, 0.5, accuracy: 1e-9)
        XCTAssertEqual(all[2].overlapRatio, 0)
    }

    func testEchoDetection() {
        let rate = 16_000
        // 远端语音：调幅噪声
        var system: [Float] = []
        for i in 0..<(rate * 2) {
            let env = Float(0.5 + 0.5 * sin(2 * Double.pi * 3 * Double(i) / Double(rate)))
            system.append(env * Float.random(in: -0.3...0.3))
        }
        // 回声：延迟 80ms、衰减 15 dB
        let delay = Int(0.08 * Double(rate))
        let echo = [Float](repeating: 0, count: delay) + system.prefix(system.count - delay).map { $0 * 0.18 }
        let det = EchoDetector()
        XCTAssertTrue(det.isEcho(mic: echo, system: system))
        // 本人说话：与远端无关
        var own: [Float] = []
        for i in 0..<(rate * 2) {
            let env = Float(0.5 + 0.5 * sin(2 * Double.pi * 1.3 * Double(i) / Double(rate) + 1))
            own.append(env * Float.random(in: -0.1...0.1))
        }
        XCTAssertFalse(det.isEcho(mic: own, system: system))
        // 麦克风能量更高时（本人说话盖过外放）不判为回声
        XCTAssertFalse(det.isEcho(mic: system.map { $0 * 2 }, system: system))
    }
}

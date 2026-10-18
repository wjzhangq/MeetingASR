import XCTest
@testable import MeetingASRCore

final class SegmentFixTests: XCTestCase {
    func testSimilarClustersMerge() {
        var config = SegmentClusteringConfig()
        config.mergeSimilarity = 0.5
        config.minClusterSec = 30
        config.shortSegmentSec = 1
        let clusterer = SegmentClusterer(config: config)

        func seg(_ id: Int, _ v: [Float]) -> Segment {
            var s = Segment(
                id: id, track: .file,
                start: Double(id) * 12, end: Double(id) * 12 + 10,
                speechStart: Double(id) * 12, speechEnd: Double(id) * 12 + 10
            )
            s.embedding = v
            return s
        }

        let a = VectorMath.normalized([1, 0.2, 0, 0, 0, 0, 0, 0])
        let a2 = VectorMath.normalized([1, 0, 0.2, 0, 0, 0, 0, 0])
        let b = VectorMath.normalized([0, 0, 0, 1, 0.2, 0, 0, 0])
        let b2 = VectorMath.normalized([0, 0, 0, 1, 0, 0.2, 0, 0])
        let out = clusterer.cluster([seg(0, a), seg(1, a2), seg(2, b), seg(3, b2), seg(4, a)])
        XCTAssertEqual(Set(out.compactMap(\.cluster)).count, 2)
        XCTAssertEqual(out[0].cluster, out[1].cluster)
        XCTAssertEqual(out[0].cluster, out[4].cluster)
        XCTAssertEqual(out[2].cluster, out[3].cluster)
        XCTAssertNotEqual(out[0].cluster, out[2].cluster)
    }

    func testThreeWaySplitDoesNotDuplicateTokens() {
        let e0 = VectorMath.normalized([Float]([1, 0, 0, 0]))
        let e1 = VectorMath.normalized([Float]([0, 1, 0, 0]))
        func anchored(_ id: Int, _ cluster: String, _ embedding: [Float]) -> Segment {
            var s = Segment(
                id: id, track: .file,
                start: Double(id) * 20, end: Double(id) * 20 + 10,
                speechStart: Double(id) * 20, speechEnd: Double(id) * 20 + 10
            )
            s.cluster = cluster
            s.embedding = embedding
            return s
        }
        var mixed = Segment(id: 9, track: .file, start: 0, end: 6, speechStart: 0, speechEnd: 6)
        mixed.isMixed = true
        mixed.subwindows = [
            SubwindowEmbedding(start: 0, end: 2, embedding: e0),
            SubwindowEmbedding(start: 2, end: 4, embedding: e1),
            SubwindowEmbedding(start: 4, end: 6, embedding: e0),
        ]
        mixed.tokens = [
            TranscriptToken(t: "甲", start: 1),
            TranscriptToken(t: "乙", start: 3.5),
            TranscriptToken(t: "丙", start: 5.5),
        ]
        let out = SegmentAssigner().splitMixedSegments([
            anchored(0, "C0", e0), anchored(1, "C1", e1), mixed,
        ])
        let pieces = out.filter { $0.id == 9 }
        XCTAssertEqual(pieces.map(\.text), ["甲", "乙", "丙"])
        XCTAssertEqual(pieces.flatMap(\.tokens).map(\.t), ["甲", "乙", "丙"])
    }

    func testTurnFallsBackToSegmentText() {
        var hello = Segment(id: 0, track: .file, start: 0, end: 1, speechStart: 0, speechEnd: 1)
        hello.text = "hello"
        hello.speaker = "S1"
        var world = Segment(id: 1, track: .file, start: 1.2, end: 2, speechStart: 1.2, speechEnd: 2)
        world.text = "world"
        world.speaker = "S1"
        XCTAssertEqual(TurnAssembler.turns([hello, world], gap: 1).map(\.text), ["hello world"])

        hello.text = "你好"
        world.text = "世界"
        XCTAssertEqual(TurnAssembler.turns([hello, world], gap: 1).map(\.text), ["你好世界"])
    }

    func testLongRangeHardCutAndQuietCut() {
        let sr = 16_000
        let loud = [Float](repeating: 0.2, count: sr * 10)
        let hard = SpeechRangeSplitter.split([0...10], samples: loud, sampleRate: sr, maxSec: 3)
        XCTAssertEqual(hard.count, 4)
        XCTAssertEqual(hard[0].lowerBound, 0, accuracy: 0.001)
        XCTAssertEqual(hard[0].upperBound, 3, accuracy: 0.02)
        XCTAssertEqual(hard.last?.upperBound ?? 0, 10, accuracy: 0.001)
        XCTAssertTrue(hard.allSatisfy { $0.upperBound - $0.lowerBound <= 3.05 })

        var dipped = loud
        for i in Int(2.7 * Double(sr))..<Int(3.0 * Double(sr)) { dipped[i] = 0 }
        let soft = SpeechRangeSplitter.split([0...10], samples: dipped, sampleRate: sr, maxSec: 4, searchSec: 2)
        XCTAssertGreaterThan(soft[0].upperBound, 2.6)
        XCTAssertLessThan(soft[0].upperBound, 3.2)
        XCTAssertEqual(soft.last?.upperBound ?? 0, 10, accuracy: 0.001)
    }

    func testASRChunksDoNotOverlapOrExceedCap() throws {
        let asr = LengthASR()
        let samples = [Float](repeating: 0.1, count: 90 * 16_000)
        let seg = Segment(id: 0, track: .file, start: 0, end: 90, speechStart: 0, speechEnd: 90)
        let out = try SegmentPipeline(config: SegmentClusteringConfig(), maxASRSec: 60)
            .process([seg], samples: samples, recognizer: asr, embedder: UnitEmbedder())
        XCTAssertEqual(asr.lengths, [60 * 16_000, 30 * 16_000])
        XCTAssertTrue(asr.lengths.allSatisfy { $0 <= 60 * 16_000 })
        XCTAssertEqual(out[0].tokens.map { Int(($0.start * 100).rounded()) }, [5, 6005])
        XCTAssertEqual(out[0].start, 0)
        XCTAssertEqual(out[0].end, 90)
    }

    func testSegmentLogRejectsMismatchedKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("masr-log-\(UUID().uuidString)")
        let meeting = MeetingPaths(dir: root.appendingPathComponent("m"))
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SegmentLogKey(track: .file, vadConfig: SegmentVADConfig(), asrModel: "paraformer", embeddingModel: "campp")
        let url = SegmentLog.url(meeting, track: .file)
        try SegmentLog.create(url, key: key)
        var seg = Segment(id: 1, track: .file, start: 0, end: 1, speechStart: 0, speechEnd: 1)
        seg.text = "甲"
        try SegmentLog.append(seg, to: url)
        XCTAssertEqual(SegmentLog.usableSegments(meeting: meeting, track: .file, key: key).map(\.text), ["甲"])
        var other = key
        other.asrModel = "firered"
        XCTAssertTrue(SegmentLog.usableSegments(meeting: meeting, track: .file, key: other).isEmpty)
    }
}

private final class LengthASR: SpeechRecognizer {
    var modelName = "length"
    var lengths: [Int] = []
    private let lock = NSLock()

    func recognize(_ samples: [Float]) -> RecognitionResult {
        lock.lock()
        lengths.append(samples.count)
        lock.unlock()
        return RecognitionResult(text: "a", tokens: [TranscriptToken(t: "a", start: 0.05)])
    }
}

private final class UnitEmbedder: SpeakerEmbedder {
    var modelName = "unit"
    func embed(_ samples: [Float]) -> [Float]? {
        guard samples.count >= 8_000 else { return nil }
        return [1, 0, 0, 0]
    }
}

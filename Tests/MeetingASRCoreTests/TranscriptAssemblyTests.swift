import XCTest
@testable import MeetingASRCore

final class OverlapDedupTests: XCTestCase {
    func toks(_ s: String, from t0: Double, step: Double = 0.2) -> [TranscriptToken] {
        s.enumerated().map { TranscriptToken(t: String($1), start: t0 + Double($0) * step) }
    }

    func testTokenJoin() {
        let t = ["你", "测", "的", "是", "a", "s", "r", "吗", "hello", "world"].map { TranscriptToken(t: $0, start: 0) }
        XCTAssertEqual(TokenText.join(t), "你测的是 a s r 吗 hello world")
    }

    func testOverlappingDuplicateTokensRemovedFromShorterSegment() {
        // 林涛 20~28 秒；王伟 25~28 秒与之重叠，裁剪的混合音频把林涛 25~27 秒的话也识别了一遍
        let a = RecognizedPiece(speaker: "S2", track: .system, start: 20, end: 28, text: "", tokens: toks("我们先看一下端侧的效果", from: 20, step: 0.6))
        let dupStart = a.tokens[9].start
        let b = RecognizedPiece(speaker: "S3", track: .system, start: 25, end: 28, text: "", tokens: toks("的效果", from: dupStart - 0.1) + toks("好", from: 27.5))
        let out = OverlapDeduplicator.dedupe([a, b])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[1].tokens.map(\.t), ["好"])
        XCTAssertEqual(out[1].text, "好")
        XCTAssertEqual(out[0].tokens.count, a.tokens.count)
    }

    func testFullyDuplicatedSegmentDropped() {
        let a = RecognizedPiece(speaker: "S2", track: .system, start: 20, end: 28, text: "x", tokens: toks("今天中午吃的啥呀", from: 25))
        let b = RecognizedPiece(speaker: "S3", track: .system, start: 25, end: 27, text: "x", tokens: toks("今天中午吃的啥", from: 25.05))
        XCTAssertEqual(OverlapDeduplicator.dedupe([a, b]).map(\.speaker), ["S2"])
    }

    func testDifferentTracksOrNoOverlapUntouched() {
        let a = RecognizedPiece(speaker: "S1", track: .mic, start: 0, end: 5, text: "x", tokens: toks("好的", from: 1))
        let b = RecognizedPiece(speaker: "S2", track: .system, start: 0, end: 5, text: "x", tokens: toks("好的", from: 1))
        let c = RecognizedPiece(speaker: "S3", track: .system, start: 5, end: 8, text: "x", tokens: toks("好的", from: 5))
        XCTAssertEqual(OverlapDeduplicator.dedupe([a, b, c]).count, 3)
    }

    func testTextFallbackWithoutTimestamps() {
        let a = RecognizedPiece(speaker: "S2", track: .system, start: 20, end: 28, text: "我们先看一下端侧的效果，然后再说。")
        let b = RecognizedPiece(speaker: "S3", track: .system, start: 24, end: 27, text: "看一下端侧效果")
        let c = RecognizedPiece(speaker: "S4", track: .system, start: 26, end: 29, text: "我不同意")
        XCTAssertEqual(OverlapDeduplicator.dedupe([a, b, c]).map(\.speaker), ["S2", "S4"])
    }
}

final class AsrFirstTests: XCTestCase {
    func seg(_ spk: String, _ s: Double, _ e: Double, echo: Bool = false) -> ASRSegment {
        var x = ASRSegment(speaker: spk, track: .system, start: s, end: e, cropStart: s, cropEnd: e)
        x.isEcho = echo
        return x
    }

    func timed(_ s: String, from t0: Double, step: Double = 0.25) -> [TimedToken] {
        s.enumerated().map { TimedToken(t: String($1), start: t0 + Double($0) * step, end: t0 + Double($0 + 1) * step) }
    }

    func testChunkerGroupsAndPads() {
        let c = AsrChunker().chunks(speech: [0.5...3, 2...4, 4.6...8, 20...22], total: 30)
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c[0].start, 0.5)
        XCTAssertEqual(c[0].end, 8)
        XCTAssertEqual(c[0].cropStart, 0.25, accuracy: 1e-9)
        XCTAssertEqual(c[1].cropEnd, 22.25, accuracy: 1e-9)
    }

    func testChunkerSplitsLongSpeechAtSilence() {
        let c = AsrChunker().chunks(speech: [0...60], silences: [18, 24, 47], total: 60)
        XCTAssertEqual(c.map(\.start), [0, 24, 47])
        XCTAssertTrue(c.allSatisfy { $0.end - $0.start <= 25 })
    }

    func testTokenEnds() {
        let t = TimedToken.from([TranscriptToken(t: "a", start: 1), TranscriptToken(t: "b", start: 1.2), TranscriptToken(t: "c", start: 3)], chunkEnd: 3.1)
        XCTAssertEqual(t.map(\.end), [1.2, 2.0, 3.1])
    }

    func testOverlapTranscribedOnce() {
        // A 0~10 秒；B 8~14 秒，8~10 秒重叠。重叠部分只出现一次，延续 A
        let tokens = timed("我们先看一下端侧的效果然后", from: 0.2, step: 0.75) + timed("好的我同意", from: 10.5, step: 0.6)
        let out = SpeakerAssigner().assign(tokens, spans: [seg("A", 0, 10), seg("B", 8, 14)], track: .system)
        XCTAssertEqual(out.map(\.speaker), ["A", "B"])
        XCTAssertEqual(out[0].text, "我们先看一下端侧的效果然后")
        XCTAssertEqual(out[1].text, "好的我同意")
        XCTAssertEqual(out.flatMap(\.tokens).count, tokens.count)
    }

    func testShortRunSmoothed() {
        // 边界抖动：A 的一句话中间有 1 个字落在 B 的短段里
        let tokens = timed("今天中午吃的啥呀", from: 0, step: 0.3)
        let out = SpeakerAssigner().assign(tokens, spans: [seg("A", 0, 1.4), seg("B", 1.4, 1.65), seg("A", 1.65, 3)], track: .system)
        XCTAssertEqual(out.map(\.speaker), ["A"])
        XCTAssertEqual(out[0].text, "今天中午吃的啥呀")
    }

    func testEchoTokensDropped() {
        let tokens = timed("你好", from: 1) + timed("远端的话", from: 5) + timed("嗯", from: 9.9)
        let out = SpeakerAssigner().assign(tokens, spans: [seg("M", 0.8, 2), seg("M", 4.9, 9.8, echo: true)], track: .mic)
        XCTAssertEqual(out.map(\.text), ["你好"])
    }

    func testSegmentBoundsSnapToSpans() {
        let out = SpeakerAssigner().assign(timed("好的", from: 2.3), spans: [seg("A", 2, 3)], track: .system)
        XCTAssertEqual(out[0].start, 2)
        XCTAssertEqual(out[0].end, 3)
    }

    func testSplitOnLongPause() {
        let out = SpeakerAssigner().assign(timed("第一句", from: 0) + timed("第二句", from: 5), spans: [seg("A", 0, 6)], track: .system)
        XCTAssertEqual(out.map(\.text), ["第一句", "第二句"])
    }
}

final class TextEchoTests: XCTestCase {
    func toks(_ s: String, from t0: Double, step: Double = 0.25) -> [TranscriptToken] {
        s.enumerated().map { TranscriptToken(t: String($1), start: t0 + Double($0) * step) }
    }

    func piece(_ track: TrackKind, _ spk: String, _ text: String, from t0: Double) -> RecognizedPiece {
        let t = toks(text, from: t0)
        return RecognizedPiece(speaker: spk, track: track, start: t0, end: t0 + Double(text.count) * 0.25, text: text, tokens: t)
    }

    func testEchoRunRemovedOwnSpeechKept() {
        let sys = piece(.system, "S2", "我们下周再讨论端侧方案", from: 10)
        // 麦克风：本人先说"好的"，随后外放回声（滞后 0.15 秒、有一个字识别错）
        var mic = piece(.mic, "S1", "好的", from: 9.3)
        mic.tokens += toks("我们下州再讨论端侧方案", from: 10.15)
        mic.end = 13
        let out = TextEchoFilter().filter([mic, sys])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.first { $0.track == .mic }?.text, "好的")
    }

    func testWhollyEchoedPieceDropped() {
        let sys = piece(.system, "S2", "今天中午吃的啥呀", from: 20)
        let mic = piece(.mic, "S1", "今天中午吃的啥呀", from: 20.2)
        XCTAssertEqual(TextEchoFilter().filter([mic, sys]).map(\.track), [.system])
    }

    func testCoincidentalCommonCharsKept() {
        let sys = piece(.system, "S2", "这是我的问题", from: 5)
        let mic = piece(.mic, "S1", "那是你的看法", from: 5.1)
        XCTAssertEqual(TextEchoFilter().filter([mic, sys]).count, 2)
    }

    func testSameTextAtDifferentTimeKept() {
        let sys = piece(.system, "S2", "我同意这个方案", from: 5)
        let mic = piece(.mic, "S1", "我同意这个方案", from: 30)
        XCTAssertEqual(TextEchoFilter().filter([mic, sys]).count, 2)
    }

    func testTextFallbackWithoutTokens() {
        let sys = RecognizedPiece(speaker: "S2", track: .system, start: 10, end: 14, text: "我们下周再讨论端侧方案。")
        let mic = RecognizedPiece(speaker: "S1", track: .mic, start: 10.1, end: 14, text: "下周再讨论端侧方案")
        let own = RecognizedPiece(speaker: "S1", track: .mic, start: 15, end: 16, text: "好的没问题")
        XCTAssertEqual(TextEchoFilter().filter([mic, sys, own]).map(\.text), ["我们下周再讨论端侧方案。", "好的没问题"])
    }
}

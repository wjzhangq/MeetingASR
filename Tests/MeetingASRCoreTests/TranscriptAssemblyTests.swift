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

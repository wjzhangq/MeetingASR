import XCTest
@testable import MeetingASRCore

final class TextNormalizationTests: XCTestCase {
    let n = AcronymNormalizer()

    func testSpacedLettersBecomeAcronym() {
        XCTAssertEqual(n.normalize("你测的是 a s r 吗"), "你测的是 ASR 吗")
        XCTAssertEqual(n.normalize("用a p i调"), "用API调")
        // 词典外的字母串直接大写
        XCTAssertEqual(n.normalize("x y z 方案"), "XYZ 方案")
    }

    func testDictionarySegmentation() {
        XCTAssertEqual(n.normalize("c p p s d k 已经发了"), "C++ SDK 已经发了")
        XCTAssertEqual(n.normalize("i o s 端"), "iOS 端")
    }

    func testWholeWordCase() {
        XCTAssertEqual(n.normalize("这个 asr 和 sdk"), "这个 ASR 和 SDK")
        // 常见英文单词与普通单词不改
        XCTAssertEqual(n.normalize("open the app it is ok"), "open the app it is ok")
        XCTAssertEqual(n.normalize("hello world"), "hello world")
    }

    func testSingleLetterAndWordsUntouched() {
        XCTAssertEqual(n.normalize("选 a 方案"), "选 a 方案")
        XCTAssertEqual(n.normalize("a good plan"), "a good plan")
        XCTAssertEqual(n.normalize("C++ 写的"), "C++ 写的")
    }

    func testExtraFromHotwords() {
        let m = AcronymNormalizer(extra: ["MeetingASR", "FunASR", "星图平台", "Sherpa ONNX"])
        XCTAssertEqual(m.normalize("f u n a s r 的模型"), "FunASR 的模型")
        XCTAssertEqual(m.normalize("funasr 的模型"), "FunASR 的模型")
    }

    func testTokens() {
        let toks = ["测", "a", "s", "r", "吗"].enumerated().map { TranscriptToken(t: $1, start: Double($0) * 0.1) }
        let out = n.normalize(tokens: toks)
        XCTAssertEqual(out.map(\.t), ["测", "ASR", "吗"])
        XCTAssertEqual(out[1].start, 0.1)
        XCTAssertEqual(n.normalize(tokens: [TranscriptToken(t: "sdk", start: 1)]).map(\.t), ["SDK"])
    }
}

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

final class SubwordMergerTests: XCTestCase {
    func testParaformerBPE() {
        let t = SubwordMerger.merge([("我", 0), ("用", 0.2), ("sher@@", 0.4), ("pa", 0.5), ("吧", 0.8)])
        XCTAssertEqual(t.map(\.t), ["我", "用", "sherpa", "吧"])
        XCTAssertEqual(t[2].start, 0.4)
    }

    func testSentencePiece() {
        let t = SubwordMerger.merge([("测", 0), ("▁fire", 0.2), ("red", 0.3), ("▁asr", 0.5), ("模", 0.7), ("型", 0.8), ("<unk>", 0.9)])
        XCTAssertEqual(t.map(\.t), ["测", "fire" + "red", "asr", "模", "型"])
        XCTAssertEqual(TokenText.join(t), "测 firered asr 模型")
    }
}

final class EstimatedTokensTests: XCTestCase {
    func testEstimatedWhenModelHasNoTimestamps() {
        let r = RecognitionResult(text: "用 FireRed 识别，好的。")
        let t = r.tokensOrEstimated(start: 1, end: 3)
        XCTAssertEqual(t.map(\.t), ["用", "FireRed", "识", "别", "好", "的"])
        XCTAssertEqual(t.first?.start, 1)
        XCTAssertLessThan(t.last!.start, 3)
        // 有时间戳时原样返回
        let r2 = RecognitionResult(text: "好", tokens: [TranscriptToken(t: "好", start: 0.3)])
        XCTAssertEqual(r2.tokensOrEstimated(start: 0, end: 1).map(\.start), [0.3])
    }

    func testAsrModelNames() {
        XCTAssertEqual(AsrModelKind(cliName: "firered-ctc"), .fireRedAsrCtc)
        XCTAssertNil(AsrModelKind(cliName: "whisper"))
        XCTAssertFalse(AsrModelKind.fireRedAsrAed.providesTimestamps)
        XCTAssertEqual(AsrModelKind.fireRedAsrCtc.releaseURL.lastPathComponent, "sherpa-onnx-fire-red-asr2-ctc-zh_en-int8-2026-02-25.tar.bz2")
    }
}

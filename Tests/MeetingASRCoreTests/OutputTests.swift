import XCTest
@testable import MeetingASRCore

final class OutputTests: XCTestCase {
    func sample() -> Transcript {
        Transcript(
            title: "周会",
            createdAt: "2026-10-14T14:30:00+08:00",
            durationSec: 3605.2,
            speakers: [
                TranscriptSpeaker(id: "S1", track: .mic, personId: "p1", name: "李四", source: .auto),
                TranscriptSpeaker(id: "S2", track: .system),
            ],
            segments: [
                TranscriptSegment(speaker: "S2", start: 12.34, end: 18.9, text: "我们先过一下上周的进度。"),
                TranscriptSegment(speaker: "S2", start: 19, end: 21, text: "先说前端。"),
                TranscriptSegment(speaker: "S1", start: 21.5, end: 25, text: "前端已经完成。"),
                TranscriptSegment(speaker: "S2", start: 3700, end: 3701.5, text: "好的。"),
            ],
            pauses: [PauseMark(at: 30)]
        )
    }

    func testMarkdown() {
        let md = TranscriptWriter.markdown(sample())
        XCTAssertTrue(md.hasPrefix("# 周会\n"))
        XCTAssertTrue(md.contains("- 时长：01:00:05"))
        XCTAssertTrue(md.contains("- 说话人：S2、李四"))
        XCTAssertTrue(md.contains("**S2** `00:00:12 – 00:00:21`\n\n我们先过一下上周的进度。先说前端。"))
        XCTAssertTrue(md.contains("**李四** `00:00:21 – 00:00:25`"))
        let pauseRange = md.range(of: "（暂停）")!
        XCTAssertLessThan(md.range(of: "前端已经完成")!.lowerBound, pauseRange.lowerBound)
        XCTAssertLessThan(pauseRange.lowerBound, md.range(of: "好的。")!.lowerBound)
    }

    func testSRT() {
        let srt = TranscriptWriter.srt(sample())
        XCTAssertTrue(srt.hasPrefix("1\n00:00:12,340 --> 00:00:18,900\nS2：我们先过一下上周的进度。\n"))
        XCTAssertTrue(srt.contains("3\n00:00:21,500 --> 00:00:25,000\n李四：前端已经完成。"))
        XCTAssertTrue(srt.contains("01:01:40,000 --> 01:01:41,500"))
    }

    func testPlainText() {
        let txt = TranscriptWriter.plainText(sample())
        XCTAssertTrue(txt.hasPrefix("S2 [00:00:12]\n我们先过一下上周的进度。\n先说前端。\n\n李四 [00:00:21]"))
    }

    func testWriteAndVerify() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("masr-out-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = MeetingPaths(dir: dir)
        let t = sample()
        try TranscriptWriter.writeAll(t, to: m)
        XCTAssertTrue(TranscriptWriter.verify(t, at: m))
        var changed = t
        changed.title = "x"
        XCTAssertFalse(TranscriptWriter.verify(changed, at: m))
    }
}

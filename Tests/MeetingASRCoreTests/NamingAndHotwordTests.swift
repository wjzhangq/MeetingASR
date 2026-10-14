import XCTest
@testable import MeetingASRCore

final class NamingAndHotwordTests: XCTestCase {
    var layout: StorageLayout!
    var store: MeetingStore!
    var people: PeopleStore!
    var meeting: MeetingPaths!

    override func setUpWithError() throws {
        layout = StorageLayout(root: FileManager.default.temporaryDirectory.appendingPathComponent("masr-name-\(UUID().uuidString)"))
        try layout.ensureDirectories()
        store = MeetingStore(layout: layout)
        people = PeopleStore(layout: layout)
        meeting = layout.meeting(named: "2026-10-14_143000_周会")
        try store.saveMeta(MeetingMeta(title: "周会", createdAt: Date(), source: .recording, status: .done), meeting)
        let t = Transcript(
            title: "周会", createdAt: "2026-10-14T14:30:00+08:00", durationSec: 60,
            speakers: [
                TranscriptSpeaker(id: "S1", track: .mic),
                TranscriptSpeaker(id: "S2", track: .system),
                TranscriptSpeaker(id: "S3", track: .system),
            ],
            segments: [
                TranscriptSegment(speaker: "S1", start: 0, end: 5, text: "大家好。"),
                TranscriptSegment(speaker: "S2", start: 5, end: 9, text: "开始吧。"),
                TranscriptSegment(speaker: "S3", start: 9, end: 12, text: "好的。"),
            ]
        )
        try TranscriptWriter.writeAll(t, to: meeting)
        var recs: [SpeakerRecord] = []
        for (i, id) in ["S1", "S2", "S3"].enumerated() {
            let clip = "\(id)_01.wav"
            try WavWriter.writeMono([Float](repeating: 0.1, count: 16_000), sampleRate: 16_000, to: meeting.clip(clip))
            var e = [Float](repeating: 0, count: 4)
            e[i] = 1
            recs.append(SpeakerRecord(id: id, track: i == 0 ? .mic : .system, embedding: e, clips: [FeatureClip(file: clip, start: 0, end: 1, score: 1)]))
        }
        try JSONIO.write(SpeakersFile(matchThreshold: 0.6, speakers: recs), to: meeting.speakersJSON)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: layout.root)
    }

    func testAssignNewNameUpdatesAllOutputsAndLibrary() throws {
        let naming = SpeakerNaming(store: store, people: people)
        try naming.assign(name: "张三", to: "S2", in: meeting)
        let t = try store.loadTranscript(meeting)
        XCTAssertEqual(t.speaker("S2")?.name, "张三")
        XCTAssertEqual(t.speaker("S2")?.source, .user)
        let pid = try XCTUnwrap(t.speaker("S2")?.personId)
        XCTAssertTrue(try String(contentsOf: meeting.transcriptMarkdown, encoding: .utf8).contains("**张三**"))
        XCTAssertTrue(try String(contentsOf: meeting.transcriptSRT, encoding: .utf8).contains("张三：开始吧。"))
        XCTAssertEqual(people.person(id: pid)?.samples.count, 1)
        XCTAssertEqual(try store.loadSpeakers(meeting).record("S2")?.contributedTo, pid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.personDir(pid).appendingPathComponent("01.wav").path))
    }

    func testCorrectAutoMatchMovesSample() throws {
        let naming = SpeakerNaming(store: store, people: people)
        // 模拟自动识别把 S2 标成了李四
        let li = try people.findOrCreate(name: "李四")
        try people.addSample(personId: li.id, meeting: meeting.name, speaker: "S2", embedding: [0, 1, 0, 0], clipURLs: [], source: .auto)
        var t = try store.loadTranscript(meeting)
        t.speakers[1].personId = li.id; t.speakers[1].name = "李四"; t.speakers[1].source = .auto
        try TranscriptWriter.writeAll(t, to: meeting)

        let zhang = try people.findOrCreate(name: "张三")
        try naming.assign(personId: zhang.id, to: "S2", in: meeting)
        XCTAssertEqual(people.person(id: li.id)?.samples.count, 0, "撤销对原人物的贡献")
        XCTAssertEqual(people.person(id: zhang.id)?.samples.count, 1)
        XCTAssertEqual(try store.loadTranscript(meeting).speaker("S2")?.name, "张三")
    }

    func testMergeTwoLabelsWithSameName() throws {
        let naming = SpeakerNaming(store: store, people: people)
        try naming.assign(name: "王五", to: "S2", in: meeting)
        try naming.assign(name: "王五", to: "S3", in: meeting)
        let t = try store.loadTranscript(meeting)
        XCTAssertEqual(t.speaker("S2")?.personId, t.speaker("S3")?.personId)
        XCTAssertEqual(people.people.count, 1)
        XCTAssertEqual(people.people[0].samples.count, 2)
        // Markdown 中相邻两段同名显示
        let md = try String(contentsOf: meeting.transcriptMarkdown, encoding: .utf8)
        XCTAssertTrue(md.contains("- 说话人：S1、王五"))
    }

    func testClearAndMultiple() throws {
        let naming = SpeakerNaming(store: store, people: people)
        try naming.assign(name: "张三", to: "S1", in: meeting)
        try naming.clear("S1", in: meeting)
        var t = try store.loadTranscript(meeting)
        XCTAssertEqual(t.speaker("S1")?.name, "S1")
        XCTAssertEqual(t.speaker("S1")?.source, NameSource.none)
        XCTAssertNil(t.speaker("S1")?.personId)
        XCTAssertEqual(people.people[0].samples.count, 0)

        try naming.assign(name: "多人", to: "S3", in: meeting)
        t = try store.loadTranscript(meeting)
        XCTAssertEqual(t.speaker("S3")?.name, "多人")
        XCTAssertNil(people.person(named: "多人"))
        XCTAssertThrowsError(try naming.assign(name: "x", to: "S9", in: meeting))
    }

    func testRefreshNamesAfterRename() throws {
        let naming = SpeakerNaming(store: store, people: people)
        let t0 = try naming.assign(name: "张三", to: "S1", in: meeting)
        try people.rename(personId: t0.speaker("S1")!.personId!, to: "张叁")
        XCTAssertEqual(try store.loadTranscript(meeting).speaker("S1")?.name, "张三", "默认不回溯")
        XCTAssertEqual(try naming.refreshNames(in: meeting).speaker("S1")?.name, "张叁")
    }

    // MARK: 热词

    func testHotwordListParsing() {
        let l = HotwordList(text: "  星图平台\n#注释\n\nKubernetes\n星图平台\n")
        XCTAssertEqual(l.words, ["星图平台", "Kubernetes"])
        XCTAssertEqual(l.adding(["张三"]).words.last, "张三")
    }

    func testHotwordCorrectorChinese() {
        let c = HotwordCorrector(hotwords: HotwordList(words: ["星图平台", "鸿蒙", "张珊"]))
        XCTAssertEqual(c.correct("我们把新图平台上线了"), "我们把星图平台上线了")
        XCTAssertEqual(c.correct("红蒙系统"), "鸿蒙系统")
        XCTAssertEqual(c.correct("张山说可以"), "张珊说可以")
        // 不相关文本不改
        XCTAssertEqual(c.correct("今天天气不错"), "今天天气不错")
        // 模糊音：三字以上允许一个
        let fuzzy = HotwordCorrector(hotwords: HotwordList(words: ["数据中台"]))
        XCTAssertEqual(fuzzy.correct("苏据中台建设"), "数据中台建设")
    }

    func testHotwordCorrectorLatinAndTokens() {
        let c = HotwordCorrector(hotwords: HotwordList(words: ["Kubernetes", "GPT", "星图平台"]))
        XCTAssertEqual(c.correct("部署到kubernetes上，用 gpt 生成"), "部署到Kubernetes上，用 GPT 生成")
        XCTAssertEqual(c.correct("gpts"), "gpts")
        let tokens = "新图平台".map { TranscriptToken(t: String($0), start: 1) }
        XCTAssertEqual(c.correct(tokens: tokens).map(\.t).joined(), "星图平台")
    }
}

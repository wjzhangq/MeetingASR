import XCTest
@testable import MeetingASRCore

final class PeopleTests: XCTestCase {
    var layout: StorageLayout!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("masr-people-\(UUID().uuidString)")
        layout = StorageLayout(root: dir)
        try layout.ensureDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: layout.root)
    }

    func unit(_ i: Int, dim: Int = 8, noise: Float = 0) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        v[i] = 1
        if noise > 0 { v[(i + 1) % dim] = noise }
        return VectorMath.normalized(v)
    }

    func testHungarianMaximize() {
        let w: [[Double]] = [
            [0.9, 0.8, 0.1],
            [0.85, 0.2, 0.1],
        ]
        // 贪心会给第 0 行选 0 列，最优是 0→1、1→0
        XCTAssertEqual(Hungarian.maximize(w), [1, 0])
        XCTAssertEqual(Hungarian.maximize([[0.5], [0.9], [0.1]]), [nil, 0, nil])
        XCTAssertEqual(Hungarian.maximize([]), [])
    }

    func testMatcherOneToOneAndThreshold() {
        let a = Person(id: "pa", name: "张三", samples: [PersonSample(meeting: "m", speaker: "S1", embedding: unit(0))])
        let b = Person(id: "pb", name: "李四", samples: [PersonSample(meeting: "m", speaker: "S2", embedding: unit(1))])
        let matcher = SpeakerMatcher(threshold: 0.6)
        let r = matcher.match(speakers: [
            ("S1", unit(0, noise: 0.3)),
            ("S2", unit(0, noise: 0.5)), // 也像张三，但一对一只能分给一个
            ("S3", unit(5)),
        ], people: [a, b])
        XCTAssertEqual(r.assigned["S1"]?.personId, "pa")
        XCTAssertNil(r.assigned["S2"], "李四相似度不足阈值，不能硬分配")
        XCTAssertNil(r.assigned["S3"])
        XCTAssertEqual(r.best["S2"]?.personId, "pa")
        XCTAssertEqual(r.best.count, 3)
    }

    func testMatcherEmptyLibrary() {
        let r = SpeakerMatcher().match(speakers: [("S1", unit(0))], people: [])
        XCTAssertTrue(r.assigned.isEmpty)
    }

    func testMeanAggregation() {
        let p = Person(id: "p", name: "x", samples: [
            PersonSample(meeting: "m1", speaker: "S1", embedding: unit(0)),
            PersonSample(meeting: "m2", speaker: "S1", embedding: unit(1)),
        ])
        XCTAssertEqual(SpeakerMatcher(aggregation: .max).similarity(unit(0), to: p), 1, accuracy: 1e-6)
        XCTAssertEqual(SpeakerMatcher(aggregation: .mean).similarity(unit(0), to: p), 0.5, accuracy: 1e-6)
    }

    func makeClip(_ name: String) throws -> URL {
        let url = layout.root.appendingPathComponent("src/\(name)")
        try WavWriter.writeMono([Float](repeating: 0.1, count: 1600), sampleRate: 16_000, to: url)
        return url
    }

    func testPeopleStoreAddRevokeAndCap() throws {
        let store = PeopleStore(layout: layout, maxSamplesPerPerson: 2)
        let zhang = try store.findOrCreate(name: " 张三 ")
        XCTAssertEqual(zhang.name, "张三")
        XCTAssertEqual(try store.findOrCreate(name: "张三").id, zhang.id)
        let clip = try makeClip("S1_01.wav")

        try store.addSample(personId: zhang.id, meeting: "m1", speaker: "S1", embedding: unit(0), clipURLs: [clip], source: .user, at: Date(timeIntervalSince1970: 1))
        try store.addSample(personId: zhang.id, meeting: "m2", speaker: "S2", embedding: unit(0), clipURLs: [clip], source: .auto, at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(store.person(id: zhang.id)?.samples.map(\.clips), [["01.wav"], ["02.wav"]])
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.personDir(zhang.id).appendingPathComponent("01.wav").path))

        // 超过上限淘汰最旧样本及其片段
        try store.addSample(personId: zhang.id, meeting: "m3", speaker: "S1", embedding: unit(0), clipURLs: [clip], source: .user, at: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(store.person(id: zhang.id)?.samples.map(\.meeting), ["m2", "m3"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.personDir(zhang.id).appendingPathComponent("01.wav").path))

        // 改正：撤销 m2/S2 在张三处的贡献，加入李四
        let li = try store.findOrCreate(name: "李四")
        XCTAssertEqual(store.sampleOwner(meeting: "m2", speaker: "S2"), zhang.id)
        try store.addSample(personId: li.id, meeting: "m2", speaker: "S2", embedding: unit(1), clipURLs: [clip], source: .user)
        XCTAssertEqual(store.person(id: zhang.id)?.samples.map(\.meeting), ["m3"])
        XCTAssertEqual(store.sampleOwner(meeting: "m2", speaker: "S2"), li.id)
        XCTAssertEqual(try store.removeSample(meeting: "m2", speaker: "S2"), li.id)
        XCTAssertNil(store.sampleOwner(meeting: "m2", speaker: "S2"))

        // 持久化
        let reloaded = PeopleStore(layout: layout)
        XCTAssertEqual(reloaded.people.count, 2)
        XCTAssertEqual(reloaded.snapshot().embeddingModel, EmbeddingModel.current)
    }

    func testSuggestionsRenameMergeDelete() throws {
        let store = PeopleStore(layout: layout)
        let a = try store.findOrCreate(name: "张三")
        _ = try store.findOrCreate(name: "张三丰")
        let c = try store.findOrCreate(name: "小张")
        XCTAssertEqual(store.suggestions(for: "张").map(\.name), ["张三", "张三丰", "小张"])
        XCTAssertEqual(store.suggestions(for: "三丰").map(\.name), ["张三丰"])
        try store.rename(personId: c.id, to: "张小")
        XCTAssertEqual(store.person(id: c.id)?.name, "张小")

        let clip = try makeClip("x.wav")
        try store.addSample(personId: c.id, meeting: "m1", speaker: "S1", embedding: unit(0), clipURLs: [clip], source: .user)
        try store.merge(c.id, into: a.id)
        XCTAssertNil(store.person(id: c.id))
        XCTAssertEqual(store.person(id: a.id)?.samples.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.personDir(a.id).appendingPathComponent("01.wav").path))
        try store.delete(personId: a.id)
        XCTAssertNil(store.person(id: a.id))
        XCTAssertThrowsError(try store.findOrCreate(name: "  "))
    }

    func testReembed() throws {
        let store = PeopleStore(layout: layout)
        let a = try store.findOrCreate(name: "A")
        try store.addSample(personId: a.id, meeting: "m", speaker: "S1", embedding: unit(0), clipURLs: [try makeClip("c.wav")], source: .user)
        try store.reembedAll(modelName: "new-model") { _ in [0, 3, 4] }
        XCTAssertEqual(store.snapshot().embeddingModel, "new-model")
        XCTAssertEqual(store.person(id: a.id)?.samples[0].embedding ?? [], [0, 0.6, 0.8])
    }

    func testClipSelection() {
        func seg(_ s: Double, _ e: Double, overlap: Double = 0, echo: Bool = false) -> ASRSegment {
            var x = ASRSegment(speaker: "S1", track: .system, start: s, end: e, cropStart: s, cropEnd: e)
            x.overlapRatio = overlap
            x.isEcho = echo
            return x
        }
        let sel = ClipSelector(count: 3, minSec: 3, maxSec: 8)
        let cands = sel.candidates(from: [
            seg(0, 20),            // 切成 3 个约 6.7 秒的窗口
            seg(100, 104),
            seg(200, 210, overlap: 0.5),
            seg(300, 306, echo: true),
            seg(400, 401.5),       // 短段只作后备
        ])
        XCTAssertEqual(cands.count, 4)
        XCTAssertTrue(cands.allSatisfy { $0.duration <= 8 && $0.duration >= 3 })
        // 分数最高的两个都在 0~20 秒，分散度要求让第二个从 100 秒取
        let picked = sel.select(cands, scores: [0.9, 0.85, 0.8, 0.5], meetingDuration: 600)
        XCTAssertEqual(picked.map { $0.0.start }, [0, cands[1].start, 100])

        let fallback = sel.candidates(from: [seg(0, 1.5), seg(5, 7), seg(10, 15, overlap: 0.6)])
        XCTAssertEqual(fallback.first, ClipCandidate(start: 10, end: 15))
        XCTAssertEqual(fallback.count, 3)
    }

    func testClipScore() {
        XCTAssertEqual(ClipSelector.score(similarity: 0.8, snrDB: 30), 0.8, accuracy: 1e-9)
        XCTAssertEqual(ClipSelector.score(similarity: 0.8, snrDB: 0), 0.4, accuracy: 1e-9)
    }
}

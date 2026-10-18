import XCTest
@testable import MeetingASRCore

// MARK: - 模拟引擎
// 用不同频率的正弦"语音"代表不同说话人：声纹 = 主频所在频带的 one-hot。

private func dominantBand(_ x: [Float]) -> Int {
    // 只按有声样本估计频率（帧可能跨越静音）
    var crossings = 0, active = 0
    for i in 1..<max(1, x.count) where abs(x[i]) > 1e-4 || abs(x[i - 1]) > 1e-4 {
        active += 1
        if (x[i - 1] < 0) != (x[i] < 0) { crossings += 1 }
    }
    guard active > 0 else { return 0 }
    let freq = Double(crossings) / 2 / (Double(active) / 16_000)
    return min(7, Int(freq / 100))
}

private final class MockASR: SpeechRecognizer {
    var modelName = "mock-asr"
    var calls = 0
    /// 有声部分每 0.25 秒输出一个字（循环"新图平台"），带字级时间戳
    func recognize(_ samples: [Float]) -> RecognitionResult {
        calls += 1
        let chars = Array("新图平台")
        let frame = 4000
        var tokens: [TranscriptToken] = []
        var i = 0
        while i + frame <= samples.count {
            if SignalStats.rms(Array(samples[i..<(i + frame)])) > 0.01 {
                tokens.append(TranscriptToken(t: String(chars[tokens.count % chars.count]), start: Double(i) / 16_000 + 0.1))
            }
            i += frame
        }
        return RecognitionResult(text: tokens.map(\.t).joined(), tokens: tokens)
    }
}

private final class MockPunct: Punctuator {
    func punctuate(_ text: String) -> String { text + "。" }
}

/// 以 0.5 秒为帧，按能量与主频切分并聚类。
private final class MockDiarizer: SpeakerDiarizer {
    var lastOptions: DiarizationOptions?
    var calls = 0
    func diarize(_ samples: [Float], options: DiarizationOptions, progress: @escaping (Double) -> Bool) -> [RawSpan] {
        lastOptions = options
        calls += 1
        let frame = 8000
        var spans: [RawSpan] = []
        var i = 0
        while i + frame <= samples.count {
            let f = Array(samples[i..<(i + frame)])
            if SignalStats.rms(f) > 0.01 {
                let spk = "\(dominantBand(f))"
                let t = Double(i) / 16_000
                if let last = spans.last, last.speaker == spk, abs(last.end - t) < 1e-6 {
                    spans[spans.count - 1].end = t + 0.5
                } else {
                    spans.append(RawSpan(speaker: spk, start: t, end: t + 0.5))
                }
            }
            i += frame
            if !progress(Double(i) / Double(samples.count)) { return [] }
        }
        return spans
    }
}

private final class MockEmbedder: SpeakerEmbedder {
    var modelName = EmbeddingModel.current
    func embed(_ samples: [Float]) -> [Float]? {
        guard samples.count > 8000 else { return nil }
        var v = [Float](repeating: 0.01, count: 8)
        v[dominantBand(samples)] = 1
        return VectorMath.normalized(v)
    }
}

private final class MockVAD: VoiceActivityDetector {
    func detect(_ samples: [Float]) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        let frame = 1600
        var start: Double?
        var i = 0
        while i < samples.count {
            let active = SignalStats.rms(Array(samples[i..<min(samples.count, i + frame)])) > 0.01
            let t = Double(i) / 16_000
            if active, start == nil { start = t }
            if !active, let s = start { out.append(s...t); start = nil }
            i += frame
        }
        if let s = start { out.append(s...Double(samples.count) / 16_000) }
        return out
    }
}

final class PipelineTests: XCTestCase {
    var layout: StorageLayout!

    override func setUpWithError() throws {
        layout = StorageLayout(root: FileManager.default.temporaryDirectory.appendingPathComponent("masr-pipe-\(UUID().uuidString)"))
        try layout.ensureDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: layout.root)
    }

    func engines() -> EngineSet {
        EngineSet(recognizer: MockASR(), punctuator: MockPunct(), diarizer: MockDiarizer(), embedder: MockEmbedder(), vad: MockVAD())
    }

    /// 生成音轨：给定 (起, 止, 频率) 区间
    func track(rate: Int, seconds: Double, parts: [(Double, Double, Double)], amp: Float = 0.3) -> [Float] {
        var x = [Float](repeating: 0, count: Int(seconds * Double(rate)))
        for (s, e, f) in parts {
            for i in Int(s * Double(rate))..<min(x.count, Int(e * Double(rate))) {
                x[i] = amp * Float(sin(2 * Double.pi * f * Double(i) / Double(rate)))
            }
        }
        return x
    }

    /// 创建一场双轨录音会议（48k 系统轨 + 48k 麦克风轨）
    func makeRecording(title: String, mic: [(Double, Double, Double)], system: [(Double, Double, Double)], micEchoOf: [(Double, Double, Double)] = []) throws -> MeetingPaths {
        let (m, meta0) = try MeetingFactory.createRecordingMeeting(title: title, expectedSpeakers: nil, layout: layout)
        var meta = meta0
        let sys = track(rate: 48_000, seconds: 40, parts: system)
        var micT = track(rate: 48_000, seconds: 40, parts: mic)
        // 回声：系统声音衰减后串入麦克风
        let echo = track(rate: 48_000, seconds: 40, parts: micEchoOf, amp: 0.3 * 0.2)
        for i in micT.indices { micT[i] += echo[i] }
        try WavWriter.writeMono(sys, sampleRate: 48_000, to: m.rawTrack(.system))
        try WavWriter.writeMono(micT, sampleRate: 48_000, to: m.rawTrack(.mic))
        meta.tracks = [
            TrackInfo(kind: .mic, file: ".raw/mic.wav", sampleRate: 48_000, channels: 1, firstHostTime: 1000),
            TrackInfo(kind: .system, file: ".raw/system.wav", sampleRate: 48_000, channels: 1, firstHostTime: 1000),
        ]
        meta.pauses = [PauseInterval(audioOffset: 20, pausedAt: Date(), resumedAt: Date())]
        meta.durationSec = 40
        meta.status = .pending
        try JSONIO.write(meta, to: m.meta)
        return m
    }

    func testFullPipelineTwoTracksThenAutoMatch() throws {
        try runFullPipeline()
    }

    func runFullPipeline() throws {
        let store = MeetingStore(layout: layout)
        let people = PeopleStore(layout: layout)
        var opts = ProcessingOptions()
        opts.recognition.recognitionMode = .segmentStream
        opts.hotwords = HotwordList(words: ["星图平台"])
        let proc = MeetingProcessor(engines: engines(), store: store, people: people, options: opts)

        // 本人 250Hz；远端 A 450Hz、B 650Hz；第 30~34 秒远端 A 的声音外放串入麦克风
        let m1 = try makeRecording(
            title: "周会",
            mic: [(1, 5, 250), (14, 18, 250), (26, 29.5, 250)],
            system: [(6, 12, 450), (19, 24, 650), (30, 34, 450), (35, 39, 650)],
            micEchoOf: [(30, 34, 450)]
        )
        var stages: [ProcessingStage] = []
        let t = try proc.process(m1) { p in if stages.last != p.stage { stages.append(p.stage) } }

        XCTAssertEqual(stages, [.preprocess, .diarization, .recognition, .speakerID, .output, .cleanup])
        XCTAssertEqual(t.speakers.map(\.id), ["S1", "S2", "S3"])
        XCTAssertEqual(t.speakers.map(\.track), [.mic, .system, .system])
        XCTAssertTrue(t.speakers.allSatisfy { $0.source == .none })
        XCTAssertEqual(t.segments.first?.speaker, "S1")
        XCTAssertEqual(t.segments.first?.start ?? 0, 1, accuracy: 0.2)
        // 回声段被丢弃：30~34 秒只有一个说话人
        XCTAssertEqual(t.segments.filter { $0.start >= 29.6 && $0.start < 34 }.map(\.speaker), ["S2"])
        // 热词纠错 + 标点 + 全局时间戳
        XCTAssertTrue(t.segments[0].text.hasPrefix("星图平台"))
        XCTAssertTrue(t.segments[0].text.hasSuffix("。"))
        XCTAssertEqual(t.segments[0].tokens?.first?.t, "星")
        XCTAssertGreaterThan(t.segments[0].tokens?.first?.start ?? 0, 0.8)
        XCTAssertEqual(t.pauses, [PauseMark(at: 20)])

        // 原始音频已删除，只保留结果和特征片段
        XCTAssertFalse(FileManager.default.fileExists(atPath: m1.rawDir.path))
        let meta = try store.loadMeta(m1)
        XCTAssertEqual(meta.status, .done)
        XCTAssertNotNil(meta.rawDeletedAt)
        let sp = try store.loadSpeakers(m1)
        XCTAssertEqual(sp.speakers.count, 3)
        for r in sp.speakers {
            XCTAssertFalse(r.clips.isEmpty)
            XCTAssertEqual(VectorMath.norm(r.embedding), 1, accuracy: 1e-4)
            for c in r.clips {
                XCTAssertTrue(FileManager.default.fileExists(atPath: m1.clip(c.file).path))
                XCTAssertGreaterThanOrEqual(c.end - c.start, 2.9)
            }
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: m1.dir.path).sorted()
        XCTAssertEqual(files, ["meta.json", "speakers", "transcript.json", "transcript.md", "transcript.srt"])
        XCTAssertTrue(try String(contentsOf: m1.transcriptMarkdown, encoding: .utf8).contains("（暂停）"))

        // 用户命名
        let naming = SpeakerNaming(store: store, people: people)
        try naming.assign(name: "我", to: "S1", in: m1)
        try naming.assign(name: "张三", to: "S2", in: m1)

        // 第二场会议：张三（450Hz）应被自动识别，650Hz 的人仍未命名
        let m2 = try makeRecording(title: "复盘", mic: [(1, 6, 250)], system: [(8, 14, 650), (16, 24, 450)])
        let t2 = try proc.process(m2)
        let zhang = try XCTUnwrap(t2.speakers.first { $0.name == "张三" })
        XCTAssertEqual(zhang.source, .auto)
        XCTAssertEqual(t2.speakers.first { $0.name == "我" }?.track, .mic)
        XCTAssertEqual(t2.speakers.filter { $0.source == .none }.count, 1)
        // 自动识别结果作为样本加入人物库
        XCTAssertEqual(people.person(named: "张三")?.samples.count, 2)

        // 改正：其实是王五 → 撤销张三的样本
        try naming.assign(name: "王五", to: zhang.id, in: m2)
        XCTAssertEqual(people.person(named: "张三")?.samples.count, 1)
        XCTAssertEqual(people.person(named: "王五")?.samples.count, 1)
    }

    func testSingleTrackFileWithRangeAndExpectedSpeakers() throws {
        try runSingleTrack()
    }

    func runSingleTrack() throws {
        let src = layout.root.appendingPathComponent("input/访谈.wav")
        try WavWriter.writeMono(track(rate: 16_000, seconds: 30, parts: [(0, 8, 250), (9, 15, 450), (16, 29, 250)]), sampleRate: 16_000, to: src)
        let m = try MeetingFactory.createFileMeeting(source: src, range: 5...20, expectedSpeakers: 2, layout: layout)
        XCTAssertTrue(m.name.hasSuffix("_访谈"))
        let e = engines()
        var opts = ProcessingOptions()
        opts.recognition.recognitionMode = .segmentStream
        let proc = MeetingProcessor(engines: e, store: MeetingStore(layout: layout), people: PeopleStore(layout: layout), options: opts)
        let t = try proc.process(m)
        XCTAssertEqual((e.diarizer as! MockDiarizer).lastOptions?.numSpeakers, 2)
        XCTAssertEqual(t.durationSec, 15, accuracy: 0.01)
        XCTAssertEqual(t.speakers.map(\.track), [.file, .file])
        XCTAssertEqual(t.segments.map(\.speaker), ["S1", "S2", "S1"])
        XCTAssertEqual(t.segments[1].start, 4, accuracy: 0.01)
        // 用户的源文件不能被删除
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: m.rawDir.path))
    }

    func testLongAudioDiarizedInBlocks() throws {
        // 30 秒音频按 8 秒分块：两人交替发言，跨块后仍统一为 2 位说话人
        let src = layout.root.appendingPathComponent("input/长会.wav")
        let parts: [(Double, Double, Double)] = stride(from: 0.0, to: 30, by: 3).map { ($0, $0 + 2.5, Int($0 / 3) % 2 == 0 ? 250 : 450) }
        try WavWriter.writeMono(track(rate: 16_000, seconds: 30, parts: parts), sampleRate: 16_000, to: src)
        let m = try MeetingFactory.createFileMeeting(source: src, range: nil, expectedSpeakers: nil, layout: layout)
        var opts = ProcessingOptions()
        opts.blockDiarization.blockSec = 8
        opts.blockDiarization.searchSec = 2
        let e = engines()
        let proc = MeetingProcessor(engines: e, store: MeetingStore(layout: layout), people: PeopleStore(layout: layout), options: opts)
        let t = try proc.process(m)
        XCTAssertEqual(t.speakers.map(\.id), ["S1", "S2"])
        XCTAssertEqual(t.segments.count, 10)
        XCTAssertEqual(t.segments.map(\.speaker), (0..<10).map { $0 % 2 == 0 ? "S1" : "S2" })
        // 分块时不向每块传入人数
        XCTAssertNil((e.diarizer as! MockDiarizer).lastOptions?.numSpeakers)
    }

    func testReusesBlocksDiarizedDuringRecording() throws {
        // 32 秒单轨录音按 8 秒分块（切在约 8.7、17.7、26.7 秒）：录音期间已分离的块直接复用，识别时只分离剩余部分
        let (m, meta0) = try MeetingFactory.createRecordingMeeting(title: "长会", expectedSpeakers: nil, layout: layout)
        let parts: [(Double, Double, Double)] = stride(from: 0.0, to: 32, by: 3).map { ($0, $0 + 2.5, Int($0 / 3) % 2 == 0 ? 250 : 450) }
        try WavWriter.writeMono(track(rate: 48_000, seconds: 32, parts: parts), sampleRate: 48_000, to: m.rawTrack(.mic))
        var meta = meta0
        meta.tracks = [TrackInfo(kind: .mic, file: ".raw/mic.wav", sampleRate: 48_000, channels: 1, firstHostTime: 1000)]
        meta.durationSec = 32
        meta.status = .pending
        try JSONIO.write(meta, to: m.meta)

        var opts = ProcessingOptions()
        opts.blockDiarization.blockSec = 8
        opts.blockDiarization.searchSec = 2
        let e = engines()
        let key = DiarizationCache.Key(track: .mic, recognition: opts.recognition, config: opts.blockDiarization, models: e.models)
        let live = LiveDiarizer(source: m.rawTrack(.mic), cacheURL: DiarizationCache.url(m, track: .mic), key: key,
                                recognition: opts.recognition, diarizer: e.diarizer, config: opts.blockDiarization)
        let liveBlocks = try live.step()
        XCTAssertEqual(liveBlocks, 3)
        let mock = e.diarizer as! MockDiarizer
        XCTAssertEqual(mock.calls, 3)

        let proc = MeetingProcessor(engines: e, store: MeetingStore(layout: layout), people: PeopleStore(layout: layout), options: opts)
        let t = try proc.process(m)
        // 识别时只分离了最后一块
        XCTAssertEqual(mock.calls, 4)
        XCTAssertEqual(t.speakers.map(\.id), ["S1", "S2"])
        XCTAssertEqual(t.segments.count, 11)
        XCTAssertEqual(t.segments.map(\.speaker), (0..<11).map { $0 % 2 == 0 ? "S1" : "S2" })
        // 缓存随原始音频一起删除
        XCTAssertFalse(FileManager.default.fileExists(atPath: m.rawDir.path))
    }

    func testCancellationKeepsRawAudio() throws {
        let store = MeetingStore(layout: layout)
        let m = try makeRecording(title: "取消", mic: [(1, 5, 250)], system: [(6, 12, 450)])
        let proc = MeetingProcessor(engines: engines(), store: store, people: PeopleStore(layout: layout), options: ProcessingOptions())
        let flag = CancellationFlag()
        XCTAssertThrowsError(try proc.process(m, cancel: flag) { p in if p.stage == .diarization { flag.cancel() } }) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(try store.loadMeta(m).status, .cancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: m.rawTrack(.mic).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: m.workDir.path))
        XCTAssertEqual(store.unfinishedMeetings().map(\.paths), [m])
        // 重试成功
        _ = try proc.process(m)
        XCTAssertEqual(try store.loadMeta(m).status, .done)
        XCTAssertTrue(store.unfinishedMeetings().isEmpty)
    }

    func testFailureMarksMeetingFailed() throws {
        let store = MeetingStore(layout: layout)
        let (m, _) = try MeetingFactory.createRecordingMeeting(title: "坏", expectedSpeakers: nil, layout: layout)
        try store.updateMeta(m) { $0.tracks = [TrackInfo(kind: .mic, file: ".raw/mic.wav", sampleRate: 48_000, channels: 1)] }
        let proc = MeetingProcessor(engines: engines(), store: store, people: PeopleStore(layout: layout), options: ProcessingOptions())
        XCTAssertThrowsError(try proc.process(m))
        let meta = try store.loadMeta(m)
        XCTAssertEqual(meta.status, .failed)
        XCTAssertNotNil(meta.error)
    }

    func testQueueRunsSeriallyAndReportsEvents() throws {
        let m1 = try makeRecording(title: "q1", mic: [(1, 5, 250)], system: [(6, 12, 450)])
        let m2 = try makeRecording(title: "q2", mic: [(1, 5, 250)], system: [(6, 12, 450)])
        let done = expectation(description: "both finished")
        done.expectedFulfillmentCount = 2
        let log = EventLog()
        let layout = self.layout!
        let e = engines()
        let queue = ProcessingQueue(makeProcessor: {
            MeetingProcessor(engines: e, store: MeetingStore(layout: layout), people: PeopleStore(layout: layout), options: ProcessingOptions())
        }) { ev in
            log.append(ev)
            if case .finished = ev { done.fulfill() }
        }
        queue.enqueue(m1)
        queue.enqueue(m2)
        queue.enqueue(m2) // 重复入队忽略
        wait(for: [done], timeout: 60)
        let starts = log.events.compactMap { if case .started(let m) = $0 { return m.name } else { return nil } }
        XCTAssertEqual(starts, [m1.name, m2.name])
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [ProcessingEvent] = []
    func append(_ e: ProcessingEvent) { lock.lock(); _events.append(e); lock.unlock() }
    var events: [ProcessingEvent] { lock.lock(); defer { lock.unlock() }; return _events }
}

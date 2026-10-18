import XCTest
@testable import MeetingASRCore

private final class ChunkVAD: StreamingVAD {
    private var pending: [ClosedRange<Double>] = []
    private var clock = 0.0
    private let sampleRate: Int

    init(sampleRate: Int = 16_000) { self.sampleRate = sampleRate }

    func accept(_ samples: [Float]) {
        let start = clock
        clock += Double(samples.count) / Double(sampleRate)
        if SignalStats.rms(samples) > 0.01 {
            pending.append(start...clock)
        }
    }

    func next() -> ClosedRange<Double>? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    func flush() {}

    func reset() {
        pending.removeAll()
        clock = 0
    }
}

private final class FixedASR: SpeechRecognizer {
    var modelName = "mock-asr"
    var calls = 0
    let gate = NSCondition()
    var hold = false

    func recognize(_ samples: [Float]) -> RecognitionResult {
        gate.lock()
        calls += 1
        while hold { gate.wait() }
        gate.unlock()
        return RecognitionResult(text: "实时", tokens: [TranscriptToken(t: "实", start: 0.05)])
    }

    func release() {
        gate.lock()
        hold = false
        gate.broadcast()
        gate.unlock()
    }
}

private final class FixedEmbedder: SpeakerEmbedder {
    var modelName = "mock-embed"
    func embed(_ samples: [Float]) -> [Float]? {
        guard samples.count >= 8_000 else { return nil }
        return [1, 0, 0, 0, 0, 0, 0, 0]
    }
}

private final class PassthroughVAD: VoiceActivityDetector {
    func detect(_ samples: [Float]) -> [ClosedRange<Double>] {
        samples.isEmpty ? [] : [0...Double(samples.count) / 16_000]
    }
}

final class LiveRecognitionTests: XCTestCase {
    private func makeCoordinator(
        meeting: MeetingPaths,
        asr: FixedASR,
        maxQueued: Int = 2,
        maxPending: Int = 4
    ) throws -> LiveSegmentCoordinator {
        try LiveSegmentCoordinator(
            meeting: meeting,
            tracks: [.mic],
            asrModel: asr.modelName,
            embeddingModel: "mock-embed",
            makeVAD: { _ in ChunkVAD() },
            recognizer: asr,
            embedder: FixedEmbedder(),
            embeddingTracks: [.mic],
            maxQueued: maxQueued,
            maxPending: maxPending
        )
    }

    func testClosedSegmentsAreLoggedAndReused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("masr-live-\(UUID().uuidString)")
        let layout = StorageLayout(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let (meeting, _) = try MeetingFactory.createRecordingMeeting(title: "实时", expectedSpeakers: nil, layout: layout)
        let asr = FixedASR()
        let coordinator = try makeCoordinator(meeting: meeting, asr: asr)
        let speech = [Float](repeating: 0.2, count: 16_000)
        let silence = [Float](repeating: 0, count: 16_000)
        coordinator.accept(track: .mic, samples: speech, sessionStart: 0)
        coordinator.accept(track: .mic, samples: silence, sessionStart: 1)
        coordinator.accept(track: .mic, samples: speech, sessionStart: 2)
        coordinator.finish()

        let key = SegmentLogKey(track: .mic, vadConfig: SegmentVADConfig(), asrModel: "mock-asr", embeddingModel: "mock-embed")
        let logged = SegmentLog.usableSegments(meeting: meeting, track: .mic, key: key)
        XCTAssertEqual(logged.count, 2)
        XCTAssertEqual(logged.map(\.text), ["实时", "实时"])
        XCTAssertEqual(SegmentLog.coveredUntil(meeting: meeting, track: .mic, key: key), 3, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(logged[1].speechStart, 1.9)

        let audio = speech + silence + speech
        try WavWriter.writeMono(audio, sampleRate: 16_000, to: meeting.rawTrack(.mic))
        var meta = try JSONIO.read(MeetingMeta.self, from: meeting.meta)
        meta.tracks = [TrackInfo(kind: .mic, file: ".raw/mic.wav", sampleRate: 16_000, channels: 1, firstHostTime: 1000)]
        meta.durationSec = 3
        meta.status = .pending
        try JSONIO.write(meta, to: meeting.meta)

        let callsBefore = asr.calls
        let store = MeetingStore(layout: layout)
        let people = PeopleStore(layout: layout)
        var options = ProcessingOptions()
        options.recognition.recognitionMode = .segmentStream
        let engines = EngineSet(
            recognizer: asr, punctuator: nil, diarizer: IdleDiarizer(), embedder: FixedEmbedder(), vad: PassthroughVAD())
        let processor = MeetingProcessor(engines: engines, store: store, people: people, options: options)
        let transcript = try processor.process(meeting)
        XCTAssertEqual(asr.calls, callsBefore, "覆盖完整的段日志不应再跑 ASR")
        XCTAssertTrue(transcript.segments.contains { $0.text.contains("实") })
    }

    func testFullQueueLeavesTheTailForLater() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("masr-live-stall-\(UUID().uuidString)")
        let layout = StorageLayout(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let (meeting, _) = try MeetingFactory.createRecordingMeeting(title: "积压", expectedSpeakers: nil, layout: layout)
        let asr = FixedASR()
        asr.hold = true
        let coordinator = try makeCoordinator(meeting: meeting, asr: asr, maxQueued: 1, maxPending: 0)
        let speech = [Float](repeating: 0.2, count: 16_000)
        coordinator.accept(track: .mic, samples: speech, sessionStart: 0)
        coordinator.accept(track: .mic, samples: speech, sessionStart: 1)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { asr.release() }
        coordinator.finish()

        let key = SegmentLogKey(track: .mic, vadConfig: SegmentVADConfig(), asrModel: "mock-asr", embeddingModel: "mock-embed")
        let logged = SegmentLog.usableSegments(meeting: meeting, track: .mic, key: key)
        XCTAssertEqual(logged.count, 1)
        XCTAssertLessThan(SegmentLog.coveredUntil(meeting: meeting, track: .mic, key: key), 1.8)
    }
}

/// 测试里不需要真正的分离器。
private final class IdleDiarizer: SpeakerDiarizer {
    func diarize(_ samples: [Float], options: DiarizationOptions, progress: @escaping (Double) -> Bool) -> [RawSpan] {
        _ = progress(1)
        return []
    }
}

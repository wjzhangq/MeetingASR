import XCTest
@testable import MeetingASRCore

final class RecordingTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("masr-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testClockPauseResume() {
        let c = SessionClock()
        XCTAssertNil(c.sessionTime(atHost: 0))
        c.start(at: 100)
        XCTAssertEqual(c.sessionTime(atHost: 110), 10)
        XCTAssertEqual(c.pause(at: 120), 20)
        XCTAssertNil(c.sessionTime(atHost: 125))
        XCTAssertEqual(c.elapsed(now: 200), 20)
        c.resume(at: 200)
        XCTAssertEqual(c.sessionTime(atHost: 205), 25)
        XCTAssertEqual(c.stop(at: 210), 30)
        XCTAssertEqual(c.state, .idle)
    }

    /// 每 0.1 秒一个缓冲（1600 帧 @16k）
    func feed(_ w: AlignedTrackWriter, from: Double, to: Double, value: Float) {
        var t = from
        while t < to - 1e-9 {
            w.append([Float](repeating: value, count: 1600), hostTime: t)
            t += 0.1
        }
    }

    func testTwoTracksStayAlignedAcrossPauseAndDropout() throws {
        let clock = SessionClock()
        clock.start(at: 1000)
        let mic = try AlignedTrackWriter(kind: .mic, url: dir.appendingPathComponent("mic.wav"), sampleRate: 16_000, clock: clock)
        let sys = try AlignedTrackWriter(kind: .system, url: dir.appendingPathComponent("system.wav"), sampleRate: 16_000, clock: clock)

        // 麦克风从 1000 开始；系统轨晚 0.5 秒才有首帧
        feed(mic, from: 1000, to: 1010, value: 0.1)
        feed(sys, from: 1000.5, to: 1004, value: 0.2)
        // 系统轨 1004~1006 断流（会议软件重启），之后恢复
        feed(sys, from: 1006, to: 1010, value: 0.2)
        // 暂停 1010~1100：期间的数据全部丢弃
        clock.pause(at: 1010)
        feed(mic, from: 1010, to: 1020, value: 0.9)
        feed(sys, from: 1010, to: 1020, value: 0.9)
        clock.resume(at: 1100)
        feed(mic, from: 1100, to: 1105, value: 0.1)
        feed(sys, from: 1100, to: 1105, value: 0.2)
        clock.stop(at: 1105)

        XCTAssertEqual(mic.firstHostTime, 1000)
        XCTAssertEqual(sys.firstHostTime, 1000.5)
        try mic.close(); try sys.close()
        let m = try WavReader(url: mic.url)
        let s = try WavReader(url: sys.url)
        XCTAssertEqual(m.durationSec, 15, accuracy: 0.01)
        // 系统轨从 0.5 秒开始（偏移由首帧主机时间给出），总长 14.5 秒
        XCTAssertEqual(s.durationSec, 14.5, accuracy: 0.01)
        let sAll = s.readAllMono()
        // 断流区间（会话时间 4~6 秒 → 系统轨文件 3.5~5.5 秒）为静音
        XCTAssertEqual(SignalStats.rms(Array(sAll[Int(3.6 * 16_000)..<Int(5.4 * 16_000)])), 0)
        XCTAssertEqual(sAll[Int(6 * 16_000)], 0.2, accuracy: 1e-3)
        // 暂停期间的 0.9 没有写入
        XCTAssertLessThan(m.readAllMono().max()!, 0.5)
    }

    func testOverlapIsTrimmed() throws {
        let clock = SessionClock()
        clock.start(at: 0)
        let w = try AlignedTrackWriter(kind: .mic, url: dir.appendingPathComponent("a.wav"), sampleRate: 16_000, clock: clock)
        w.append([Float](repeating: 0.1, count: 16_000), hostTime: 0)
        // 时间戳回退 0.5 秒的重复数据
        w.append([Float](repeating: 0.1, count: 16_000), hostTime: 0.5)
        try w.close()
        XCTAssertEqual(try WavReader(url: w.url).durationSec, 1.5, accuracy: 0.001)
    }

    func testRecoverInterruptedRecording() throws {
        let layout = StorageLayout(root: dir)
        let store = MeetingStore(layout: layout)
        let (m, meta0) = try MeetingFactory.createRecordingMeeting(title: "崩溃", expectedSpeakers: nil, layout: layout)
        var meta = meta0
        meta.tracks = [
            TrackInfo(kind: .mic, file: ".raw/mic.wav", sampleRate: 16_000, channels: 1),
            TrackInfo(kind: .system, file: ".raw/system.wav", sampleRate: 16_000, channels: 1),
        ]
        meta.pauses = [PauseInterval(audioOffset: 1, pausedAt: Date())]
        try store.saveMeta(meta, m)
        // 只有麦克风轨写入了数据，且头部未回填
        let w = try WavWriter(url: m.rawTrack(.mic), sampleRate: 16_000)
        w.write([Float](repeating: 0.1, count: 32_000))
        let fixed = try XCTUnwrap(store.recoverInterruptedRecording(m))
        XCTAssertEqual(fixed.status, .pending)
        XCTAssertEqual(fixed.durationSec, 2, accuracy: 0.01)
        XCTAssertEqual(fixed.tracks.map(\.kind), [.mic])
        XCTAssertTrue(fixed.pauses.isEmpty)
        XCTAssertNil(try store.recoverInterruptedRecording(m))
        XCTAssertEqual(store.unfinishedMeetings().count, 1)
        try w.close()
    }
}

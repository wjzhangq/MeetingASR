import XCTest
@testable import MeetingASRCore

final class StorageTests: XCTestCase {
    func makeTempLayout() throws -> StorageLayout {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("masr-\(UUID().uuidString)")
        let layout = StorageLayout(root: dir)
        try layout.ensureDirectories()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return layout
    }

    func testMeetingDirName() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 10; comps.day = 14; comps.hour = 14; comps.minute = 30; comps.second = 0
        let date = Calendar.current.date(from: comps)!
        XCTAssertEqual(StorageLayout.meetingDirName(date: date, title: "周会"), "2026-10-14_143000_周会")
        XCTAssertEqual(StorageLayout.meetingDirName(date: date, title: ""), "2026-10-14_143000")
        XCTAssertEqual(StorageLayout.meetingDirName(date: date, title: "a/b:c"), "2026-10-14_143000_a_b_c")
    }

    func testNewMeetingNameAvoidsCollision() throws {
        let layout = try makeTempLayout()
        let date = Date()
        let first = layout.newMeetingName(date: date, title: "x")
        try FileManager.default.createDirectory(at: layout.meeting(named: first).dir, withIntermediateDirectories: true)
        XCTAssertEqual(layout.newMeetingName(date: date, title: "x"), first + "-2")
    }

    func testTranscriptJSONShape() throws {
        let t = Transcript(
            title: "周会",
            createdAt: "2026-10-14T14:30:00+08:00",
            durationSec: 3605.2,
            speakers: [
                TranscriptSpeaker(id: "S1", track: .mic, personId: "p_8f2a", name: "李四", source: .auto),
                TranscriptSpeaker(id: "S3", track: .system),
            ],
            segments: [TranscriptSegment(speaker: "S1", start: 12.34, end: 18.9, text: "我们先过一下上周的进度。", tokens: [TranscriptToken(t: "我", start: 12.4)])]
        )
        let data = try JSONIO.encode(t)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["version"] as? Int, 2)
        XCTAssertNotNil(obj["created_at"])
        XCTAssertNotNil(obj["duration_sec"])
        let speakers = obj["speakers"] as! [[String: Any]]
        XCTAssertEqual(speakers[0]["person_id"] as? String, "p_8f2a")
        XCTAssertTrue(speakers[1]["person_id"] is NSNull, "未命名时 person_id 为 null")
        XCTAssertEqual(speakers[1]["name"] as? String, "S3")
        XCTAssertEqual(speakers[1]["source"] as? String, "none")
        let back = try JSONIO.makeDecoder().decode(Transcript.self, from: data)
        XCTAssertEqual(back, t)
    }

    func testMetaRoundTripAndRecentList() throws {
        let layout = try makeTempLayout()
        let store = MeetingStore(layout: layout)
        for i in 0..<12 {
            let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 100)
            let m = layout.meeting(named: layout.newMeetingName(date: date, title: "m\(i)"))
            var meta = MeetingMeta(title: "m\(i)", createdAt: date, source: .recording)
            meta.status = i == 11 ? .failed : .done
            try store.saveMeta(meta, m)
            if i == 11 { try FileManager.default.createDirectory(at: m.rawDir, withIntermediateDirectories: true) }
        }
        let recent = store.recentMeetings()
        XCTAssertEqual(recent.count, 10)
        XCTAssertEqual(recent.first?.title, "m11")
        XCTAssertEqual(store.latestCompleted()?.title, "m10")
        XCTAssertEqual(store.unfinishedMeetings().map(\.title), ["m11"])
        let loaded = try store.loadMeta(recent[0].paths)
        XCTAssertEqual(Int(loaded.createdAt.timeIntervalSince1970), 1_700_001_100)
    }

    func testSettingsBackwardCompatibleDecode() throws {
        let json = #"{"captureSource":"micOnly","recognition":{"matchThreshold":0.7}}"#
        let s = try JSONIO.makeDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.captureSource, .micOnly)
        XCTAssertEqual(s.recognition.matchThreshold, 0.7)
        XCTAssertEqual(s.recognition.clusterThreshold, 0.5)
        XCTAssertEqual(s.captureApps.count, CaptureApp.defaults.count)
    }

    func testCaptureAppMatchesHelpers() {
        let teams = CaptureApp.defaults[1]
        XCTAssertTrue(teams.matches(bundleID: "com.microsoft.teams2"))
        XCTAssertTrue(teams.matches(bundleID: "com.microsoft.teams2.helper.Renderer"))
        XCTAssertFalse(teams.matches(bundleID: "com.microsoft.teams2x"))
    }
}

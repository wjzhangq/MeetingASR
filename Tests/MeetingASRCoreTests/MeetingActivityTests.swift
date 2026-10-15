import XCTest
@testable import MeetingASRCore

final class MeetingActivityTests: XCTestCase {
    typealias Obs = MeetingActivityDetector.Observation

    /// 每 2 秒采样一次，返回各时刻的事件
    func run(_ d: inout MeetingActivityDetector, _ samples: [(Double, Obs)]) -> [(Double, MeetingActivityDetector.Event)] {
        samples.compactMap { t, o in d.update(o, now: t).map { (t, $0) } }
    }

    func timeline(from: Double, to: Double, _ o: Obs) -> [(Double, Obs)] {
        stride(from: from, to: to, by: 2).map { ($0, o) }
    }

    func testStartAndEnd() {
        var d = MeetingActivityDetector()
        let teams = Obs(inputApp: "Microsoft Teams", outputActive: true)
        let idle = Obs(inputApp: nil, outputActive: false)
        let ev = run(&d, timeline(from: 0, to: 10, idle) + timeline(from: 10, to: 60, teams) + timeline(from: 60, to: 100, idle))
        XCTAssertEqual(ev.map(\.1), [.started(app: "Microsoft Teams"), .ended(app: "Microsoft Teams")])
        XCTAssertEqual(ev[0].0, 16) // 10 秒开始采集，持续 ≥5 秒
        XCTAssertEqual(ev[1].0, 76) // 60 秒起静默，≥15 秒
        XCTAssertFalse(d.inMeeting)
    }

    func testBriefMicUseIgnored() {
        var d = MeetingActivityDetector()
        let ev = run(&d, timeline(from: 0, to: 4, Obs(inputApp: "Microsoft Teams", outputActive: false)) + timeline(from: 4, to: 30, Obs(inputApp: nil, outputActive: false)))
        XCTAssertTrue(ev.isEmpty)
    }

    func testMutedButListeningKeepsMeeting() {
        // 会中静音（软件停止采集）但仍在播放远端声音：不判为结束
        var d = MeetingActivityDetector()
        let ev = run(&d, timeline(from: 0, to: 20, Obs(inputApp: "腾讯会议", outputActive: true))
                     + timeline(from: 20, to: 80, Obs(inputApp: nil, outputActive: true)))
        XCTAssertEqual(ev.map(\.1), [.started(app: "腾讯会议")])
        XCTAssertTrue(d.inMeeting)
        XCTAssertEqual(d.currentApp, "腾讯会议")
    }

    func testShortSilenceDoesNotEnd() {
        var d = MeetingActivityDetector()
        let on = Obs(inputApp: "Microsoft Teams", outputActive: true), off = Obs(inputApp: nil, outputActive: false)
        let ev = run(&d, timeline(from: 0, to: 20, on) + timeline(from: 20, to: 30, off) + timeline(from: 30, to: 50, on))
        XCTAssertEqual(ev.map(\.1), [.started(app: "Microsoft Teams")])
    }
}

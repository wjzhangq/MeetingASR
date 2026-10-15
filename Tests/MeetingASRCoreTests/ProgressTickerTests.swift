import XCTest
@testable import MeetingASRCore

final class ProgressTickerTests: XCTestCase {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var values: [Double] = []
        func add(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
        var snapshot: [Double] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func testEstimateAdvancesWithoutCallbacksAndStaysBelowTarget() {
        let box = Box()
        let t = ProgressTicker(interval: 0.05) { box.add($0) }
        t.estimate(from: 0.1, to: 0.5, expectedSeconds: 0.3)
        Thread.sleep(forTimeInterval: 0.6)
        let v = box.snapshot
        XCTAssertGreaterThan(v.count, 5, "无回调阶段也应持续上报")
        XCTAssertEqual(v, v.sorted(), "单调不减")
        XCTAssertGreaterThan(v.last!, 0.4)
        XCTAssertLessThan(v.last!, 0.5)
        // 真实进度到达：停止估计；比已上报值小的不回退
        t.set(0.45)
        t.set(0.7)
        let n = box.snapshot.count
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(box.snapshot.count, n)
        XCTAssertEqual(box.snapshot.last, 0.7)
        t.stop()
        t.set(0.9)
        XCTAssertEqual(box.snapshot.last, 0.7, "停止后不再上报")
    }
}

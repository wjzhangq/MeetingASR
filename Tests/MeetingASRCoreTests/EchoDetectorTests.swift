import XCTest
@testable import MeetingASRCore

final class EchoDetectorTests: XCTestCase {
    func testEchoDetection() {
        let rate = 16_000
        // 远端语音：调幅噪声
        var system: [Float] = []
        for i in 0..<(rate * 2) {
            let env = Float(0.5 + 0.5 * sin(2 * Double.pi * 3 * Double(i) / Double(rate)))
            system.append(env * Float.random(in: -0.3...0.3))
        }
        // 回声：延迟 80ms、衰减 15 dB
        let delay = Int(0.08 * Double(rate))
        let echo = [Float](repeating: 0, count: delay) + system.prefix(system.count - delay).map { $0 * 0.18 }
        let det = EchoDetector()
        XCTAssertTrue(det.isEcho(mic: echo, system: system))
        // 本人说话：与远端无关
        var own: [Float] = []
        for i in 0..<(rate * 2) {
            let env = Float(0.5 + 0.5 * sin(2 * Double.pi * 1.3 * Double(i) / Double(rate) + 1))
            own.append(env * Float.random(in: -0.1...0.1))
        }
        XCTAssertFalse(det.isEcho(mic: own, system: system))
        // 麦克风能量更高时（本人说话盖过外放）不判为回声
        XCTAssertFalse(det.isEcho(mic: system.map { $0 * 2 }, system: system))
        // 外放音量大：回声只衰减 3 dB，但包络几乎一致 → 判为回声
        let loud = [Float](repeating: 0, count: delay) + system.prefix(system.count - delay).map { $0 * 0.7 }
        XCTAssertTrue(det.isEcho(mic: loud, system: system))
    }
}

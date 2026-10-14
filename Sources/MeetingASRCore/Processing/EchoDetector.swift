import Foundation

/// 回声判定（4.3 回声对策 2）：
/// 麦克风轨某段与会议软件轨同时段能量包络高度相关，且麦克风能量明显更低时，判定为回声。
public struct EchoDetector: Sendable {
    /// 包络相关系数阈值
    public var correlationThreshold: Float = 0.75
    /// 麦克风（还原增益后）能量低于系统轨的倍数，0.5 约 -6 dB
    public var energyRatio: Float = 0.5
    /// 允许的回声延迟（秒）
    public var maxDelay: Double = 0.5
    /// 包络帧长（秒）
    public var frameSec: Double = 0.02

    public init() {}

    /// - Parameters:
    ///   - mic/system: 同一时间区间的 16k 样本
    ///   - micGain/systemGain: 预处理时施加的增益，用于还原原始能量对比
    public func isEcho(mic: [Float], system: [Float], micGain: Float = 1, systemGain: Float = 1, sampleRate: Int = 16_000) -> Bool {
        guard mic.count > sampleRate / 4, system.count > sampleRate / 4 else { return false }
        let micRMS = SignalStats.rms(mic) / max(micGain, 1e-6)
        let sysRMS = SignalStats.rms(system) / max(systemGain, 1e-6)
        guard sysRMS > 1e-4, micRMS < sysRMS * energyRatio else { return false }
        let frame = max(1, Int(frameSec * Double(sampleRate)))
        let a = Self.centered(SignalStats.envelope(mic, frame: frame))
        let b = Self.centered(SignalStats.envelope(system, frame: frame))
        let lag = Int(maxDelay / frameSec)
        // 回声只会滞后于远端声音：mic[i] 对应 system[i - d]
        return Self.laggedCorrelation(mic: a, system: b, maxLag: lag) >= correlationThreshold
    }

    static func centered(_ x: [Float]) -> [Float] {
        guard !x.isEmpty else { return x }
        let m = x.reduce(0, +) / Float(x.count)
        return x.map { $0 - m }
    }

    static func laggedCorrelation(mic: [Float], system: [Float], maxLag: Int) -> Float {
        let n = min(mic.count, system.count)
        var best: Float = -1
        for d in 0...max(0, min(maxLag, n / 2)) {
            var dot: Float = 0, ea: Float = 0, eb: Float = 0
            for i in d..<n {
                let x = mic[i], y = system[i - d]
                dot += x * y; ea += x * x; eb += y * y
            }
            if ea > 0, eb > 0 { best = max(best, dot / sqrt(ea * eb)) }
        }
        return best
    }
}

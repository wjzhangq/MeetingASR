import Foundation

/// 预处理：任意采样率/声道 → 16kHz 单声道，响度归一，写为 WAV。
/// 分块流式处理，长音频不一次性载入内存。
public enum Preprocessor {
    public static let targetRate = 16_000
    /// 目标语音 RMS（约 -23 dBFS）
    public static let targetRMS: Float = 0.07
    /// 最大增益（+20 dB），避免把底噪放得过大
    public static let maxGain: Float = 10

    public struct Result: Sendable {
        public let url: URL
        public let durationSec: Double
        public let gain: Float
    }

    /// - Parameters:
    ///   - range: 只处理该时间范围（秒，基于源文件），nil 为整段（FR-F3）
    ///   - progress: 0...1
    public static func process(
        source: MonoAudioSource,
        range: ClosedRange<Double>? = nil,
        output: URL,
        isCancelled: () -> Bool = { false },
        progress: (Double) -> Void = { _ in }
    ) throws -> Result {
        let sr = source.sampleRate
        let startFrame = Int64(((range?.lowerBound ?? 0) * Double(sr)).rounded())
        let endFrame = min(source.frameCount, range.map { Int64(($0.upperBound * Double(sr)).rounded()) } ?? source.frameCount)
        let total = max(0, endFrame - startFrame)
        let chunk = sr * 10

        // 第一遍：统计有声部分的 RMS，计算增益
        var sumSq: Double = 0
        var activeCount: Int64 = 0
        var peak: Float = 0
        var pos = startFrame
        let frameLen = sr / 50 // 20ms
        while pos < endFrame {
            if isCancelled() { throw CancellationError() }
            let buf = source.readMono(startFrame: pos, count: Int(min(Int64(chunk), endFrame - pos)))
            if buf.isEmpty { break }
            var i = 0
            while i < buf.count {
                let n = min(frameLen, buf.count - i)
                var e: Float = 0
                for j in i..<(i + n) {
                    e += buf[j] * buf[j]
                    peak = max(peak, abs(buf[j]))
                }
                // 只统计高于 -50 dBFS 的帧
                if e / Float(n) > 1e-5 {
                    sumSq += Double(e)
                    activeCount += Int64(n)
                }
                i += n
            }
            pos += Int64(buf.count)
            progress(total > 0 ? 0.5 * Double(pos - startFrame) / Double(total) : 0.5)
        }
        var gain: Float = 1
        if activeCount > 0 {
            let rms = Float(sqrt(sumSq / Double(activeCount)))
            if rms > 0 { gain = min(maxGain, targetRMS / rms) }
        }
        if peak * gain > 0.99, peak > 0 {
            // 峰值过高时适当降低增益，剩余峰值交给软限幅
            gain = max(min(gain, 0.99 / peak), min(gain, 1))
        }

        // 第二遍：重采样 + 增益 + 软限幅
        let writer = try WavWriter(url: output, sampleRate: targetRate, channels: 1, format: .int16)
        let resampler = Resampler(inputRate: sr, outputRate: targetRate)
        pos = startFrame
        while pos < endFrame {
            if isCancelled() { try? writer.close(); throw CancellationError() }
            var buf = source.readMono(startFrame: pos, count: Int(min(Int64(chunk), endFrame - pos)))
            if buf.isEmpty { break }
            pos += Int64(buf.count)
            for i in buf.indices { buf[i] = softClip(buf[i] * gain) }
            writer.write(resampler.process(buf))
            progress(total > 0 ? 0.5 + 0.5 * Double(pos - startFrame) / Double(total) : 1)
        }
        writer.write(resampler.flush())
        try writer.close()
        return Result(url: output, durationSec: writer.durationSec, gain: gain)
    }

    @inline(__always)
    static func softClip(_ x: Float) -> Float {
        let a = abs(x)
        if a <= 0.9 { return x }
        // 0.9 以上平滑压缩到 1 以内
        let y = 0.9 + 0.1 * tanh((a - 0.9) / 0.1)
        return x < 0 ? -y : y
    }
}

/// 简单信号统计。
public enum SignalStats {
    public static func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        var s: Float = 0
        for v in x { s += v * v }
        return sqrt(s / Float(x.count))
    }

    public static func rms(_ x: [Float]) -> Float { rms(x[...]) }

    /// 估计信噪比（dB）：20ms 帧能量的高分位 / 低分位。
    public static func estimateSNR(_ x: [Float], sampleRate: Int = 16_000) -> Double {
        let n = sampleRate / 50
        guard x.count >= n * 4 else { return 0 }
        var energies: [Float] = []
        var i = 0
        while i + n <= x.count {
            energies.append(rms(x[i..<(i + n)]) + 1e-6)
            i += n
        }
        energies.sort()
        let lo = energies[energies.count / 10]
        let hi = energies[energies.count * 9 / 10]
        return Double(20 * log10(hi / lo))
    }

    /// 两段信号在 ±maxLag 样本范围内的最大归一化互相关（用于回声判定）。
    public static func maxNormalizedCorrelation(_ a: [Float], _ b: [Float], maxLag: Int, step: Int = 1) -> Float {
        let n = min(a.count, b.count)
        guard n > maxLag * 2 else { return 0 }
        var best: Float = 0
        var lag = -maxLag
        while lag <= maxLag {
            var dot: Float = 0, ea: Float = 0, eb: Float = 0
            let s = max(0, -lag), e = min(n, n - lag)
            var i = s
            while i < e {
                let x = a[i], y = b[i + lag]
                dot += x * y; ea += x * x; eb += y * y
                i += 1
            }
            if ea > 0, eb > 0 { best = max(best, abs(dot) / sqrt(ea * eb)) }
            lag += step
        }
        return best
    }

    /// 简单的能量包络（每 frame 个样本取 RMS）。
    public static func envelope(_ x: [Float], frame: Int) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(x.count / frame + 1)
        var i = 0
        while i < x.count {
            out.append(rms(x[i..<min(x.count, i + frame)]))
            i += frame
        }
        return out
    }
}

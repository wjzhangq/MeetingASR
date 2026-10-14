import Foundation

/// 流式带限重采样器（加窗 sinc，Blackman 窗）。
/// 用整数有理数步进计算输出位置，长音频不会累积误差。
public final class Resampler {
    public let inputRate: Int
    public let outputRate: Int
    private let halfWidth: Int
    private let cutoff: Double
    /// 预计算的滤波器表：phases × (2*halfWidth) 系数
    private let phases: Int
    private let table: [Float]
    private var history: [Float] = []
    /// 已丢弃的输入样本数（history[0] 的全局下标）
    private var historyStart: Int64 = 0
    /// 下一个输出样本序号
    private var outIndex: Int64 = 0
    private var inputTotal: Int64 = 0

    public init(inputRate: Int, outputRate: Int, halfWidth: Int = 16) {
        self.inputRate = inputRate
        self.outputRate = outputRate
        self.halfWidth = halfWidth
        // 降采样时截止频率按输出奈奎斯特频率收缩
        cutoff = 0.95 * min(1.0, Double(outputRate) / Double(inputRate))
        phases = 256
        var t = [Float](repeating: 0, count: (phases + 1) * 2 * halfWidth)
        for p in 0...phases {
            let frac = Double(p) / Double(phases)
            var sum = 0.0
            var row = [Double](repeating: 0, count: 2 * halfWidth)
            for k in 0..<(2 * halfWidth) {
                // 第 k 个抽头对应输入下标 floor(t) - halfWidth + 1 + k
                let x = Double(k - halfWidth + 1) - frac
                let sincArg = Double.pi * x * cutoff
                let sinc = abs(x) < 1e-9 ? 1.0 : sin(sincArg) / sincArg
                let n = (x + Double(halfWidth)) / Double(2 * halfWidth)
                let w = (n <= 0 || n >= 1) ? 0 : 0.42 - 0.5 * cos(2 * .pi * n) + 0.08 * cos(4 * .pi * n)
                row[k] = sinc * w
                sum += row[k]
            }
            for k in 0..<(2 * halfWidth) {
                t[p * 2 * halfWidth + k] = Float(sum != 0 ? row[k] / sum : 0)
            }
        }
        table = t
    }

    /// 输入一段样本，返回可以确定的输出样本。
    public func process(_ input: [Float]) -> [Float] {
        if inputRate == outputRate { return input }
        history.append(contentsOf: input)
        inputTotal += Int64(input.count)
        return drain(final: false)
    }

    /// 输入结束，输出剩余样本（末尾以零补齐）。
    public func flush() -> [Float] {
        if inputRate == outputRate { return [] }
        return drain(final: true)
    }

    private func drain(final: Bool) -> [Float] {
        var out: [Float] = []
        let totalOut = final ? (inputTotal * Int64(outputRate) + Int64(inputRate) - 1) / Int64(inputRate) : Int64.max
        let tapCount = 2 * halfWidth
        while outIndex < totalOut {
            let num = outIndex * Int64(inputRate)
            let center = num / Int64(outputRate)
            let rem = num % Int64(outputRate)
            let first = center - Int64(halfWidth) + 1
            let last = center + Int64(halfWidth)
            if !final && last >= inputTotal { break }
            let phase = Int((Double(rem) / Double(outputRate) * Double(phases)).rounded())
            let base = phase * tapCount
            var acc: Float = 0
            history.withUnsafeBufferPointer { h in
                table.withUnsafeBufferPointer { tb in
                    for k in 0..<tapCount {
                        let gi = first + Int64(k)
                        if gi < historyStart || gi >= inputTotal { continue }
                        acc += h[Int(gi - historyStart)] * tb[base + k]
                    }
                }
            }
            out.append(acc)
            outIndex += 1
        }
        // 丢弃不再需要的历史
        let nextFirst = (outIndex * Int64(inputRate)) / Int64(outputRate) - Int64(halfWidth) + 1
        let drop = Int(max(0, min(Int64(history.count), nextFirst - historyStart)))
        if drop > 4096 {
            history.removeFirst(drop)
            historyStart += Int64(drop)
        }
        return out
    }

    /// 一次性重采样整段音频。
    public static func resample(_ samples: [Float], from inRate: Int, to outRate: Int) -> [Float] {
        if inRate == outRate { return samples }
        let r = Resampler(inputRate: inRate, outputRate: outRate)
        return r.process(samples) + r.flush()
    }
}

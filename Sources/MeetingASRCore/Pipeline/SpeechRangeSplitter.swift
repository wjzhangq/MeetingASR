import Foundation

/// 把超过上限的 VAD 区间切开。sherpa-onnx 的 `maxSpeechDuration` 仍可能吐出数分钟的段，
/// 这里在输出侧再切一刀：切点前几秒里若有明显更安静的帧，就切在那里，否则按上限硬切。
public enum SpeechRangeSplitter {
    public static func split(
        _ ranges: [ClosedRange<Double>],
        samples: [Float],
        sampleRate: Int = 16_000,
        maxSec: Double,
        searchSec: Double = 2
    ) -> [ClosedRange<Double>] {
        guard maxSec > 0.5, sampleRate > 0 else { return ranges }
        return ranges.flatMap {
            splitOne($0, samples: samples, sampleRate: sampleRate, maxSec: maxSec, searchSec: searchSec)
        }
    }

    private static func splitOne(
        _ range: ClosedRange<Double>,
        samples: [Float],
        sampleRate: Int,
        maxSec: Double,
        searchSec: Double
    ) -> [ClosedRange<Double>] {
        if range.upperBound - range.lowerBound <= maxSec + 1e-3 { return [range] }

        var pieces: [ClosedRange<Double>] = []
        var cursor = range.lowerBound
        while range.upperBound - cursor > maxSec + 1e-3 {
            let hard = cursor + maxSec
            let earliest = cursor + min(maxSec * 0.5, maxSec - 0.05)
            let windowStart = max(earliest, hard - searchSec)
            let preferred = quietCut(samples, sampleRate: sampleRate, from: windowStart, to: hard)
            var cut = min(max(preferred ?? hard, cursor + 0.05), hard)
            if cut <= cursor { cut = hard }
            pieces.append(cursor...cut)
            cursor = cut
        }
        if range.upperBound - cursor > 1e-3 {
            pieces.append(cursor...range.upperBound)
        }
        return pieces.isEmpty ? [range] : pieces
    }

    /// 窗口内最安静的一帧。只有明显低于中位能量时才采用，避免在均匀语音中间乱切。
    private static func quietCut(_ samples: [Float], sampleRate: Int, from: Double, to: Double) -> Double? {
        let frame = max(1, sampleRate / 50)
        let a = max(0, Int(from * Double(sampleRate)))
        let b = min(samples.count, Int(to * Double(sampleRate)))
        guard b - a >= frame else { return nil }

        var bestRMS = Float.greatestFiniteMagnitude
        var bestT = to
        var rmses: [Float] = []
        var i = a
        while i + frame <= b {
            let r = SignalStats.rms(samples[i..<(i + frame)])
            rmses.append(r)
            if r < bestRMS {
                bestRMS = r
                bestT = Double(i + frame / 2) / Double(sampleRate)
            }
            i += frame
        }
        guard !rmses.isEmpty else { return nil }
        let median = rmses.sorted()[rmses.count / 2]
        guard median > 1e-6, bestRMS < median * 0.45 else { return nil }
        return bestT
    }
}

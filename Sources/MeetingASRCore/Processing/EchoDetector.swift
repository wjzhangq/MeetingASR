import Foundation

/// 回声判定（4.3 回声对策 2）：
/// 麦克风轨某段与会议软件轨同时段能量包络高度相关，且麦克风能量明显更低时，判定为回声。
public struct EchoDetector: Sendable {
    /// 包络相关系数阈值
    public var correlationThreshold: Float = 0.75
    /// 麦克风（还原增益后）能量低于系统轨的倍数，0.5 约 -6 dB
    public var energyRatio: Float = 0.5
    /// 包络相关性极高时（外放音量大、回声消除后残留），能量只需不高于系统轨即判为回声
    public var strongCorrelation: Float = 0.9
    public var strongEnergyRatio: Float = 1.0
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
        guard sysRMS > 1e-4, micRMS < sysRMS * max(energyRatio, strongEnergyRatio) else { return false }
        let frame = max(1, Int(frameSec * Double(sampleRate)))
        let a = Self.centered(SignalStats.envelope(mic, frame: frame))
        let b = Self.centered(SignalStats.envelope(system, frame: frame))
        let lag = Int(maxDelay / frameSec)
        // 回声只会滞后于远端声音：mic[i] 对应 system[i - d]
        let corr = Self.laggedCorrelation(mic: a, system: b, maxLag: lag)
        if corr >= correlationThreshold, micRMS < sysRMS * energyRatio { return true }
        return corr >= strongCorrelation && micRMS < sysRMS * strongEnergyRatio
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

/// 文本层回声过滤（声学判定的兜底）：麦克风轨识别出的字与会议软件轨同一时间（回声滞后）的字相同，
/// 且连续成片时，判为串入的远端声音并删除。可处理一段内本人说话与回声混杂、声学相关性被稀释的情况。
public struct TextEchoFilter: Sendable {
    /// 麦克风字相对系统轨同字的允许时间差：滞后最多 maxLag 秒，超前最多 maxLead 秒（时间戳误差）
    public var maxLag: Double = 1.0
    public var maxLead: Double = 0.3
    /// 以 token 为中心、宽 2*window+1 的窗口内至少 minMatches 个字匹配，才判为回声（避免"的""是"等偶然相同）
    public var window: Int = 2
    public var minMatches: Int = 3
    /// 无字级时间戳时：麦克风段文本被同时段系统轨文本包含的比例阈值与最少字数
    public var minContainment: Double = 0.7
    public var minChars: Int = 4

    public init() {}

    /// 返回过滤后的识别结果（只改动麦克风轨）。
    public func filter(_ pieces: [RecognizedPiece]) -> [RecognizedPiece] {
        let system = pieces.filter { $0.track == .system }
        guard !system.isEmpty, pieces.contains(where: { $0.track == .mic }) else { return pieces }
        let sysTokens = system.flatMap(\.tokens).sorted { $0.start < $1.start }
        let sysStarts = sysTokens.map(\.start)
        return pieces.compactMap { p -> RecognizedPiece? in
            guard p.track == .mic else { return p }
            if !p.tokens.isEmpty, !sysTokens.isEmpty {
                let echo = echoMask(p.tokens, sysTokens: sysTokens, sysStarts: sysStarts)
                guard echo.contains(true) else { return p }
                var q = p
                q.tokens = zip(p.tokens, echo).filter { !$0.1 }.map(\.0)
                guard q.tokens.count >= 2 || (q.tokens.count == 1 && q.tokens[0].t.count > 1) else { return nil }
                q.text = TokenText.join(q.tokens)
                return q
            }
            // 无时间戳：按时间重叠的系统轨文本比较
            guard TextSimilarity.chars(p.text).count >= minChars else { return p }
            let nearby = system.filter { $0.end >= p.start - maxLag && $0.start <= p.end + maxLag }.map(\.text).joined()
            return TextSimilarity.containment(p.text, in: nearby) >= minContainment ? nil : p
        }
    }

    /// 每个麦克风 token 是否为回声。
    func echoMask(_ tokens: [TranscriptToken], sysTokens: [TranscriptToken], sysStarts: [Double]) -> [Bool] {
        let match: [Bool] = tokens.map { tok in
            let t = tok.t.trimmingCharacters(in: .whitespaces).lowercased()
            guard !t.isEmpty else { return false }
            var i = Self.lowerBound(sysStarts, tok.start - maxLag)
            while i < sysTokens.count, sysStarts[i] <= tok.start + maxLead {
                if sysTokens[i].t.trimmingCharacters(in: .whitespaces).lowercased() == t { return true }
                i += 1
            }
            return false
        }
        var echo = [Bool](repeating: false, count: tokens.count)
        for i in tokens.indices where match[i] {
            let lo = max(0, i - window), hi = min(tokens.count - 1, i + window)
            if (lo...hi).filter({ match[$0] }).count >= minMatches { echo[i] = true }
        }
        // 夹在两个回声字之间的单个不匹配字（识别误差）一并删除
        if tokens.count >= 3 {
            for i in 1..<(tokens.count - 1) where !echo[i] && echo[i - 1] && echo[i + 1] { echo[i] = true }
        }
        return echo
    }

    static func lowerBound(_ a: [Double], _ x: Double) -> Int {
        var l = 0, h = a.count
        while l < h {
            let m = (l + h) / 2
            if a[m] < x { l = m + 1 } else { h = m }
        }
        return l
    }
}

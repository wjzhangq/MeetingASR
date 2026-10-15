import Foundation

/// 一段识别结果（会议时间轴，token 为绝对时间）。
public struct RecognizedPiece: Equatable, Sendable {
    public var speaker: String
    public var track: TrackKind
    public var start: Double
    public var end: Double
    public var text: String
    public var tokens: [TranscriptToken]

    public init(speaker: String, track: TrackKind, start: Double, end: Double, text: String, tokens: [TranscriptToken] = []) {
        self.speaker = speaker
        self.track = track
        self.start = start
        self.end = end
        self.text = text
        self.tokens = tokens
    }

    public var duration: Double { end - start }
}

/// 字级 token 拼接为文本：中文直接相连，英文词之间、中英之间加空格（与 Paraformer 输出风格一致）。
public enum TokenText {
    public static func join(_ tokens: [TranscriptToken]) -> String {
        var out = ""
        for tok in tokens {
            let t = tok.t.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if let last = out.last, let first = t.first, isLatin(last) || isLatin(first), !last.isPunctuation, !first.isPunctuation {
                out.append(" ")
            }
            out += t
        }
        return out
    }

    static func isLatin(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
}

/// 文本相似度（去掉标点与空白后按字比较）。
public enum TextSimilarity {
    static func chars(_ s: String) -> [Character] {
        s.filter { !$0.isPunctuation && !$0.isWhitespace && !$0.isSymbol }.map { Character($0.lowercased()) }
    }

    /// a 中有多大比例的字（按最长公共子序列）出现在 b 中，0...1。
    public static func containment(_ a: String, in b: String) -> Double {
        let x = chars(a), y = chars(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(lcs(x, y)) / Double(x.count)
    }

    static func lcs(_ x: [Character], _ y: [Character]) -> Int {
        var prev = [Int](repeating: 0, count: y.count + 1)
        var cur = prev
        for i in 1...x.count {
            for j in 1...y.count {
                cur[j] = x[i - 1] == y[j - 1] ? prev[j - 1] + 1 : max(prev[j], cur[j - 1])
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }
}

/// 重叠段去重：同一音轨上两个说话人的段时间重叠时，两段裁剪的是同一份混合音频，
/// 重叠部分会被各识别一次。保留较长的段（主段）中的内容，删去次段中与主段同时同字的部分。
public enum OverlapDeduplicator {
    /// 次段 token 与主段 token 视为同一个字的最大时间差（秒）
    public static let tokenTolerance = 0.6
    /// 无字级时间戳时：次段与主段时间重叠比例、文本包含度达到该值则整段丢弃
    public static let minOverlapRatio = 0.5
    public static let minContainment = 0.6

    public static func dedupe(_ pieces: [RecognizedPiece]) -> [RecognizedPiece] {
        var p = pieces
        var dropped = Set<Int>()
        let order = p.indices.sorted { p[$0].start < p[$1].start }
        for (oi, i) in order.enumerated() {
            for j in order[(oi + 1)...] {
                if p[j].start >= p[i].end { break }
                guard !dropped.contains(i), !dropped.contains(j), p[i].track == p[j].track, p[i].speaker != p[j].speaker else { continue }
                let lo = max(p[i].start, p[j].start), hi = min(p[i].end, p[j].end)
                guard hi > lo else { continue }
                let (pri, sec) = p[i].duration >= p[j].duration ? (i, j) : (j, i)
                if !p[pri].tokens.isEmpty, !p[sec].tokens.isEmpty {
                    let before = p[sec].tokens.count
                    let primary = p[pri].tokens
                    p[sec].tokens.removeAll { tok in
                        tok.start >= lo - tokenTolerance && tok.start <= hi + tokenTolerance &&
                            primary.contains { $0.t == tok.t && abs($0.start - tok.start) <= tokenTolerance }
                    }
                    if p[sec].tokens.count != before {
                        if p[sec].tokens.isEmpty { dropped.insert(sec) } else { p[sec].text = TokenText.join(p[sec].tokens) }
                    }
                } else if (hi - lo) / max(p[sec].duration, 1e-6) >= minOverlapRatio,
                          TextSimilarity.containment(p[sec].text, in: p[pri].text) >= minContainment {
                    dropped.insert(sec)
                }
            }
        }
        return p.indices.filter { !dropped.contains($0) }.map { p[$0] }
    }
}

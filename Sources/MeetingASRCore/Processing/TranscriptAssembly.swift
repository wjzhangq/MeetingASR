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

/// 轮次合并：同一说话人、间隔 < gap 的相邻段合并为一轮。
public enum TurnAssembler {
    /// 将段合并为轮次，返回 RecognizedPiece。
    public static func turns(_ segments: [Segment], gap: Double) -> [RecognizedPiece] {
        guard !segments.isEmpty else { return [] }
        
        // 按时间排序
        let sorted = segments.sorted { $0.start < $1.start }
        
        var pieces: [RecognizedPiece] = []
        var current: [Segment] = []
        
        func flush() {
            guard let first = current.first else { return }
            let speaker = first.speaker ?? first.cluster ?? "unknown"
            let track = first.track
            let start = current.map(\.start).min() ?? first.start
            let end = current.map(\.end).max() ?? first.end
            
            // 合并文本和 tokens
            let allTokens = current.flatMap(\.tokens).sorted { $0.start < $1.start }
            let text = TokenText.join(allTokens)
            
            pieces.append(RecognizedPiece(
                speaker: speaker,
                track: track,
                start: start,
                end: end,
                text: text,
                tokens: allTokens
            ))
            current.removeAll()
        }
        
        for seg in sorted {
            guard !seg.isEcho else { continue }
            
            let speaker = seg.speaker ?? seg.cluster ?? "unknown"
            
            if let last = current.last {
                let lastSpeaker = last.speaker ?? last.cluster ?? "unknown"
                let gapBetween = seg.start - last.end
                
                if speaker != lastSpeaker || gapBetween > gap || seg.track != last.track {
                    flush()
                }
            }
            
            current.append(seg)
        }
        
        flush()
        return pieces
    }
}

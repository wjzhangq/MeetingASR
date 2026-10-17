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

// MARK: - 先识别、再分配说话人

/// 一个送 ASR 的长句块（会议时间轴）。
public struct AsrChunk: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var cropStart: Double
    public var cropEnd: Double

    public init(start: Double, end: Double, cropStart: Double, cropEnd: Double) {
        self.start = start
        self.end = end
        self.cropStart = cropStart
        self.cropEnd = cropEnd
    }
}

/// 把一条音轨的语音区间组合成 10~25 秒的长句块：比按说话人切出的短段上下文更完整，
/// 且重叠语音只识别一次。
public struct AsrChunker: Sendable {
    /// 块最大时长
    public var maxChunk: Double = 25
    /// 相邻语音间隔不超过该值时并入同一块
    public var maxGap: Double = 1.0
    /// 前后补边（不越过相邻块）
    public var padding: Double = 0.25

    public init() {}

    /// - Parameters:
    ///   - speech: 语音区间（VAD 与说话人段的并集即可，可重叠）
    ///   - silences: 静音点，用于切开过长的连续语音
    ///   - total: 音轨在会议时间轴上的终点
    public func chunks(speech: [ClosedRange<Double>], silences: [Double] = [], total: Double) -> [AsrChunk] {
        // 1. 求并集
        var merged: [ClosedRange<Double>] = []
        for r in speech.filter({ $0.upperBound > $0.lowerBound }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        // 2. 过长的连续语音在静音点切开
        var cfg = SegmenterConfig()
        cfg.maxSegment = maxChunk
        let sorted = silences.sorted()
        let pieces = Segmenter(config: cfg).split(merged.map { RawSpan(speaker: "", start: $0.lowerBound, end: $0.upperBound) }) { s, e in
            sorted.filter { $0 > s && $0 < e }
        }
        // 3. 相邻片段组合成块
        var groups: [(Double, Double)] = []
        for p in pieces {
            if let last = groups.last, p.start - last.1 <= maxGap, p.end - last.0 <= maxChunk {
                groups[groups.count - 1].1 = max(last.1, p.end)
            } else {
                groups.append((p.start, p.end))
            }
        }
        // 4. 补边
        return groups.indices.map { i in
            let (s, e) = groups[i]
            let lo = max(i > 0 ? groups[i - 1].1 : 0, s - padding, 0)
            let hi = min(i + 1 < groups.count ? groups[i + 1].0 : total, e + padding, total)
            return AsrChunk(start: s, end: e, cropStart: min(lo, s), cropEnd: max(hi, e))
        }
    }
}

/// 带结束时间的 token（会议时间轴）。
public struct TimedToken: Equatable, Sendable {
    public var t: String
    public var start: Double
    public var end: Double

    public init(t: String, start: Double, end: Double) {
        self.t = t
        self.start = start
        self.end = end
    }

    /// 由 ASR 输出的起点序列推算结束时间：下一个 token 的起点，单字最长 maxLen 秒，且不超过块尾。
    public static func from(_ tokens: [TranscriptToken], chunkEnd: Double, maxLen: Double = 0.8) -> [TimedToken] {
        tokens.indices.map { i in
            let s = tokens[i].start
            let next = i + 1 < tokens.count ? tokens[i + 1].start : chunkEnd
            return TimedToken(t: tokens[i].t, start: s, end: max(s, min(next, s + maxLen, max(chunkEnd, s))))
        }
    }
}

/// 按时间把 token 分配给说话人（分离结果），再按说话人切成发言段。
public struct SpeakerAssigner: Sendable {
    /// 不在任何说话人段内的 token，并入该距离内最近的段
    public var maxNearestGap: Double = 0.8
    /// 夹在同一说话人中间、不超过该字数与时长的短游程视为边界抖动，并入两侧说话人
    public var smoothMaxTokens: Int = 2
    public var smoothMaxSec: Double = 0.5
    /// 同一说话人 token 间隔超过该值时另起一段
    public var splitGap: Double = 1.5
    /// 单段最大时长
    public var maxSegment: Double = 30

    public init() {}

    /// - Parameters:
    ///   - tokens: 本音轨全部 token（按时间排序）
    ///   - spans: 本音轨的说话人段；`isEcho` 的段内（且不在其他段内）的 token 视为回声丢弃
    public func assign(_ tokens: [TimedToken], spans: [ASRSegment], track: TrackKind) -> [RecognizedPiece] {
        let voice = spans.filter { !$0.isEcho }.sorted { $0.start < $1.start }
        let echo = spans.filter(\.isEcho)
        guard !voice.isEmpty else { return [] }

        // 1. 逐个分配（记录所依据的说话人段，用于收紧时间边界）
        var labeled: [(tok: TimedToken, spk: String, span: Int?)] = []
        var prev: String?
        for tok in tokens {
            let t = tok.start + min(0.2, max(0, tok.end - tok.start) / 2)
            let cands = voice.indices.filter { voice[$0].start <= t && t <= voice[$0].end }
            var chosen: Int?
            if cands.count == 1 {
                chosen = cands[0]
            } else if cands.count > 1 {
                // 重叠：延续上一个字的说话人，否则取 t 处于最内部的段
                chosen = cands.first { voice[$0].speaker == prev }
                    ?? cands.max { min(t - voice[$0].start, voice[$0].end - t) < min(t - voice[$1].start, voice[$1].end - t) }
            } else {
                let nearest = voice.indices.min { Self.distance(t, voice[$0]) < Self.distance(t, voice[$1]) }!
                let dv = Self.distance(t, voice[nearest])
                let de = echo.map { Self.distance(t, $0) }.min() ?? .infinity
                // 回声段内或更靠近回声段：丢弃
                if de <= maxNearestGap, de < dv { continue }
                if dv <= maxNearestGap || prev == nil { chosen = nearest }
            }
            var tk = tok
            if let c = chosen {
                // 字的结束时间不超过所在说话人段
                tk.end = max(tk.start, min(tk.end, max(voice[c].end, tk.start)))
                labeled.append((tk, voice[c].speaker, c))
                prev = voice[c].speaker
            } else if let p = prev {
                labeled.append((tk, p, nil))
            }
        }

        // 2. 平滑短游程
        var runs: [(speaker: String, range: Range<Int>)] = []
        for (i, l) in labeled.enumerated() {
            if let last = runs.last, last.speaker == l.spk {
                runs[runs.count - 1].range = last.range.lowerBound..<(i + 1)
            } else {
                runs.append((l.spk, i..<(i + 1)))
            }
        }
        if runs.count >= 3 {
            for k in 1..<(runs.count - 1) {
                let r = runs[k].range
                let dur = labeled[r.upperBound - 1].tok.end - labeled[r.lowerBound].tok.start
                if r.count <= smoothMaxTokens, dur <= smoothMaxSec,
                   runs[k - 1].speaker == runs[k + 1].speaker, runs[k - 1].speaker != runs[k].speaker {
                    for i in r { labeled[i].spk = runs[k - 1].speaker }
                }
            }
        }

        // 3. 切段；段的起止在 1 秒内贴合同一说话人段的边界
        var out: [RecognizedPiece] = []
        var cur: [(tok: TimedToken, spk: String, span: Int?)] = []
        func flush() {
            guard let f = cur.first, let l = cur.last else { return }
            var start = f.tok.start, end = max(l.tok.end, f.tok.start)
            if let si = f.span, voice[si].speaker == f.spk, voice[si].start <= start, start - voice[si].start <= 1 {
                start = max(voice[si].start, out.last(where: { $0.speaker == f.spk })?.end ?? -.infinity)
            }
            if let si = l.span, voice[si].speaker == l.spk, voice[si].end >= end, voice[si].end - end <= 1 {
                end = voice[si].end
            }
            let toks = cur.map { TranscriptToken(t: $0.tok.t, start: $0.tok.start) }
            out.append(RecognizedPiece(speaker: f.spk, track: track, start: start, end: end, text: TokenText.join(toks), tokens: toks))
            cur = []
        }
        for l in labeled {
            if let first = cur.first, let last = cur.last,
               l.spk != first.spk || l.tok.start - last.tok.end > splitGap || l.tok.end - first.tok.start > maxSegment {
                flush()
            }
            cur.append(l)
        }
        flush()
        return out
    }

    static func distance(_ t: Double, _ s: ASRSegment) -> Double {
        t < s.start ? s.start - t : (t > s.end ? t - s.end : 0)
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

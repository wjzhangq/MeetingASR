import Foundation

/// ASR 输出的子词片段合并为词级 token。
public enum SubwordMerger {
    /// 判断是否为应过滤的特殊 token（控制符、静音、语言标记等）。
    public static func isSpecialToken(_ token: String) -> Bool {
        if token.isEmpty { return true }
        // Paraformer / FireRedASR 通用控制符
        if token == "<unk>" || token == "<blk>" || token == "<sos/eos>" { return true }
        // FireRedASR 语言/方言/静音标记（<sil>、<zh>、<en>、<yue> 等）
        if token.hasPrefix("<") && token.hasSuffix(">") { return true }
        return false
    }

    /// 子词片段合并为词：Paraformer 的英文 BPE 片段以 "@@" 结尾表示未完；
    /// SentencePiece（FireRedASR）以 "▁" 开头表示新词，不带 "▁" 的英文片段接在前一个英文词后。
    public static func merge(_ pieces: [(String, Double)]) -> [TranscriptToken] {
        var tokens: [TranscriptToken] = []
        var pending: (String, Double)?
        var lastWasLatinWord = false
        for (piece, start) in pieces {
            if isSpecialToken(piece) { continue }
            if piece.hasSuffix("@@") {
                let stem = String(piece.dropLast(2))
                pending = pending.map { ($0.0 + stem, $0.1) } ?? (stem, start)
                continue
            }
            if let pd = pending {
                tokens.append(TranscriptToken(t: pd.0 + piece, start: pd.1))
                pending = nil
                lastWasLatinWord = false
                continue
            }
            if piece.hasPrefix("▁") {
                let w = String(piece.drop { $0 == "▁" })
                guard !w.isEmpty else { continue }
                tokens.append(TranscriptToken(t: w, start: start))
                lastWasLatinWord = w.unicodeScalars.allSatisfy { $0.isASCII }
                continue
            }
            let latin = piece.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) || $0 == "'" }
            if latin, lastWasLatinWord, let last = tokens.last {
                tokens[tokens.count - 1] = TranscriptToken(t: last.t + piece, start: last.start)
                continue
            }
            tokens.append(TranscriptToken(t: piece, start: start))
            lastWasLatinWord = false
        }
        if let pd = pending { tokens.append(TranscriptToken(t: pd.0, start: pd.1)) }
        return tokens
    }
}

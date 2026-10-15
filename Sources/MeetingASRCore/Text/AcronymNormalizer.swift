import Foundation

/// 英文缩写规范化：Paraformer 等中文模型常把缩写按字母逐个输出（"a s r"、"c p p s d k"）。
/// - 连续 ≥2 个以空格分隔的单字母合并为大写缩写："a s r" → "ASR"；
/// - 能按词典完整切分时按词典写法输出并以空格分隔："c p p s d k" → "C++ SDK"；
/// - 词典中的缩写整词出现时规范大小写："asr" → "ASR"。
public struct AcronymNormalizer: Sendable {
    /// 字母序列（大写）→ 规范写法
    public let dictionary: [String: String]
    private let maxKeyLength: Int

    /// 内置常见技术缩写。只收录小写形式不是常见英文单词的条目，避免误改正常英文。
    public static let builtin: [String: String] = {
        var d: [String: String] = [:]
        for w in ["ASR", "TTS", "SDK", "API", "AI", "LLM", "NLP", "GPU", "CPU", "NPU", "TPU", "UI", "UX", "PC",
                  "HTTP", "HTTPS", "URL", "JSON", "XML", "HTML", "CSS", "SQL", "PDF", "PPT", "CRM", "ERP", "OKR", "KPI",
                  "QA", "QPS", "TPS", "RTF", "CER", "WER", "VAD", "AEC", "ANC", "DSP", "SOC", "RAM", "ROM", "SSD",
                  "AWS", "GCP", "CDN", "DNS", "VPN", "SSH", "RPC", "GRPC", "MCP", "RAG", "OCR", "TCP", "UDP", "IP",
                  "ID", "PR", "MR", "CI", "CD", "PM", "HR", "CEO", "CTO", "CFO", "MVP", "POC", "SLA", "B2B", "B2C"] {
            d[w] = w
        }
        d["CPP"] = "C++"
        d["IOS"] = "iOS"
        d["ONNX"] = "ONNX"
        d["APP"] = "App"
        return d
    }()

    /// 小写整词出现时仍规范大小写的条目（排除 app/it/us 等常见单词）。
    private static let wholeWordExcluded: Set<String> = ["APP", "IT", "US", "ID", "PR", "PM", "CD", "IP"]

    /// - Parameter extra: 额外的缩写（如热词表中的纯字母词），键不区分大小写
    public init(extra: [String] = []) {
        var d = Self.builtin
        for w in extra {
            let letters = w.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.uppercased()
            // 只收录较短、无空格的纯字母数字词（缩写/产品名）
            guard letters.count >= 2, letters.count <= 10, !w.contains(" ") else { continue }
            d[letters] = w
        }
        dictionary = d
        maxKeyLength = d.keys.map(\.count).max() ?? 0
    }

    // MARK: - 文本

    public func normalize(_ text: String) -> String {
        let chars = Array(text)
        var out: [Character] = []
        var i = 0
        while i < chars.count {
            if Self.isLatinBoundary(chars, i - 1), let (letters, end) = Self.letterRun(chars, from: i), Self.isLatinBoundary(chars, end) {
                out.append(contentsOf: render(letters))
                i = end
                continue
            }
            if Self.isLatinBoundary(chars, i - 1), let end = Self.wordEnd(chars, from: i) {
                let word = String(chars[i..<end])
                let key = word.uppercased()
                if key.count >= 2, !Self.wholeWordExcluded.contains(key), let canon = dictionary[key], word != canon {
                    out.append(contentsOf: canon)
                } else {
                    out.append(contentsOf: word)
                }
                i = end
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return String(out)
    }

    // MARK: - 字级 token

    /// 合并连续的单字母 token 为一个缩写 token（起点取第一个字母）。
    public func normalize(tokens: [TranscriptToken]) -> [TranscriptToken] {
        var out: [TranscriptToken] = []
        var i = 0
        while i < tokens.count {
            var j = i
            while j < tokens.count, Self.isSingleLetter(tokens[j].t) { j += 1 }
            if j - i >= 2 {
                let letters = tokens[i..<j].map { $0.t.trimmingCharacters(in: .whitespaces).uppercased() }.joined()
                out.append(TranscriptToken(t: render(letters), start: tokens[i].start))
                i = j
            } else {
                var t = tokens[i]
                let key = t.t.trimmingCharacters(in: .whitespaces).uppercased()
                if key.count >= 2, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
                   !Self.wholeWordExcluded.contains(key), let canon = dictionary[key] {
                    t.t = t.t.hasPrefix(" ") ? " " + canon : canon
                }
                out.append(t)
                i += 1
            }
        }
        return out
    }

    // MARK: - 内部

    /// 字母序列 → 输出：整体在词典中 > 可按词典完整切分 > 直接大写。
    func render(_ letters: String) -> String {
        if let w = dictionary[letters] { return w }
        if let parts = segment(Array(letters)) { return parts.joined(separator: " ") }
        return letters
    }

    /// 动态规划：切分为最少的词典词，无法完整切分返回 nil。
    private func segment(_ s: [Character]) -> [String]? {
        let n = s.count
        guard n >= 2 else { return nil }
        var best = [[String]?](repeating: nil, count: n + 1)
        best[0] = []
        for end in 1...n {
            for len in stride(from: min(maxKeyLength, end), through: 2, by: -1) {
                guard let prev = best[end - len], let w = dictionary[String(s[(end - len)..<end])] else { continue }
                if best[end] == nil || prev.count + 1 < best[end]!.count { best[end] = prev + [w] }
            }
        }
        guard let r = best[n], r.count >= 2 else { return nil }
        return r
    }

    private static func isSingleLetter(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: .whitespaces)
        return s.count == 1 && s.first!.isASCII && s.first!.isLetter
    }

    private static func isLatin(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }

    /// 位置 i 是否为拉丁词边界（越界或非字母数字）。
    private static func isLatinBoundary(_ chars: [Character], _ i: Int) -> Bool {
        i < 0 || i >= chars.count || !(isLatin(chars[i]) || chars[i] == "+")
    }

    /// 从 i 开始匹配 "x y z"（单字母以单个空格分隔，≥2 个），返回大写字母串与结束位置。
    private static func letterRun(_ chars: [Character], from i: Int) -> (String, Int)? {
        var letters = ""
        var k = i
        while k < chars.count, chars[k].isASCII, chars[k].isLetter, isLatinBoundary(chars, k + 1) {
            letters.append(Character(chars[k].uppercased()))
            k += 1
            // 后面紧跟 " 字母" 且该字母是单字母才继续
            if k + 1 < chars.count, chars[k] == " ", chars[k + 1].isASCII, chars[k + 1].isLetter, isLatinBoundary(chars, k + 2) {
                k += 1
            } else {
                break
            }
        }
        return letters.count >= 2 ? (letters, k) : nil
    }

    /// 从 i 开始的拉丁词（字母数字）结束位置。
    private static func wordEnd(_ chars: [Character], from i: Int) -> Int? {
        var k = i
        while k < chars.count, isLatin(chars[k]) { k += 1 }
        return k > i ? k : nil
    }
}

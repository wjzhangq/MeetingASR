import Foundation

/// 热词表：纯文本，一行一个词（4.5）。
public struct HotwordList: Equatable, Sendable {
    public var words: [String]

    public init(words: [String]) {
        var seen = Set<String>()
        self.words = words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && seen.insert($0).inserted }
    }

    public init(text: String) {
        self.init(words: text.components(separatedBy: .newlines))
    }

    public static func load(from url: URL = AppSupport.hotwordsFile) -> HotwordList {
        HotwordList(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    public func save(to url: URL = AppSupport.hotwordsFile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (words.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// 合并人物库姓名（人物姓名自动加入热词）。
    public func adding(_ more: [String]) -> HotwordList {
        HotwordList(words: words + more)
    }
}

/// 汉字转无声调拼音（带缓存）。
final class PinyinTable: @unchecked Sendable {
    static let shared = PinyinTable()
    private var cache: [Character: String] = [:]
    private let lock = NSLock()

    func pinyin(_ c: Character) -> String? {
        guard c.isCJK else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let p = cache[c] { return p }
        let p = String(c).applyingTransform(.mandarinToLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false)?
            .lowercased()
            .trimmingCharacters(in: .whitespaces) ?? String(c)
        cache[c] = p
        return p
    }
}

extension Character {
    var isCJK: Bool {
        guard let s = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
        switch s.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF: return true
        default: return false
        }
    }
}

/// 热词后处理纠错（4.5 备选方案 1）：
/// - 中文热词：按拼音近似匹配同长度片段并替换（支持常见模糊音）；
/// - 英文热词：大小写/空格不敏感匹配后规范为热词写法。
public struct HotwordCorrector: Sendable {
    public let hotwords: [String]
    private let cjk: [(word: [Character], pinyin: [String])]
    private let latin: [(word: String, pattern: String)]

    public init(hotwords: HotwordList) {
        self.hotwords = hotwords.words
        var cjk: [(word: [Character], pinyin: [String])] = []
        var latin: [(word: String, pattern: String)] = []
        for w in hotwords.words {
            let chars = Array(w)
            if chars.count >= 2, chars.allSatisfy(\.isCJK) {
                cjk.append((chars, chars.map { PinyinTable.shared.pinyin($0) ?? "" }))
            } else if chars.contains(where: \.isLetter), !chars.contains(where: \.isCJK) {
                latin.append((w, w.lowercased().replacingOccurrences(of: " ", with: "")))
            }
        }
        // 长词优先，避免短词抢先替换
        self.cjk = cjk.sorted { $0.word.count > $1.word.count }
        self.latin = latin.sorted { $0.pattern.count > $1.pattern.count }
    }

    public var isEmpty: Bool { cjk.isEmpty && latin.isEmpty }

    /// 一次替换：字符下标范围 → 新字符（中文为等长替换）。
    public struct Replacement: Equatable, Sendable {
        public var range: Range<Int>
        public var with: [Character]
    }

    /// 在字符序列中查找中文热词的近似匹配（等长替换，保留与字级时间戳一一对应）。
    public func cjkReplacements(in chars: [Character]) -> [Replacement] {
        guard !cjk.isEmpty, chars.count >= 2 else { return [] }
        let py = chars.map { PinyinTable.shared.pinyin($0) }
        var taken = [Bool](repeating: false, count: chars.count)
        var result: [Replacement] = []
        for hw in cjk {
            let n = hw.word.count
            guard chars.count >= n else { continue }
            var i = 0
            while i + n <= chars.count {
                let window = i..<(i + n)
                if window.contains(where: { taken[$0] }) || Array(chars[window]) == hw.word {
                    i += 1
                    continue
                }
                var fuzzy = 0
                var ok = true
                for k in 0..<n {
                    guard let p = py[i + k] else { ok = false; break }
                    if p == hw.pinyin[k] { continue }
                    if Self.fuzzyEqual(p, hw.pinyin[k]) { fuzzy += 1 } else { ok = false; break }
                }
                // 模糊音最多 1 个，且两字词必须完全同音
                if ok, fuzzy == 0 || (n >= 3 && fuzzy <= 1) {
                    result.append(Replacement(range: window, with: hw.word))
                    for k in window { taken[k] = true }
                    i += n
                } else {
                    i += 1
                }
            }
        }
        return result.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// 纠正一段文本。
    public func correct(_ text: String) -> String {
        guard !isEmpty else { return text }
        var chars = Array(text)
        for r in cjkReplacements(in: chars) {
            chars.replaceSubrange(r.range, with: r.with)
        }
        var s = String(chars)
        for l in latin {
            s = Self.replaceLatin(in: s, pattern: l.pattern, with: l.word)
        }
        return s
    }

    /// 纠正字级 token（每个中文 token 一个字时按位置替换）。
    public func correct(tokens: [TranscriptToken]) -> [TranscriptToken] {
        guard !cjk.isEmpty, tokens.allSatisfy({ $0.t.count == 1 || !$0.t.contains(where: \.isCJK) }) else { return tokens }
        let chars = tokens.map { $0.t.count == 1 ? $0.t.first! : Character(" ") }
        var out = tokens
        for r in cjkReplacements(in: chars) {
            for (k, idx) in r.range.enumerated() { out[idx].t = String(r.with[k]) }
        }
        return out
    }

    /// 平翘舌
    static let fuzzyPairs: [(String, String)] = [("zh", "z"), ("ch", "c"), ("sh", "s")]
    /// 声母混淆 n/l、h/f、r/l
    static let fuzzyInitials: [Character: Character] = ["n": "l", "h": "f", "r": "l"]
    static let fuzzyFinals: [(String, String)] = [("ang", "an"), ("eng", "en"), ("ing", "in"), ("ong", "on")]

    static func fuzzyEqual(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        return canonical(a) == canonical(b)
    }

    static func canonical(_ p: String) -> String {
        var s = p
        for (long, short) in fuzzyPairs where s.hasPrefix(long) {
            s = short + s.dropFirst(long.count)
            break
        }
        if let first = s.first, let mapped = fuzzyInitials[first] {
            s = String(mapped) + s.dropFirst()
        }
        for (long, short) in fuzzyFinals where s.hasSuffix(long) {
            s = s.dropLast(long.count) + short
            break
        }
        return s
    }

    /// 英文热词：忽略大小写与内部空格匹配，且两侧不是字母数字。
    static func replaceLatin(in s: String, pattern: String, with word: String) -> String {
        let chars = Array(s)
        var out: [Character] = []
        var i = 0
        let pat = Array(pattern)
        while i < chars.count {
            if (i == 0 || !(chars[i - 1].isLetter && !chars[i - 1].isCJK) && !chars[i - 1].isNumber),
               let end = matchLatin(chars, from: i, pat: pat),
               end == chars.count || !((chars[end].isLetter && !chars[end].isCJK) || chars[end].isNumber) {
                out.append(contentsOf: word)
                i = end
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return String(out)
    }

    private static func matchLatin(_ chars: [Character], from start: Int, pat: [Character]) -> Int? {
        var i = start, k = 0
        while k < pat.count {
            guard i < chars.count else { return nil }
            if chars[i] == " ", k > 0 { i += 1; continue }
            guard Character(chars[i].lowercased()) == pat[k] else { return nil }
            i += 1; k += 1
        }
        return i
    }
}

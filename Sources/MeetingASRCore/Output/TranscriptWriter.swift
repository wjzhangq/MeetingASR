import Foundation

/// 输出 transcript.json / transcript.md / transcript.srt。
public enum TranscriptWriter {
    public static func writeAll(_ t: Transcript, to m: MeetingPaths) throws {
        try JSONIO.write(t, to: m.transcriptJSON)
        try Data(markdown(t).utf8).write(to: m.transcriptMarkdown, options: .atomic)
        try Data(srt(t).utf8).write(to: m.transcriptSRT, options: .atomic)
    }

    /// 校验三个结果文件均存在且 JSON 可解析、内容一致（删除原始音频前调用，4.7）。
    public static func verify(_ t: Transcript, at m: MeetingPaths) -> Bool {
        guard let back = try? JSONIO.read(Transcript.self, from: m.transcriptJSON), back == t else { return false }
        for url in [m.transcriptMarkdown, m.transcriptSRT] {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attrs[.size] as? NSNumber)?.intValue ?? 0 > 0 || t.segments.isEmpty else { return false }
        }
        return true
    }

    // MARK: Markdown

    public static func markdown(_ t: Transcript) -> String {
        var lines: [String] = []
        lines.append("# \(t.title.isEmpty ? "会议记录" : t.title)")
        lines.append("")
        if let date = ISO8601.date(from: t.createdAt) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "yyyy-MM-dd HH:mm"
            lines.append("- 时间：\(f.string(from: date))")
        }
        lines.append("- 时长：\(clock(t.durationSec))")
        let names = orderedSpeakerNames(t)
        if !names.isEmpty { lines.append("- 说话人：\(names.joined(separator: "、"))") }
        lines.append("")
        lines.append("---")
        lines.append("")

        let pauses = (t.pauses ?? []).map(\.at).sorted()
        var pauseIdx = 0
        var group: [TranscriptSegment] = []

        func flush() {
            guard let first = group.first, let last = group.last else { return }
            let name = t.displayName(of: first.speaker)
            let end = group.map(\.end).max() ?? last.end
            lines.append("**\(name)** `\(clock(first.start)) – \(clock(end))`")
            lines.append("")
            lines.append(group.map(\.text).joined())
            lines.append("")
            group.removeAll()
        }

        for s in t.segments where !s.text.isEmpty {
            var paused = false
            while pauseIdx < pauses.count, pauses[pauseIdx] <= s.start {
                pauseIdx += 1
                paused = true
            }
            if paused {
                flush()
                lines.append("*（暂停）*")
                lines.append("")
            }
            if let g = group.first, g.speaker != s.speaker { flush() }
            group.append(s)
        }
        flush()
        if pauseIdx < pauses.count, pauses[pauseIdx] < t.durationSec {
            lines.append("*（暂停）*")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: SRT

    public static func srt(_ t: Transcript) -> String {
        var out: [String] = []
        var n = 1
        for s in t.segments where !s.text.isEmpty {
            out.append("\(n)")
            out.append("\(srtTime(s.start)) --> \(srtTime(max(s.end, s.start + 0.1)))")
            out.append("\(t.displayName(of: s.speaker))：\(s.text)")
            out.append("")
            n += 1
        }
        return out.joined(separator: "\n")
    }

    // MARK: 纯文本（一键复制，FR-V3）

    public static func plainText(_ t: Transcript) -> String {
        var lines: [String] = []
        var last: String?
        for s in t.segments where !s.text.isEmpty {
            if s.speaker != last {
                if last != nil { lines.append("") }
                lines.append("\(t.displayName(of: s.speaker)) [\(clock(s.start))]")
                last = s.speaker
            }
            lines.append(s.text)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 时间格式

    /// `HH:MM:SS`
    public static func clock(_ sec: Double) -> String {
        let s = Int(max(0, sec).rounded(.down))
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    /// `HH:MM:SS,mmm`
    public static func srtTime(_ sec: Double) -> String {
        let ms = Int((max(0, sec) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    /// 按首次发言顺序列出说话人显示名（合并后同名只出现一次）。
    static func orderedSpeakerNames(_ t: Transcript) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for s in t.segments {
            let n = t.displayName(of: s.speaker)
            if seen.insert(n).inserted { names.append(n) }
        }
        return names
    }
}

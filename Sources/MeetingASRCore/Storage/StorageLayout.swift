import Foundation

/// 数据目录布局：
/// ```
/// ~/Documents/MeetingASR/
/// ├── meetings/<YYYY-MM-DD_HHmmss_标题>/{meta.json, transcript.*, speakers/, .raw/}
/// └── people/{people.json, <person-id>/*.wav}
/// ```
public struct StorageLayout: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// 默认根目录 `~/Documents/MeetingASR/`（FR-S1）。
    public static var `default`: StorageLayout {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        return StorageLayout(root: docs.appendingPathComponent("MeetingASR", isDirectory: true))
    }

    public var meetingsDir: URL { root.appendingPathComponent("meetings", isDirectory: true) }
    public var peopleDir: URL { root.appendingPathComponent("people", isDirectory: true) }
    public var peopleFile: URL { peopleDir.appendingPathComponent("people.json") }

    public func personDir(_ personId: String) -> URL {
        peopleDir.appendingPathComponent(personId, isDirectory: true)
    }

    public func meeting(named name: String) -> MeetingPaths {
        MeetingPaths(dir: meetingsDir.appendingPathComponent(name, isDirectory: true))
    }

    public func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: peopleDir, withIntermediateDirectories: true)
    }

    /// 生成会议目录名 `YYYY-MM-DD_HHmmss_<标题>`（FR-S2），重名时追加序号。
    public func newMeetingName(date: Date, title: String) -> String {
        let base = Self.meetingDirName(date: date, title: title)
        var name = base
        var i = 2
        while FileManager.default.fileExists(atPath: meetingsDir.appendingPathComponent(name).path) {
            name = "\(base)-\(i)"
            i += 1
        }
        return name
    }

    public static func meetingDirName(date: Date, title: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = f.string(from: date)
        let t = sanitize(title)
        return t.isEmpty ? stamp : "\(stamp)_\(t)"
    }

    /// 去除文件名非法字符，限制长度。
    public static func sanitize(_ title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t").union(.controlCharacters)
        let cleaned = title.unicodeScalars.map { illegal.contains($0) ? "_" : String($0) }.joined()
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        return String(trimmed.prefix(60))
    }
}

/// 单个会议目录内的文件路径。
public struct MeetingPaths: Sendable, Hashable {
    public let dir: URL

    public init(dir: URL) { self.dir = dir }

    public var name: String { dir.lastPathComponent }
    public var meta: URL { dir.appendingPathComponent("meta.json") }
    public var transcriptJSON: URL { dir.appendingPathComponent("transcript.json") }
    public var transcriptMarkdown: URL { dir.appendingPathComponent("transcript.md") }
    public var transcriptSRT: URL { dir.appendingPathComponent("transcript.srt") }
    public var speakersDir: URL { dir.appendingPathComponent("speakers", isDirectory: true) }
    public var speakersJSON: URL { speakersDir.appendingPathComponent("speakers.json") }
    /// 录音及识别完成前的原始音频临时目录
    public var rawDir: URL { dir.appendingPathComponent(".raw", isDirectory: true) }
    /// 识别过程中的中间文件（16k 单声道）
    public var workDir: URL { rawDir.appendingPathComponent("work", isDirectory: true) }

    public func rawTrack(_ kind: TrackKind) -> URL {
        rawDir.appendingPathComponent("\(kind.rawValue).wav")
    }

    public func clip(_ file: String) -> URL {
        speakersDir.appendingPathComponent(file)
    }

    public var hasRawAudio: Bool {
        FileManager.default.fileExists(atPath: rawDir.path)
    }
}

/// 应用支持目录 `~/Library/Application Support/MeetingASR/`（热词表、设置）。
public enum AppSupport {
    public static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MeetingASR", isDirectory: true)
    }

    public static var hotwordsFile: URL { dir.appendingPathComponent("hotwords.txt") }
}

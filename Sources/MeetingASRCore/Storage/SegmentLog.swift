import Foundation

/// 段处理的参数指纹，用于断点恢复校验。
public struct SegmentLogKey: Codable, Equatable, Sendable {
    public var track: TrackKind
    public var vadConfig: SegmentVADConfig
    public var asrModel: String
    public var embeddingModel: String
    
    public init(track: TrackKind, vadConfig: SegmentVADConfig, asrModel: String, embeddingModel: String) {
        self.track = track
        self.vadConfig = vadConfig
        self.asrModel = asrModel
        self.embeddingModel = embeddingModel
    }

    /// 稳定的单行指纹。JSON 键序不稳定，不能拿两次编码的字节比较。
    var fingerprint: String {
        let v = vadConfig
        return String(
            format: "%@|%@|%@|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f",
            track.rawValue, asrModel, embeddingModel,
            Double(v.threshold), Double(v.minSilenceDuration), Double(v.minSpeechDuration),
            Double(v.maxSpeechDuration), Double(v.padBefore), Double(v.padAfter)
        )
    }
}

/// 段日志文件：.raw/segments_<track>.jsonl
public enum SegmentLog {
    /// 日志文件路径。
    public static func url(_ meeting: MeetingPaths, track: TrackKind) -> URL {
        meeting.rawDir.appendingPathComponent("segments_\(track.rawValue).jsonl")
    }
    
    /// 新建日志并写入参数指纹。之后再用 `append` 追加段。指纹不一致的日志不会被复用。
    public static func create(_ url: URL, key: SegmentLogKey) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("key " + key.fingerprint).write(to: url, atomically: true, encoding: .utf8)
    }

    /// 追加一个段到日志。
    public static func append(_ segment: Segment, to url: URL) throws {
        let data = try JSONEncoder().encode(segment)
        guard let line = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "SegmentLog", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode segment"])
        }
        
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try line.data(using: .utf8)?.write(to: url)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = "\n\(line)".data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        }
    }
    
    /// 读取所有段。
    public static func read(from url: URL) throws -> [Segment] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n").map(String.init)
        
        return lines.compactMap { line in
            guard !line.isEmpty, let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(Segment.self, from: data)
        }
    }
    
    /// 读取可复用的段（参数指纹一致）。
    public static func usableSegments(
        meeting: MeetingPaths,
        track: TrackKind,
        key: SegmentLogKey
    ) -> [Segment] {
        let url = self.url(meeting, track: track)
        guard FileManager.default.fileExists(atPath: url.path),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
        guard lines.first == "key " + key.fingerprint else { return [] }
        return lines.dropFirst().compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(Segment.self, from: data)
        }
    }

    /// 删除日志文件。
    public static func remove(meeting: MeetingPaths, track: TrackKind) {
        let url = self.url(meeting, track: track)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: coverageURL(meeting, track: track))
    }

    /// 已完成识别的文件时间（秒）。指纹不一致时视为没有进度。
    public static func coveredUntil(meeting: MeetingPaths, track: TrackKind, key: SegmentLogKey) -> Double {
        guard FileManager.default.fileExists(atPath: url(meeting, track: track).path),
              let content = try? String(contentsOf: url(meeting, track: track), encoding: .utf8) else { return 0 }
        let first = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard first == "key " + key.fingerprint else { return 0 }
        let cover = coverageURL(meeting, track: track)
        guard let text = try? String(contentsOf: cover, encoding: .utf8),
              let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0 else { return 0 }
        return value
    }

    /// 记录这条音轨已经处理到的文件时间。调用方需先写好参数指纹。
    public static func writeCoveredUntil(_ seconds: Double, meeting: MeetingPaths, track: TrackKind) throws {
        let url = coverageURL(meeting, track: track)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try String(format: "%.4f\n", seconds).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func coverageURL(_ meeting: MeetingPaths, track: TrackKind) -> URL {
        meeting.rawDir.appendingPathComponent("segments_\(track.rawValue).cover")
    }
}

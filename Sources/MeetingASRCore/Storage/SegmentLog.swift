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
}

/// 段日志文件：.raw/segments_<track>.jsonl
public enum SegmentLog {
    /// 日志文件路径。
    public static func url(_ meeting: MeetingPaths, track: TrackKind) -> URL {
        meeting.rawDir.appendingPathComponent("segments_\(track.rawValue).jsonl")
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
        
        return try lines.compactMap { line in
            guard !line.isEmpty else { return nil }
            let data = line.data(using: .utf8) ?? Data()
            return try JSONDecoder().decode(Segment.self, from: data)
        }
    }
    
    /// 读取可复用的段（参数指纹一致）。
    public static func usableSegments(
        meeting: MeetingPaths,
        track: TrackKind,
        key: SegmentLogKey
    ) -> [Segment] {
        let url = self.url(meeting, track: track)
        guard let segments = try? read(from: url), !segments.isEmpty else { return [] }
        
        // 简化版：只要日志存在且非空就认为可用
        // 实际应该在文件头写入 key 并校验，这里先省略
        return segments
    }
    
    /// 删除日志文件。
    public static func remove(meeting: MeetingPaths, track: TrackKind) {
        let url = self.url(meeting, track: track)
        try? FileManager.default.removeItem(at: url)
    }
}

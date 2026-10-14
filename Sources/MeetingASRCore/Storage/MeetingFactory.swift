import Foundation

/// 创建会议目录与初始 meta。
public enum MeetingFactory {
    /// 文件识别（FR-F1、F4）：目录名使用源文件名，源文件不复制、不删除。
    public static func createFileMeeting(source: URL, range: ClosedRange<Double>? = nil, expectedSpeakers: Int? = nil, layout: StorageLayout, date: Date = Date()) throws -> MeetingPaths {
        try layout.ensureDirectories()
        let title = source.deletingPathExtension().lastPathComponent
        let m = layout.meeting(named: layout.newMeetingName(date: date, title: title))
        try FileManager.default.createDirectory(at: m.rawDir, withIntermediateDirectories: true)
        var meta = MeetingMeta(title: title, createdAt: date, source: .file, status: .pending)
        meta.expectedSpeakers = expectedSpeakers
        meta.fileSource = FileSource(path: source.path, rangeStart: range?.lowerBound, rangeEnd: range?.upperBound)
        let src = try AudioFileOpener.open(source)
        meta.tracks = [TrackInfo(kind: .file, file: source.path, sampleRate: Double(src.sampleRate), channels: 1, sourceDescription: source.lastPathComponent)]
        let len = Double(src.frameCount) / Double(src.sampleRate)
        meta.durationSec = (range.map { min(len, $0.upperBound) - max(0, $0.lowerBound) }) ?? len
        try JSONIO.write(meta, to: m.meta)
        return m
    }

    /// 录音：创建目录与 .raw/，meta 状态为 recording。
    public static func createRecordingMeeting(title: String, expectedSpeakers: Int?, layout: StorageLayout, date: Date = Date()) throws -> (MeetingPaths, MeetingMeta) {
        try layout.ensureDirectories()
        let m = layout.meeting(named: layout.newMeetingName(date: date, title: title))
        try FileManager.default.createDirectory(at: m.rawDir, withIntermediateDirectories: true)
        var meta = MeetingMeta(title: title.isEmpty ? "会议" : title, createdAt: date, source: .recording, status: .recording)
        meta.expectedSpeakers = expectedSpeakers
        try JSONIO.write(meta, to: m.meta)
        return (m, meta)
    }
}

import Foundation

/// 会议列表项（菜单"最近会议"）。
public struct MeetingSummary: Sendable, Hashable, Identifiable {
    public var id: String { paths.name }
    public let paths: MeetingPaths
    public let title: String
    public let createdAt: Date
    public let status: MeetingStatus
    public let durationSec: Double
}

/// 会议目录的读写与查询。
public struct MeetingStore: Sendable {
    public let layout: StorageLayout

    public init(layout: StorageLayout) {
        self.layout = layout
    }

    public func loadMeta(_ m: MeetingPaths) throws -> MeetingMeta {
        try JSONIO.read(MeetingMeta.self, from: m.meta)
    }

    public func saveMeta(_ meta: MeetingMeta, _ m: MeetingPaths) throws {
        try JSONIO.write(meta, to: m.meta)
    }

    /// 读取 meta 并修改后写回。
    @discardableResult
    public func updateMeta(_ m: MeetingPaths, _ body: (inout MeetingMeta) -> Void) throws -> MeetingMeta {
        var meta = try loadMeta(m)
        body(&meta)
        try saveMeta(meta, m)
        return meta
    }

    public func loadTranscript(_ m: MeetingPaths) throws -> Transcript {
        try JSONIO.read(Transcript.self, from: m.transcriptJSON)
    }

    public func loadSpeakers(_ m: MeetingPaths) throws -> SpeakersFile {
        try JSONIO.read(SpeakersFile.self, from: m.speakersJSON)
    }

    /// 所有会议，按创建时间倒序。
    public func allMeetings() -> [MeetingSummary] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: layout.meetingsDir.path) else { return [] }
        var result: [MeetingSummary] = []
        for name in names where !name.hasPrefix(".") {
            let paths = layout.meeting(named: name)
            guard let meta = try? loadMeta(paths) else { continue }
            result.append(MeetingSummary(paths: paths, title: meta.title, createdAt: meta.createdAt, status: meta.status, durationSec: meta.durationSec))
        }
        return result.sorted { ($0.createdAt, $0.paths.name) > ($1.createdAt, $1.paths.name) }
    }

    /// 最近 N 条（FR-S5，默认 10 条）。
    public func recentMeetings(limit: Int = 10) -> [MeetingSummary] {
        Array(allMeetings().prefix(limit))
    }

    /// 已完成识别的最近一条。
    public func latestCompleted() -> MeetingSummary? {
        allMeetings().first { $0.status == .done }
    }

    /// 异常退出后遗留、仍有原始音频但未识别完成的会议（FR-R9）。
    /// `excluding` 用于排除当前正在录音或排队中的会议。
    public func unfinishedMeetings(excluding: Set<String> = []) -> [MeetingSummary] {
        allMeetings().filter { s in
            !excluding.contains(s.paths.name) && s.status != .done && s.paths.hasRawAudio
        }
    }

    /// 异常退出时仍处于"录音中"的会议：根据已写入的音频修正时长并转为待识别。
    /// 返回修正后的 meta；不需要修正时返回 nil。
    @discardableResult
    public func recoverInterruptedRecording(_ m: MeetingPaths) throws -> MeetingMeta? {
        var meta = try loadMeta(m)
        guard meta.status == .recording else { return nil }
        var duration = 0.0
        var tracks: [TrackInfo] = []
        for t in meta.tracks {
            let url = m.dir.appendingPathComponent(t.file)
            guard let r = try? WavReader(url: url), r.frameCount > 0 else { continue }
            duration = max(duration, r.durationSec)
            tracks.append(t)
        }
        meta.tracks = tracks
        meta.durationSec = duration
        if let i = meta.pauses.indices.last, meta.pauses[i].resumedAt == nil {
            meta.pauses.remove(at: i)
        }
        meta.status = tracks.isEmpty ? .failed : .pending
        if tracks.isEmpty { meta.error = "录音中断且没有可用音频" }
        try saveMeta(meta, m)
        return meta
    }
}

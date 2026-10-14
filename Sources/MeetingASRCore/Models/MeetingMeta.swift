import Foundation

/// 会议处理状态（meta.json `status`）。
public enum MeetingStatus: String, Codable, Sendable {
    /// 正在录音（含暂停）
    case recording
    /// 录音结束，等待识别
    case pending
    /// 识别中
    case processing
    /// 识别完成
    case done
    /// 识别失败（原始音频保留，可重试）
    case failed
    /// 用户取消（原始音频保留，可重试）
    case cancelled
}

public enum MeetingSourceKind: String, Codable, Sendable {
    /// 菜单栏录音
    case recording
    /// 识别音频文件
    case file
}

/// 单条音轨的录制信息。
public struct TrackInfo: Codable, Equatable, Sendable {
    public var kind: TrackKind
    /// 相对于会议目录的路径，如 `.raw/mic.wav`
    public var file: String
    public var sampleRate: Double
    public var channels: Int
    /// 首帧主机时间（mach host time 换算的秒），用于对齐
    public var firstHostTime: Double?
    /// 来源说明（进程 Bundle ID 或输入设备名）
    public var sourceDescription: String?

    public init(kind: TrackKind, file: String, sampleRate: Double, channels: Int, firstHostTime: Double? = nil, sourceDescription: String? = nil) {
        self.kind = kind
        self.file = file
        self.sampleRate = sampleRate
        self.channels = channels
        self.firstHostTime = firstHostTime
        self.sourceDescription = sourceDescription
    }

    enum CodingKeys: String, CodingKey {
        case kind, file, sampleRate = "sample_rate", channels, firstHostTime = "first_host_time", sourceDescription = "source"
    }
}

/// 暂停区间。
public struct PauseInterval: Codable, Equatable, Sendable {
    /// 暂停时已录音频时长（秒）
    public var audioOffset: Double
    public var pausedAt: Date
    public var resumedAt: Date?
    /// 暂停原因：user / sleep
    public var reason: String?

    public init(audioOffset: Double, pausedAt: Date, resumedAt: Date? = nil, reason: String? = nil) {
        self.audioOffset = audioOffset
        self.pausedAt = pausedAt
        self.resumedAt = resumedAt
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case audioOffset = "audio_offset", pausedAt = "paused_at", resumedAt = "resumed_at", reason
    }
}

/// 文件识别来源。
public struct FileSource: Codable, Equatable, Sendable {
    public var path: String
    /// 识别范围起点（秒），nil 表示从头
    public var rangeStart: Double?
    /// 识别范围终点（秒），nil 表示到结尾
    public var rangeEnd: Double?

    public init(path: String, rangeStart: Double? = nil, rangeEnd: Double? = nil) {
        self.path = path
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
    }

    enum CodingKeys: String, CodingKey {
        case path, rangeStart = "range_start", rangeEnd = "range_end"
    }
}

/// meta.json：来源、时长、暂停区间、模型版本、处理状态。
public struct MeetingMeta: Codable, Equatable, Sendable {
    public var title: String
    public var createdAt: Date
    public var source: MeetingSourceKind
    public var tracks: [TrackInfo]
    public var pauses: [PauseInterval]
    public var durationSec: Double
    /// 用户填写的预计说话人数（nil 为自动）
    public var expectedSpeakers: Int?
    public var fileSource: FileSource?
    public var status: MeetingStatus
    public var error: String?
    public var models: ModelVersions?
    public var processingStartedAt: Date?
    public var processingFinishedAt: Date?
    /// 原始音频删除时间
    public var rawDeletedAt: Date?

    public init(
        title: String,
        createdAt: Date,
        source: MeetingSourceKind,
        tracks: [TrackInfo] = [],
        pauses: [PauseInterval] = [],
        durationSec: Double = 0,
        expectedSpeakers: Int? = nil,
        fileSource: FileSource? = nil,
        status: MeetingStatus = .recording
    ) {
        self.title = title
        self.createdAt = createdAt
        self.source = source
        self.tracks = tracks
        self.pauses = pauses
        self.durationSec = durationSec
        self.expectedSpeakers = expectedSpeakers
        self.fileSource = fileSource
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case title, createdAt = "created_at", source, tracks, pauses, durationSec = "duration_sec"
        case expectedSpeakers = "expected_speakers", fileSource = "file_source", status, error, models
        case processingStartedAt = "processing_started_at", processingFinishedAt = "processing_finished_at"
        case rawDeletedAt = "raw_deleted_at"
    }

    public func track(_ kind: TrackKind) -> TrackInfo? {
        tracks.first { $0.kind == kind }
    }
}

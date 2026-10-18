import Foundation
import MeetingASRCore
import os

/// 一次录音会话：麦克风与会议软件两轨独立录制（FR-A4），统一会话时钟，元数据实时落盘。
@MainActor
final class RecordingSession {
    /// 模型输入就是 16 kHz。采集侧在回调里从设备采样率转过来，文件里不再存 48 kHz。
    static let trackSampleRate = 16_000

    let meeting: MeetingPaths
    private(set) var meta: MeetingMeta
    private let store: MeetingStore
    private let clock = SessionClock()
    private var micWriter: AlignedTrackWriter?
    private var appWriter: AlignedTrackWriter?
    private var mic: MicRecorder?
    private var tap: ProcessTapRecorder?
    private var flushTimer: Timer?
    private let log = Logger(subsystem: "com.meetingasr.app", category: "session")

    /// 会议软件 Tap 挂载状态变化
    var onTapStatus: ((Bool, [String]) -> Void)?
    var onMicDeviceChange: ((String) -> Void)?
    /// 已经对齐并写入 WAV 的 16 kHz 样本。在音频 IO 队列回调，不能阻塞。
    var onTrackSamples: ((TrackKind, [Float], Double) -> Void)?

    var state: RecorderState { clock.state }
    var elapsed: Double { clock.elapsed(now: HostTime.now) }
    var micDeviceName: String? { mic?.deviceName }

    struct Options {
        var title: String
        var expectedSpeakers: Int?
        var includeMic: Bool
        var includeApp: Bool
        var apps: [CaptureApp]
        var micDeviceUID: String?
        var voiceProcessing: Bool
    }

    init(options: Options, layout: StorageLayout) throws {
        store = MeetingStore(layout: layout)
        let (m, meta) = try MeetingFactory.createRecordingMeeting(title: options.title, expectedSpeakers: options.expectedSpeakers, layout: layout)
        self.meeting = m
        self.meta = meta
        self.options = options
    }

    private let options: Options

    func start() throws {
        let host = HostTime.now
        clock.start(at: host)
        var tracks: [TrackInfo] = []
        do {
            let forward = onTrackSamples
            if options.includeMic {
                let w = try AlignedTrackWriter(kind: .mic, url: meeting.rawTrack(.mic), sampleRate: Self.trackSampleRate, clock: clock)
                w.onSamplesWritten = { samples, sessionStart in forward?(.mic, samples, sessionStart) }
                let r = MicRecorder(writer: w, preferredDeviceUID: options.micDeviceUID, voiceProcessing: options.voiceProcessing)
                r.onDeviceChange = { [weak self] name in self?.onMicDeviceChange?(name) }
                try r.start()
                micWriter = w
                mic = r
                tracks.append(TrackInfo(kind: .mic, file: ".raw/mic.wav", sampleRate: Double(Self.trackSampleRate), channels: 1, sourceDescription: r.deviceName))
            }
            if options.includeApp {
                let w = try AlignedTrackWriter(kind: .system, url: meeting.rawTrack(.system), sampleRate: Self.trackSampleRate, clock: clock)
                w.onSamplesWritten = { samples, sessionStart in forward?(.system, samples, sessionStart) }
                let t = ProcessTapRecorder(apps: options.apps, writer: w)
                t.onStatusChange = { [weak self] attached, ids in self?.onTapStatus?(attached, ids) }
                try t.start()
                appWriter = w
                tap = t
                tracks.append(TrackInfo(kind: .system, file: ".raw/system.wav", sampleRate: Double(Self.trackSampleRate), channels: 1,
                                        sourceDescription: t.capturedBundleIDs.joined(separator: ",")))
            }
        } catch {
            stopRecorders()
            try? FileManager.default.removeItem(at: meeting.dir)
            throw error
        }
        meta.tracks = tracks
        meta.status = .recording
        saveMeta()
        // 定期刷新 WAV 头与时长，异常退出后可恢复（FR-R9）
        flushTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.periodicFlush() }
        }
    }

    /// 暂停（FR-R3）：暂停期间不写入音频，暂停区间记入元数据。
    func pause(reason: String = "user") {
        guard clock.state == .recording else { return }
        let offset = clock.pause(at: HostTime.now)
        meta.pauses.append(PauseInterval(audioOffset: offset, pausedAt: Date(), reason: reason))
        meta.durationSec = offset
        micWriter?.flushHeader()
        appWriter?.flushHeader()
        saveMeta()
    }

    func resume() {
        guard clock.state == .paused else { return }
        clock.resume(at: HostTime.now)
        if let i = meta.pauses.indices.last { meta.pauses[i].resumedAt = Date() }
        saveMeta()
    }

    /// 停止录音，关闭文件，返回待识别的会议。
    func stop() -> MeetingPaths {
        let total = clock.stop(at: HostTime.now)
        flushTimer?.invalidate()
        flushTimer = nil
        stopRecorders()
        if let i = meta.pauses.indices.last, meta.pauses[i].resumedAt == nil {
            // 暂停状态下直接停止：最后一个暂停区间不算中途暂停
            meta.pauses.removeLast()
        }
        var tracks: [TrackInfo] = []
        for var t in meta.tracks {
            let w = t.kind == .mic ? micWriter : appWriter
            try? w?.close()
            if let w, let first = w.firstHostTime, w.durationSec > 0.5 {
                t.firstHostTime = first
                if t.kind == .system, let tap { t.sourceDescription = tap.capturedBundleIDs.joined(separator: ",") }
                tracks.append(t)
            } else {
                // 该轨没有采到音频（例如会议软件全程未发声）
                try? FileManager.default.removeItem(at: meeting.rawTrack(t.kind))
            }
        }
        meta.tracks = tracks
        meta.durationSec = total
        meta.status = tracks.isEmpty ? .failed : .pending
        if tracks.isEmpty { meta.error = "没有录到任何音频" }
        saveMeta()
        return meeting
    }

    private func stopRecorders() {
        mic?.stop()
        tap?.stop()
        mic = nil
        tap = nil
    }

    private func periodicFlush() {
        micWriter?.flushHeader()
        appWriter?.flushHeader()
        meta.durationSec = elapsed
        if let w = micWriter, let i = meta.tracks.firstIndex(where: { $0.kind == .mic }) { meta.tracks[i].firstHostTime = w.firstHostTime }
        if let w = appWriter, let i = meta.tracks.firstIndex(where: { $0.kind == .system }) { meta.tracks[i].firstHostTime = w.firstHostTime }
        saveMeta()
    }

    private func saveMeta() {
        do { try store.saveMeta(meta, meeting) } catch { log.error("save meta failed: \(String(describing: error), privacy: .public)") }
    }

    var isTapAttached: Bool { tap?.isAttached ?? false }
}

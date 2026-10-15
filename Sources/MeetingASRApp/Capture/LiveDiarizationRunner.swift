import Foundation
import MeetingASRCore
import MeetingASREngine
import os

/// 录音期间在后台低优先级队列上定期调用 LiveDiarizer：每录满一块就提前分离，
/// 结果写入 `.raw/diarization_<track>.json`，停止后识别时直接复用。
final class LiveDiarizationRunner: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.meetingasr.live-diarization", qos: .utility)
    /// 分离引擎在多次录音之间复用（只在 queue 上访问）
    private static var diarizer: SpeakerDiarizer?
    /// 录音时只用少量线程，不影响会议软件与录音
    private static let numThreads = 2
    /// 检查录音文件新增内容的间隔（秒）
    private static let interval = 30

    private let meeting: MeetingPaths
    private let track: TrackKind
    private let recognition: RecognitionSettings
    private let stopped = CancellationFlag()
    private var live: LiveDiarizer?
    private let timer: DispatchSourceTimer
    private let log = Logger(subsystem: "com.meetingasr.app", category: "live-diarization")

    init(meeting: MeetingPaths, track: TrackKind, recognition: RecognitionSettings) {
        self.meeting = meeting
        self.track = track
        self.recognition = recognition
        timer = DispatchSource.makeTimerSource(queue: Self.queue)
        timer.schedule(deadline: .now() + .seconds(Self.interval), repeating: .seconds(Self.interval), leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
    }

    private func tick() {
        guard !stopped.isCancelled else { return }
        do {
            if live == nil {
                if Self.diarizer == nil {
                    guard let paths = ModelPaths.locate() else { return }
                    Self.diarizer = try SherpaDiarizer(paths: paths, numThreads: Self.numThreads)
                }
                guard let diarizer = Self.diarizer else { return }
                let config = BlockDiarizationConfig()
                let key = DiarizationCache.Key(track: track, recognition: recognition, config: config, models: .bundled)
                live = LiveDiarizer(source: meeting.rawTrack(track), cacheURL: DiarizationCache.url(meeting, track: track), key: key,
                                    recognition: recognition, diarizer: diarizer, config: config,
                                    isStopped: { [stopped] in stopped.isCancelled })
            }
            guard let live else { return }
            let t0 = Date()
            if try live.step() > 0 {
                log.info("diarized block \(live.completedBlocks, privacy: .public) in \(Date().timeIntervalSince(t0), format: .fixed(precision: 1), privacy: .public)s")
            }
        } catch {
            // 失败只影响提速，识别时会重新分离
            log.error("live diarization failed: \(String(describing: error), privacy: .public)")
            timer.cancel()
        }
    }

    /// 停止后台分离。进行中的块完成并写入缓存后，在主线程回调（之后再开始识别，避免两边同时分离同一段）。
    func finish(_ completion: @escaping @MainActor () -> Void) {
        stopped.cancel()
        timer.cancel()
        Self.queue.async {
            DispatchQueue.main.async { MainActor.assumeIsolated { completion() } }
        }
    }
}

import Foundation
import MeetingASRCore
import MeetingASREngine
import os

/// 录音期间把已经对齐的 16 kHz 样本送进段识别。模型加载失败或模型没有字级时间戳时自动退回会后整段识别。
final class LiveRecognitionRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "meetingasr.live-recognition", qos: .utility)
    private let meeting: MeetingPaths
    private let tracks: [TrackKind]
    private let recognition: RecognitionSettings
    private let log = Logger(subsystem: "com.meetingasr.app", category: "live-recognition")
    private var coordinator: LiveSegmentCoordinator?
    private var engines: EngineSet?
    private var failed = false

    init(meeting: MeetingPaths, tracks: [TrackKind], recognition: RecognitionSettings) {
        self.meeting = meeting
        self.tracks = tracks
        self.recognition = recognition
    }

    func accept(track: TrackKind, _ samples: [Float], sessionStart: Double) {
        queue.async { [samples] in
            self.startIfNeeded()
            self.coordinator?.accept(track: track, samples: samples, sessionStart: sessionStart)
        }
    }

    func pause() {
        queue.async { self.coordinator?.pause() }
    }

    func resume() {
        // 暂停时已经冲掉并重置了 VAD，恢复后继续送样本即可。
    }

    /// 等已经入队的段写完日志，再回到主线程。停止录音后调用，然后再开始会后处理。
    func finish(_ completion: @escaping @MainActor () -> Void) {
        queue.async {
            self.coordinator?.finish()
            DispatchQueue.main.async { MainActor.assumeIsolated { completion() } }
        }
    }

    private func startIfNeeded() {
        guard coordinator == nil, !failed else { return }
        do {
            guard let paths = ModelPaths.locate() else {
                failed = true
                log.error("live recognition skipped: models missing")
                return
            }
            let engines = try SherpaEngineFactory.make(
                paths: paths,
                numThreads: 2,
                asrModel: recognition.asrModel,
                provider: recognition.inferenceProvider.providerString,
                vadConfig: recognition.segmentVAD,
                loadDiarizer: false
            )
            self.engines = engines
            guard engines.recognizer.providesTimestamps else {
                failed = true
                log.info("live recognition skipped: model has no token timestamps")
                return
            }
            var vads: [TrackKind: StreamingVAD] = [:]
            for track in tracks {
                vads[track] = try SherpaStreamingVAD(paths: paths, config: recognition.segmentVAD)
            }
            let embeddingTracks: Set<TrackKind> = tracks.contains(.mic) && tracks.contains(.system) ? [.system] : Set(tracks)
            coordinator = try LiveSegmentCoordinator(
                meeting: meeting,
                tracks: tracks,
                vadConfig: recognition.segmentVAD,
                clustering: recognition.segmentClustering,
                maxASRSec: recognition.asrModel.maxASRSegmentSec,
                asrModel: engines.recognizer.modelName,
                embeddingModel: engines.embedder.modelName,
                makeVAD: { track in
                    guard let vad = vads[track] else { preconditionFailure("missing vad for \(track)") }
                    return vad
                },
                recognizer: engines.recognizer,
                embedder: engines.embedder,
                embeddingTracks: embeddingTracks
            )
        } catch {
            failed = true
            log.error("live recognition failed: \(String(describing: error), privacy: .public)")
        }
    }
}

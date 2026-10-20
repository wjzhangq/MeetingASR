import Foundation

/// 录音期间按 VAD 段做识别和声纹。采集线程只负责把已经对齐的 16 kHz 样本送进来；
/// 队列满时不阻塞调用方，没排上的尾部留到会后从文件补。
public final class LiveSegmentCoordinator: @unchecked Sendable {
    private final class Job {
        let segment: Segment
        let audio: [Float]
        let embed: Bool
        init(segment: Segment, audio: [Float], embed: Bool) {
            self.segment = segment
            self.audio = audio
            self.embed = embed
        }
    }

    private final class Lane {
        let kind: TrackKind
        let segmenter: SegmentVAD
        let window = PCMWindow()
        let logURL: URL
        var sessionOrigin: Double?
        var coveredUntil: Double = 0
        var ordered: [Segment] = []
        var done: [Int: Segment] = [:]
        var stalled = false
        var dropped = false

        init(kind: TrackKind, segmenter: SegmentVAD, logURL: URL) {
            self.kind = kind
            self.segmenter = segmenter
            self.logURL = logURL
        }

        var totalFileSec: Double { Double(window.endIndex) / Double(segmenterSampleRate) }
        var segmenterSampleRate: Int { window.sampleRate }
    }

    private let meeting: MeetingPaths
    private let sampleRate: Int
    private let vadConfig: SegmentVADConfig
    private let pipeline: SegmentPipeline
    private let recognizer: SpeechRecognizer
    private let embedder: SpeakerEmbedder
    private let embeddingTracks: Set<TrackKind>
    private let echo: EchoDetector
    private let echoLagSec: Double
    private let maxQueued: Int
    private let maxPending: Int
    private let retainSec: Double
    private var lanes: [TrackKind: Lane] = [:]
    private var waiting: [Job] = []
    private var overflow: [Job] = []
    private var running = 0
    private let lock = NSLock()
    private let idle = NSCondition()
    private let workQueue = DispatchQueue(label: "meetingasr.live.segment", qos: .utility)

    public init(
        meeting: MeetingPaths,
        tracks: [TrackKind],
        vadConfig: SegmentVADConfig = SegmentVADConfig(),
        clustering: SegmentClusteringConfig = SegmentClusteringConfig(),
        sampleRate: Int = 16_000,
        maxASRSec: Double = 60,
        asrModel: String,
        embeddingModel: String,
        makeVAD: (TrackKind) -> StreamingVAD,
        recognizer: SpeechRecognizer,
        embedder: SpeakerEmbedder,
        embeddingTracks: Set<TrackKind>,
        echo: EchoDetector = EchoDetector(),
        maxQueued: Int = 2,
        maxPending: Int = 4
    ) throws {
        self.meeting = meeting
        self.sampleRate = sampleRate
        self.vadConfig = vadConfig
        self.pipeline = SegmentPipeline(config: clustering, sampleRate: sampleRate, maxASRSec: maxASRSec)
        self.recognizer = recognizer
        self.embedder = embedder
        self.embeddingTracks = embeddingTracks
        self.echo = echo
        self.echoLagSec = echo.maxDelay
        self.maxQueued = max(1, maxQueued)
        self.maxPending = max(0, maxPending)
        self.retainSec = Double(vadConfig.maxSpeechDuration) + 36
        for kind in tracks {
            let key = SegmentLogKey(track: kind, vadConfig: vadConfig, asrModel: asrModel, embeddingModel: embeddingModel)
            let url = SegmentLog.url(meeting, track: kind)
            if SegmentLog.usableSegments(meeting: meeting, track: kind, key: key).isEmpty {
                SegmentLog.remove(meeting: meeting, track: kind)
                try SegmentLog.create(url, key: key)
            }
            let lane = Lane(kind: kind, segmenter: SegmentVAD(vad: makeVAD(kind), track: kind, config: vadConfig, sampleRate: sampleRate), logURL: url)
            lane.window.sampleRate = sampleRate
            lane.coveredUntil = SegmentLog.coveredUntil(meeting: meeting, track: kind, key: key)
            lanes[kind] = lane
        }
    }

    /// 追加这一轨刚写入 WAV 的样本。`sessionStart` 是这批样本第一帧的会话时间。
    public func accept(track: TrackKind, samples: [Float], sessionStart: Double) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let lane = lanes[track], !lane.stalled else { return }
        if lane.sessionOrigin == nil { lane.sessionOrigin = sessionStart }
        lane.window.append(samples)
        lane.segmenter.accept(samples)
        collect(lane)
    }

    /// 暂停：冲出当前语音，并让下一段从暂停后的文件时间重新计。
    public func pause() {
        lock.lock()
        defer { lock.unlock() }
        for lane in lanes.values {
            lane.segmenter.flush()
            collect(lane)
            lane.segmenter.continueAfterPause()
        }
    }

    /// 停止录音后调用。会等已经入队的段做完，再把覆盖进度写盘。
    public func finish() {
        let start = Date()
        idle.lock()
        lock.lock()
        for lane in lanes.values where !lane.stalled {
            lane.segmenter.flush()
            collect(lane)
        }
        let pendingCount = waiting.count + overflow.count + (running > 0 ? 1 : 0)
        lock.unlock()

        if pendingCount > 0 {
            print("LiveSegmentCoordinator.finish: 等待 \(pendingCount) 个段完成...")
        }

        while true {
            lock.lock()
            let idleNow = running == 0 && waiting.isEmpty && overflow.isEmpty
            lock.unlock()
            if idleNow { break }
            idle.wait()
        }

        let elapsed = Date().timeIntervalSince(start)
        if elapsed > 5 {
            print("⚠️ LiveSegmentCoordinator.finish 耗时 \(String(format: "%.1f", elapsed))秒")
        }

        lock.lock()
        for lane in lanes.values {
            if !lane.dropped && !lane.stalled {
                lane.coveredUntil = max(lane.coveredUntil, lane.totalFileSec)
            }
            try? SegmentLog.writeCoveredUntil(lane.coveredUntil, meeting: meeting, track: lane.kind)
        }
        lock.unlock()
        idle.unlock()
    }

    // MARK: - 切段

    private func collect(_ lane: Lane) {
        guard !lane.stalled else { return }
        var produced = 0
        while let seg = lane.segmenter.nextSegment() {
            take(seg, lane: lane)
            produced += 1
            if produced > 64 || lane.stalled { break }
        }
        guard !lane.stalled else { return }
        enforceCap(lane)
        trim(lane)
    }

    /// 流式 VAD 若迟迟不闭合，就按最长语音段切开，避免把整场会议留在内存里。
    private func enforceCap(_ lane: Lane) {
        let maxSec = Double(vadConfig.maxSpeechDuration)
        // 不再要求 ordered 为空，否则一个长段在处理期间后续音频无法切分。
        // 但切点必须从"已分配的最远点"起算：coveredUntil 只在段完成后才推进，
        // 直接用它会和正在处理的段重叠，导致同一段音频识别两次。
        let furthest = max(lane.coveredUntil, lane.ordered.map(\.end).max() ?? 0)
        let uncovered = lane.totalFileSec - furthest
        guard uncovered > maxSec + 1 else { return }

        if uncovered > maxSec * 2 {
            print("⚠️ [\(lane.kind)] 未分配音频 \(String(format: "%.1f", uncovered))秒，强制切分")
        }

        let cut = min(lane.totalFileSec, furthest + maxSec)
        let rate = sampleRate
        let audio = lane.window.slice(from: Int(furthest * Double(rate)), to: Int(cut * Double(rate)))
        let replay = lane.window.slice(from: Int(cut * Double(rate)), to: lane.window.endIndex)
        lane.segmenter.restart(at: cut, replay: replay)
        if SignalStats.rms(audio) <= 0.01 {
            // 静音：只有在没有段在排队时才能直接推进 coveredUntil，
            // 否则 advance() 会用已完成段的 end 覆盖它。
            if lane.ordered.isEmpty { lane.coveredUntil = cut }
            var extra = 0
            while let seg = lane.segmenter.nextSegment() {
                take(seg, lane: lane)
                extra += 1
                if extra > 16 || lane.stalled { break }
            }
            return
        }
        take(lane.segmenter.makeSegment(speechStart: furthest, speechEnd: cut), lane: lane)
    }

    private func take(_ segment: Segment, lane: Lane) {
        guard !lane.stalled else { return }
        guard segment.end > segment.start else { return }
        let audio = lane.window.slice(
            from: Int(segment.start * Double(sampleRate)),
            to: Int(segment.end * Double(sampleRate))
        )
        guard audio.count >= sampleRate / 20 else {
            lane.dropped = true
            lane.stalled = true
            return
        }
        if looksLikeEcho(segment, audio: audio, lane: lane) {
            var echoSeg = segment
            echoSeg.isEcho = true
            lane.ordered.append(echoSeg)
            lane.done[echoSeg.id] = echoSeg
            advance(lane)
            return
        }
        let job = Job(segment: segment, audio: audio, embed: embeddingTracks.contains(lane.kind))
        lane.ordered.append(segment)
        if submit(job) { return }
        if overflow.count >= maxPending {
            lane.ordered.removeAll { $0.id == segment.id }
            lane.dropped = true
            lane.stalled = true
            return
        }
        overflow.append(job)
    }

    private func looksLikeEcho(_ segment: Segment, audio: [Float], lane: Lane) -> Bool {
        guard lane.kind == .mic, let system = lanes[.system],
              let micOrigin = lane.sessionOrigin, let sysOrigin = system.sessionOrigin else { return false }
        let sessionEnd = micOrigin + segment.end
        guard sysOrigin + system.totalFileSec >= sessionEnd + echoLagSec else { return false }
        let sysStart = micOrigin + segment.start - sysOrigin
        let sysEnd = sessionEnd + echoLagSec - sysOrigin
        let remote = system.window.slice(from: Int(sysStart * Double(sampleRate)), to: Int(sysEnd * Double(sampleRate)))
        return echo.isEcho(mic: audio, system: remote, sampleRate: sampleRate)
    }

    private func trim(_ lane: Lane) {
        let hold = lane.ordered.map(\.start).min() ?? lane.coveredUntil
        let keep = max(0, hold - 1)
        lane.window.drop(before: Int(keep * Double(sampleRate)))
        if Double(lane.window.count) / Double(sampleRate) > retainSec {
            lane.dropped = true
            lane.stalled = true
            lane.window.removeAll()
        }
    }

    private func advance(_ lane: Lane) {
        while let first = lane.ordered.first, let finished = lane.done[first.id] {
            lane.ordered.removeFirst()
            lane.done[first.id] = nil
            // 段按 VAD 顺序完成。两段之间的静音没有单独的段，直接把覆盖推进到这段结束。
            lane.coveredUntil = max(lane.coveredUntil, finished.end)
            try? SegmentLog.append(finished, to: lane.logURL)
            try? SegmentLog.writeCoveredUntil(lane.coveredUntil, meeting: meeting, track: lane.kind)
        }
    }

    // MARK: - 工人

    /// 调用方持有 `lock`。
    private func submit(_ job: Job) -> Bool {
        guard running + waiting.count < maxQueued else { return false }
        waiting.append(job)
        pumpWorkers()
        return true
    }

    /// 调用方持有 `lock`。同一时刻只跑一段，避免共享同一个识别器。
    private func pumpWorkers() {
        guard running == 0, !waiting.isEmpty else { return }
        let job = waiting.removeFirst()
        running = 1
        workQueue.async { [weak self] in
            guard let self else { return }
            let result = self.execute(job)
            self.finishJob(job, result: result)
        }
    }

    private func execute(_ job: Job) -> Segment? {
        let audio = normalized(job.audio)
        var local = job.segment
        let origin = job.segment.start
        local.start = 0
        local.end = Double(audio.count) / Double(sampleRate)
        local.speechStart = max(0, job.segment.speechStart - origin)
        local.speechEnd = max(local.speechStart, job.segment.speechEnd - origin)
        let processed: [Segment]
        do {
            processed = try pipeline.process(
                [local], samples: audio, recognizer: recognizer, embedder: embedder, extractEmbeddings: job.embed)
        } catch {
            return nil
        }
        guard let out = processed.first else { return nil }
        var result = out
        result.id = job.segment.id
        result.track = job.segment.track
        result.start = job.segment.start
        result.end = job.segment.end
        result.speechStart = job.segment.speechStart
        result.speechEnd = job.segment.speechEnd
        result.tokens = out.tokens.map { TranscriptToken(t: $0.t, start: $0.start + origin) }
        result.subwindows = out.subwindows.map { sw in
            var copy = sw
            copy.start += origin
            copy.end += origin
            return copy
        }
        return result
    }

    private func normalized(_ audio: [Float]) -> [Float] {
        Preprocessor.normalize(audio, sampleRate: sampleRate)
    }

    private func finishJob(_ job: Job, result: Segment?) {
        idle.lock()
        lock.lock()
        if let lane = lanes[job.segment.track] {
            if let result {
                lane.done[job.segment.id] = result
                advance(lane)
            } else {
                lane.dropped = true
            }
        }
        running = 0
        while !overflow.isEmpty, running + waiting.count < maxQueued {
            waiting.append(overflow.removeFirst())
        }
        pumpWorkers()
        let idleNow = running == 0 && waiting.isEmpty && overflow.isEmpty
        lock.unlock()
        if idleNow { idle.broadcast() }
        idle.unlock()
    }
}

/// 按绝对采样下标保存最近一段音频，供闭合的 VAD 段切片。
final class PCMWindow {
    var sampleRate = 16_000
    private var samples: [Float] = []
    private var head = 0
    private(set) var origin = 0

    var count: Int { samples.count - head }
    var endIndex: Int { origin + count }

    func append(_ chunk: [Float]) {
        if head > 65_536, head * 2 > samples.count {
            samples.removeFirst(head)
            head = 0
        }
        samples.append(contentsOf: chunk)
    }

    func slice(from: Int, to: Int) -> [Float] {
        let a = max(origin, from)
        let b = min(endIndex, to)
        guard b > a else { return [] }
        let start = head + (a - origin)
        let end = head + (b - origin)
        return Array(samples[start..<end])
    }

    func drop(before absolute: Int) {
        let remove = max(0, min(count, absolute - origin))
        head += remove
        origin += remove
    }

    func removeAll() {
        samples.removeAll(keepingCapacity: false)
        head = 0
        origin = 0
    }
}

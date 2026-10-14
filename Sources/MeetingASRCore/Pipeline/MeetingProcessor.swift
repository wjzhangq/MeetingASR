import Foundation

public enum ProcessingError: Error, CustomStringConvertible {
    case noAudio
    case missingTrack(String)
    case verificationFailed

    public var description: String {
        switch self {
        case .noAudio: return "没有可识别的音频"
        case .missingTrack(let s): return "找不到音轨文件：\(s)"
        case .verificationFailed: return "结果文件校验失败，已保留原始音频"
        }
    }
}

/// 单个会议的识别处理参数。
public struct ProcessingOptions: Sendable {
    public var recognition: RecognitionSettings
    public var hotwords: HotwordList
    public var segmenter: SegmenterConfig
    public var echo: EchoDetector
    /// 识别成功后删除原始音频（FR-P6）
    public var deleteRawOnSuccess: Bool

    public init(recognition: RecognitionSettings = RecognitionSettings(), hotwords: HotwordList = HotwordList(words: []), segmenter: SegmenterConfig = SegmenterConfig(), echo: EchoDetector = EchoDetector(), deleteRawOnSuccess: Bool = true) {
        self.recognition = recognition
        self.hotwords = hotwords
        self.segmenter = segmenter
        self.echo = echo
        self.deleteRawOnSuccess = deleteRawOnSuccess
    }
}

/// 识别流水线（3.3 / 4.x）：
/// 预处理 → 说话人分离 → 分段 ASR → 特征提取与人物匹配 → 合并输出 → 删除原始音频。
public final class MeetingProcessor {
    public let engines: EngineSet
    public let store: MeetingStore
    public let people: PeopleStore
    public var options: ProcessingOptions

    private static let sr = Preprocessor.targetRate

    public init(engines: EngineSet, store: MeetingStore, people: PeopleStore, options: ProcessingOptions) {
        self.engines = engines
        self.store = store
        self.people = people
        self.options = options
    }

    /// 处理中的一条音轨。
    struct PreparedTrack {
        let kind: TrackKind
        let reader: WavReader
        let gain: Float
        /// 在会议时间轴上的起点偏移（秒）
        let offset: Double
    }

    /// 处理一个会议。失败或取消时更新 meta 状态并保留原始音频，然后重新抛出错误。
    @discardableResult
    public func process(_ meeting: MeetingPaths, cancel: CancellationFlag = CancellationFlag(), progress: @escaping (ProcessingProgress) -> Void = { _ in }) throws -> Transcript {
        var meta = try store.loadMeta(meeting)
        meta.status = .processing
        meta.error = nil
        meta.processingStartedAt = Date()
        meta.models = engines.models
        try store.saveMeta(meta, meeting)
        do {
            let t = try run(meeting, meta: meta, cancel: cancel, progress: progress)
            try store.updateMeta(meeting) {
                $0.status = .done
                $0.processingFinishedAt = Date()
                if t.durationSec > 0 { $0.durationSec = t.durationSec }
            }
            progress(.at(.cleanup, 0))
            try cleanup(meeting, meta: meta)
            progress(.at(.cleanup, 1))
            return t
        } catch {
            let isCancel = error is CancellationError || cancel.isCancelled
            _ = try? store.updateMeta(meeting) {
                $0.status = isCancel ? .cancelled : .failed
                $0.error = isCancel ? nil : String(describing: error)
                $0.processingFinishedAt = Date()
            }
            // 删除中间文件，保留原始音频以便重试
            try? FileManager.default.removeItem(at: meeting.workDir)
            throw isCancel ? CancellationError() : error
        }
    }

    // MARK: - 主流程

    private func run(_ meeting: MeetingPaths, meta: MeetingMeta, cancel: CancellationFlag, progress: @escaping (ProcessingProgress) -> Void) throws -> Transcript {
        let rec = options.recognition
        try FileManager.default.createDirectory(at: meeting.workDir, withIntermediateDirectories: true)

        // 1. 预处理
        progress(.at(.preprocess, 0))
        let tracks = try prepareTracks(meeting, meta: meta, cancel: cancel) { progress(.at(.preprocess, $0)) }
        guard !tracks.isEmpty else { throw ProcessingError.noAudio }
        let duration = tracks.map { $0.offset + $0.reader.durationSec }.max() ?? 0

        // 2. 说话人分离（4.3）
        let twoTrack = tracks.contains { $0.kind == .mic } && tracks.contains { $0.kind == .system }
        var perTrack: [[ASRSegment]] = []
        let segmenter = Segmenter(config: options.segmenter)
        for (ti, track) in tracks.enumerated() {
            try cancel.check()
            let base = Double(ti) / Double(tracks.count)
            let span = 1 / Double(tracks.count)
            progress(.at(.diarization, base))
            let samples = track.reader.readAllMono()
            let raw: [RawSpan]
            if twoTrack && track.kind == .mic {
                // 线上会议麦克风轨：整轨一个说话人，只做 VAD 切段
                raw = engines.vad.detect(samples).map { RawSpan(speaker: "mic", start: $0.lowerBound, end: $0.upperBound) }
            } else {
                var n = meta.expectedSpeakers ?? rec.defaultSpeakerCount
                if twoTrack, let k = n { n = max(1, k - 1) } // 预计人数含本人
                let opts = DiarizationOptions(numSpeakers: n, threshold: rec.clusterThreshold, minDurationOn: rec.minDurationOn, minDurationOff: rec.minDurationOff)
                raw = engines.diarizer.diarize(samples, options: opts) { p in
                    progress(.at(.diarization, base + span * p))
                    return !cancel.isCancelled
                }.map { RawSpan(speaker: "\(track.kind.rawValue)-\($0.speaker)", start: $0.start, end: $0.end) }
            }
            try cancel.check()
            let segs = segmenter.process(raw, track: track.kind, totalDuration: track.reader.durationSec, offset: track.offset) { s, e in
                self.silencePoints(in: samples, from: s, to: e)
            }
            perTrack.append(segs)
            progress(.at(.diarization, base + span))
        }
        var segments = Segmenter.combine(perTrack)

        // 回声判定（4.3 对策 2）
        if twoTrack, let mic = tracks.first(where: { $0.kind == .mic }), let sys = tracks.first(where: { $0.kind == .system }) {
            for i in segments.indices where segments[i].track == .mic {
                let a = read(mic, segments[i].start, segments[i].end)
                let b = read(sys, segments[i].start, segments[i].end)
                segments[i].isEcho = options.echo.isEcho(mic: a, system: b, micGain: mic.gain, systemGain: sys.gain)
            }
        }

        // 统一说话人标签：按首次发言顺序 S1、S2…
        let labels = assignLabels(segments.filter { !$0.isEcho })
        for i in segments.indices { segments[i].speaker = labels[segments[i].speaker] ?? segments[i].speaker }
        let trackOfSpeaker = Dictionary(segments.map { ($0.speaker, $0.track) }, uniquingKeysWith: { a, _ in a })

        // 3. 分段 ASR（4.4）
        let corrector = HotwordCorrector(hotwords: options.hotwords.adding(people.allNames))
        var out: [TranscriptSegment] = []
        let asrSegs = segments.filter { !$0.isEcho }
        for (i, seg) in asrSegs.enumerated() {
            try cancel.check()
            guard let track = tracks.first(where: { $0.kind == seg.track }) else { continue }
            let audio = read(track, seg.cropStart, seg.cropEnd)
            let r = engines.recognizer.recognize(audio)
            var text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                text = corrector.correct(text)
                if let p = engines.punctuator { text = p.punctuate(text) }
                let tokens = corrector.correct(tokens: r.tokens).map { TranscriptToken(t: $0.t, start: Self.round2($0.start + seg.cropStart)) }
                out.append(TranscriptSegment(speaker: seg.speaker, start: Self.round2(seg.start), end: Self.round2(seg.end), text: text, tokens: tokens.isEmpty ? nil : tokens))
            }
            progress(.at(.recognition, Double(i + 1) / Double(max(1, asrSegs.count))))
        }

        // 4. 特征片段与人物匹配（4.6）
        let spoken = Set(out.map(\.speaker))
        let speakerIDs = labels.values.filter { spoken.contains($0) }.sorted(by: Self.labelOrder)
        try FileManager.default.createDirectory(at: meeting.speakersDir, withIntermediateDirectories: true)
        var records: [SpeakerRecord] = []
        for (i, sid) in speakerIDs.enumerated() {
            try cancel.check()
            let segs = segments.filter { $0.speaker == sid }
            if let r = try extractSpeaker(sid, track: trackOfSpeaker[sid] ?? .file, segments: segs, tracks: tracks, meeting: meeting, duration: duration) {
                records.append(r)
            }
            progress(.at(.speakerID, 0.8 * Double(i + 1) / Double(max(1, speakerIDs.count))))
        }
        let matcher = SpeakerMatcher(threshold: rec.matchThreshold)
        let result = matcher.match(speakers: records.filter { !$0.embedding.isEmpty }.map { ($0.id, $0.embedding) }, people: people.people)
        var speakers: [TranscriptSpeaker] = speakerIDs.map { TranscriptSpeaker(id: $0, track: trackOfSpeaker[$0] ?? .file) }
        for i in records.indices {
            records[i].bestMatch = result.best[records[i].id]
            guard let m = result.assigned[records[i].id], let person = people.person(id: m.personId) else { continue }
            if let si = speakers.firstIndex(where: { $0.id == records[i].id }) {
                speakers[si].personId = person.id
                speakers[si].name = person.name
                speakers[si].source = .auto
            }
            // 自动识别结果也加入样本（用户改正时撤销）
            try people.addSample(personId: person.id, meeting: meeting.name, speaker: records[i].id, embedding: records[i].embedding,
                                 clipURLs: records[i].clips.map { meeting.clip($0.file) }, source: .auto)
            records[i].contributedTo = person.id
        }
        progress(.at(.speakerID, 1))

        // 5. 合并输出
        let transcript = Transcript(
            title: meta.title,
            createdAt: ISO8601.string(from: meta.createdAt),
            durationSec: Self.round2(duration),
            speakers: speakers,
            segments: out,
            pauses: meta.pauses.isEmpty ? nil : meta.pauses.map { PauseMark(at: Self.round2($0.audioOffset)) },
            models: engines.models
        )
        try JSONIO.write(SpeakersFile(matchThreshold: rec.matchThreshold, speakers: records), to: meeting.speakersJSON)
        try TranscriptWriter.writeAll(transcript, to: meeting)
        guard TranscriptWriter.verify(transcript, at: meeting),
              (try? store.loadSpeakers(meeting)) != nil,
              records.allSatisfy({ $0.clips.allSatisfy { FileManager.default.fileExists(atPath: meeting.clip($0.file).path) } }) else {
            throw ProcessingError.verificationFailed
        }
        progress(.at(.output, 1))
        return transcript
    }

    // MARK: - 预处理

    private func prepareTracks(_ meeting: MeetingPaths, meta: MeetingMeta, cancel: CancellationFlag, progress: @escaping (Double) -> Void) throws -> [PreparedTrack] {
        var sources: [(TrackInfo, URL)] = []
        for t in meta.tracks {
            let url = t.file.hasPrefix("/") ? URL(fileURLWithPath: t.file) : meeting.dir.appendingPathComponent(t.file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                if meta.tracks.count == 1 { throw ProcessingError.missingTrack(t.file) }
                continue
            }
            sources.append((t, url))
        }
        let hostTimes = sources.compactMap { $0.0.firstHostTime }
        let base = hostTimes.min()
        var prepared: [PreparedTrack] = []
        for (i, (info, url)) in sources.enumerated() {
            let src = try AudioFileOpener.open(url)
            guard src.frameCount > 0 else { continue }
            var range: ClosedRange<Double>?
            if meta.source == .file, let fs = meta.fileSource, fs.rangeStart != nil || fs.rangeEnd != nil {
                let len = Double(src.frameCount) / Double(src.sampleRate)
                let lo = max(0, fs.rangeStart ?? 0), hi = min(len, fs.rangeEnd ?? len)
                guard hi > lo else { throw ProcessingError.noAudio }
                range = lo...hi
            }
            let out = meeting.workDir.appendingPathComponent("\(info.kind.rawValue)_16k.wav")
            let res = try Preprocessor.process(source: src, range: range, output: out, isCancelled: { cancel.isCancelled }) { p in
                progress((Double(i) + p) / Double(sources.count))
            }
            let offset = (info.firstHostTime.map { $0 - (base ?? $0) }) ?? 0
            prepared.append(PreparedTrack(kind: info.kind, reader: try WavReader(url: res.url), gain: res.gain, offset: offset))
        }
        return prepared
    }

    // MARK: - 说话人特征

    private func extractSpeaker(_ sid: String, track: TrackKind, segments: [ASRSegment], tracks: [PreparedTrack], meeting: MeetingPaths, duration: Double) throws -> SpeakerRecord? {
        guard let tr = tracks.first(where: { $0.kind == track }) else { return nil }
        let rec = options.recognition
        let selector = ClipSelector(count: rec.clipsPerSpeaker, minSec: rec.clipMinSec, maxSec: rec.clipMaxSec)
        var cands = selector.candidates(from: segments)
        let total = segments.filter { !$0.isEcho }.reduce(0) { $0 + $1.duration }
        if cands.isEmpty {
            // 发言极少：取最长的一段
            guard let longest = segments.filter({ !$0.isEcho }).max(by: { $0.duration < $1.duration }) else { return nil }
            cands = [ClipCandidate(start: longest.start, end: min(longest.end, longest.start + rec.clipMaxSec))]
        }
        // 候选过多时均匀抽样，控制计算量
        let maxCands = 24
        if cands.count > maxCands {
            let step = Double(cands.count) / Double(maxCands)
            cands = (0..<maxCands).map { cands[Int(Double($0) * step)] }
        }
        let audios = cands.map { read(tr, $0.start, $0.end) }
        let embs = audios.map { engines.embedder.embed($0) }
        let overall = VectorMath.meanNormalized(embs.compactMap { $0 })
        let scores = zip(embs, audios).map { e, a -> Double in
            guard let e else { return 0 }
            return ClipSelector.score(similarity: overall.isEmpty ? 1 : VectorMath.cosine(e, overall), snrDB: SignalStats.estimateSNR(a))
        }
        let picked = selector.select(cands, scores: scores, meetingDuration: duration)
        var clips: [FeatureClip] = []
        var clipEmbs: [[Float]] = []
        for (k, (c, score)) in picked.enumerated() {
            let file = String(format: "%@_%02d.wav", sid, k + 1)
            let idx = cands.firstIndex(of: c)!
            try WavWriter.writeMono(audios[idx], sampleRate: Self.sr, to: meeting.clip(file))
            clips.append(FeatureClip(file: file, start: Self.round2(c.start), end: Self.round2(c.end), score: (score * 1000).rounded() / 1000))
            if let e = embs[idx] { clipEmbs.append(e) }
        }
        // 说话人声纹 = 所选片段声纹均值并归一化
        let embedding = clipEmbs.isEmpty ? overall : VectorMath.meanNormalized(clipEmbs)
        return SpeakerRecord(id: sid, track: track, embedding: embedding, clips: clips, durationSec: Self.round2(total))
    }

    // MARK: - 清理（4.7）

    private func cleanup(_ meeting: MeetingPaths, meta: MeetingMeta) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: meeting.workDir)
        guard options.deleteRawOnSuccess else { return }
        if fm.fileExists(atPath: meeting.rawDir.path) {
            // 直接删除，不进废纸篓
            try fm.removeItem(at: meeting.rawDir)
        }
        try store.updateMeta(meeting) { $0.rawDeletedAt = Date() }
    }

    // MARK: - 工具

    private func read(_ t: PreparedTrack, _ start: Double, _ end: Double) -> [Float] {
        t.reader.readMono(from: max(0, start - t.offset), to: max(0, end - t.offset))
    }

    /// 在区间内用 VAD 找静音点（语音区间之间的中点，全局时间）。
    private func silencePoints(in samples: [Float], from s: Double, to e: Double) -> [Double] {
        let a = max(0, Int(s * Double(Self.sr))), b = min(samples.count, Int(e * Double(Self.sr)))
        guard b > a else { return [] }
        let speech = engines.vad.detect(Array(samples[a..<b]))
        guard speech.count > 1 else { return [] }
        return zip(speech, speech.dropFirst()).map { s + ($0.upperBound + $1.lowerBound) / 2 }
    }

    private func assignLabels(_ segments: [ASRSegment]) -> [String: String] {
        var labels: [String: String] = [:]
        for s in segments.sorted(by: { $0.start < $1.start }) where labels[s.speaker] == nil {
            labels[s.speaker] = "S\(labels.count + 1)"
        }
        return labels
    }

    static func labelOrder(_ a: String, _ b: String) -> Bool {
        (Int(a.dropFirst()) ?? 0) < (Int(b.dropFirst()) ?? 0)
    }

    static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
}

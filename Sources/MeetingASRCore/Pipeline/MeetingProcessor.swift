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
    /// 长音频分块分离
    public var blockDiarization = BlockDiarizationConfig()
    public var echo: EchoDetector
    public var textEcho: TextEchoFilter
    /// 识别成功后删除原始音频（FR-P6）
    public var deleteRawOnSuccess: Bool

    public init(recognition: RecognitionSettings = RecognitionSettings(), hotwords: HotwordList = HotwordList(words: []), segmenter: SegmenterConfig = SegmenterConfig(), echo: EchoDetector = EchoDetector(), textEcho: TextEchoFilter = TextEchoFilter(), deleteRawOnSuccess: Bool = true) {
        self.recognition = recognition
        self.hotwords = hotwords
        self.segmenter = segmenter
        self.echo = echo
        self.textEcho = textEcho
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

    /// 分离各阶段耗时（按本机实测持续校准，用于无回调阶段的进度估计）
    struct DiarizationTiming {
        /// 切分阶段：每秒音频耗时（秒）
        var segSecondsPerAudioSec = 0.04
        /// 切分阶段占单块分离总耗时的比例
        var segShare = 0.42

        mutating func learn(total: Double, segment: Double?, audioSec: Double) {
            guard let segment, total > 0.5, audioSec > 10 else { return }
            segSecondsPerAudioSec = 0.5 * segSecondsPerAudioSec + 0.5 * (segment / audioSec)
            segShare = min(0.8, max(0.1, 0.5 * segShare + 0.5 * (segment / total)))
        }
    }

    private var diarTiming = DiarizationTiming()

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
        try runSegmentStream(meeting, meta: meta, cancel: cancel, progress: progress)
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

    /// 样本数组中 [s, e) 秒的片段。
    static func slice(_ samples: [Float], _ s: Double, _ e: Double) -> [Float] {
        let a = max(0, Int(s * Double(sr))), b = min(samples.count, Int(e * Double(sr)))
        return b > a ? Array(samples[a..<b]) : []
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
    
    // MARK: - Segment Stream Mode
    
    private func runSegmentStream(
        _ meeting: MeetingPaths,
        meta: MeetingMeta,
        cancel: CancellationFlag,
        progress: @escaping (ProcessingProgress) -> Void
    ) throws -> Transcript {
        let rec = options.recognition
        
        // 1. 预处理
        progress(.at(.preprocess, 0))
        let tracks = try prepareTracks(meeting, meta: meta, cancel: cancel) { progress(.at(.preprocess, $0)) }
        guard !tracks.isEmpty else { throw ProcessingError.noAudio }
        let duration = tracks.map { $0.offset + $0.reader.durationSec }.max() ?? 0
        
        // 2. VAD 分段 + 并行 ASR/声纹
        progress(.at(.diarization, 0))
        var allSegments: [Segment] = []
        let twoTrack = tracks.contains { $0.kind == .mic } && tracks.contains { $0.kind == .system }
        
        for (ti, track) in tracks.enumerated() {
            try cancel.check()
            let samples = track.reader.readAllMono()
            
            // VAD 切段
            let vadRanges = engines.vad.detect(samples)
            var segments = vadRanges.enumerated().map { idx, range -> Segment in
                let padBefore = rec.segmentVAD.padBefore
                let padAfter = rec.segmentVAD.padAfter
                let speechStart = range.lowerBound
                let speechEnd = range.upperBound
                let start = max(0, speechStart - padBefore)
                let end = min(Double(samples.count) / Double(Self.sr), speechEnd + padAfter)
                
                return Segment(
                    id: idx,
                    track: track.kind,
                    start: start + track.offset,
                    end: end + track.offset,
                    speechStart: speechStart + track.offset,
                    speechEnd: speechEnd + track.offset
                )
            }
            
            // 并行 ASR + 声纹
            let pipeline = SegmentPipeline(config: rec.segmentClustering, sampleRate: Self.sr)
            segments = pipeline.process(segments, samples: samples, recognizer: engines.recognizer, embedder: engines.embedder)
            
            allSegments.append(contentsOf: segments)
            progress(.at(.diarization, (Double(ti) + 0.8) / Double(tracks.count)))
        }
        
        // 3. 聚类
        progress(.at(.recognition, 0))
        let clusterer = SegmentClusterer(config: rec.segmentClustering)
        let assigner = SegmentAssigner(config: rec.segmentClustering)
        
        var segmentsByTrack: [TrackKind: [Segment]] = [:]
        for track in Set(allSegments.map(\.track)) {
            var trackSegs = allSegments.filter { $0.track == track }
            
            if twoTrack && track == .mic {
                for i in trackSegs.indices {
                    trackSegs[i].cluster = "mic-speaker"
                }
            } else {
                trackSegs = clusterer.cluster(trackSegs)
                trackSegs = assigner.assignShortSegments(trackSegs)
                trackSegs = assigner.splitMixedSegments(trackSegs)
            }
            
            segmentsByTrack[track] = trackSegs
        }
        allSegments = segmentsByTrack.values.flatMap { $0 }
        
        // 4. 回声过滤
        if twoTrack, let mic = tracks.first(where: { $0.kind == .mic }), let sys = tracks.first(where: { $0.kind == .system }) {
            for i in allSegments.indices where allSegments[i].track == .mic {
                let seg = allSegments[i]
                let a = read(mic, seg.start, seg.end)
                let b = read(sys, seg.start, seg.end)
                allSegments[i].isEcho = options.echo.isEcho(mic: a, system: b, micGain: mic.gain, systemGain: sys.gain)
            }
        }
        
        // 5. 分配说话人标签
        var labels: [String: String] = [:]
        for seg in allSegments.sorted(by: { $0.start < $1.start }) where !seg.isEcho {
            if let cluster = seg.cluster, labels[cluster] == nil {
                labels[cluster] = "S\(labels.count + 1)"
            }
        }
        
        for i in allSegments.indices {
            if let cluster = allSegments[i].cluster {
                allSegments[i].speaker = labels[cluster]
            }
        }
        
        let trackOfSpeaker = Dictionary(
            allSegments.compactMap { seg in seg.speaker.map { ($0, seg.track) } },
            uniquingKeysWith: { a, _ in a }
        )
        
        // 6. 轮次合并
        progress(.at(.recognition, 0.3))
        var pieces = TurnAssembler.turns(allSegments, gap: rec.segmentClustering.turnMergeGap)
        if twoTrack { pieces = options.textEcho.filter(pieces) }
        
        // 7. 热词 + 标点
        progress(.at(.recognition, 0.6))
        let corrector = HotwordCorrector(hotwords: options.hotwords.adding(people.allNames))
        let acronyms = AcronymNormalizer()
        let out: [TranscriptSegment] = pieces.map { pc in
            var text = acronyms.normalize(corrector.correct(pc.text))
            if let p = engines.punctuator { text = acronyms.normalize(p.punctuate(text)) }
            let tokens = acronyms.normalize(tokens: corrector.correct(tokens: pc.tokens))
                .map { TranscriptToken(t: $0.t, start: Self.round2($0.start)) }
            return TranscriptSegment(
                speaker: pc.speaker,
                start: Self.round2(pc.start),
                end: Self.round2(pc.end),
                text: text,
                tokens: tokens.isEmpty ? nil : tokens
            )
        }
        
        // 8. 特征片段与人物匹配
        progress(.at(.speakerID, 0))
        let spoken = Set(out.map(\.speaker))
        let speakerIDs = labels.values.filter { spoken.contains($0) }.sorted(by: Self.labelOrder)
        try FileManager.default.createDirectory(at: meeting.speakersDir, withIntermediateDirectories: true)
        
        let asrSegments = allSegments.map { seg -> ASRSegment in
            ASRSegment(
                speaker: seg.speaker ?? "unknown",
                track: seg.track,
                start: seg.start,
                end: seg.end,
                cropStart: seg.start,
                cropEnd: seg.end
            )
        }
        
        var records: [SpeakerRecord] = []
        for (i, sid) in speakerIDs.enumerated() {
            try cancel.check()
            let segs = asrSegments.filter { $0.speaker == sid }
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
            try people.addSample(
                personId: person.id,
                meeting: meeting.name,
                speaker: records[i].id,
                embedding: records[i].embedding,
                clipURLs: records[i].clips.map { meeting.clip($0.file) },
                source: .auto
            )
            records[i].contributedTo = person.id
        }
        progress(.at(.speakerID, 1))
        
        // 9. 输出
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
}

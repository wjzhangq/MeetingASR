import Foundation

/// 录音期间提前完成的分块分离结果，保存在 `.raw/diarization_<track>.json`，识别时直接复用，
/// 停止录音后只需分离最后不足一块的部分。随原始音频一起删除。
public struct DiarizationCache: Codable, Equatable, Sendable {
    /// 结果对应的参数；任一项与识别时不同则整份作废
    public struct Key: Codable, Equatable, Sendable {
        public var track: TrackKind
        public var sampleRate: Int
        public var blockSec: Double
        public var threshold: Float
        public var minDurationOn: Float
        public var minDurationOff: Float
        public var model: String

        public init(track: TrackKind, recognition: RecognitionSettings, config: BlockDiarizationConfig, models: ModelVersions) {
            self.track = track
            sampleRate = Preprocessor.targetRate
            blockSec = config.blockSec
            threshold = recognition.clusterThreshold
            minDurationOn = recognition.minDurationOn
            minDurationOff = recognition.minDurationOff
            model = models.segmentation + "|" + models.embedding
        }
    }

    public struct Span: Codable, Equatable, Sendable {
        /// 块内簇编号（"0"、"1"…）
        public var speaker: String
        /// 秒，相对音轨起点
        public var start: Double
        public var end: Double
    }

    public struct Block: Codable, Equatable, Sendable {
        /// 16kHz 样本下标，相对音轨起点
        public var start: Int
        public var end: Int
        public var spans: [Span]
    }

    public var version = 1
    public var key: Key
    public var blocks: [Block] = []

    public init(key: Key) {
        self.key = key
    }

    public static func url(_ meeting: MeetingPaths, track: TrackKind) -> URL {
        meeting.rawDir.appendingPathComponent("diarization_\(track.rawValue).json")
    }

    public static func load(_ meeting: MeetingPaths, track: TrackKind) -> DiarizationCache? {
        load(from: url(meeting, track: track))
    }

    public static func load(from url: URL) -> DiarizationCache? {
        try? JSONIO.read(DiarizationCache.self, from: url)
    }

    /// 可直接使用的块：参数一致、从 0 开始首尾相接、不超出音轨。
    /// 之后剩余部分短于 `minTail` 时去掉最后一块，与剩余部分一起重新分离（避免出现过短的块）。
    public func usableBlocks(key: Key, totalSamples: Int, minTail: Int) -> [Block] {
        guard version == 1, self.key == key else { return [] }
        var out: [Block] = []
        var pos = 0
        for b in blocks {
            guard b.start == pos, b.end > b.start, b.end <= totalSamples else { break }
            out.append(b)
            pos = b.end
        }
        while let last = out.last, totalSamples - last.end < minTail { out.removeLast() }
        return out
    }
}

/// 录音期间的增量分离：读取正在写入的录音文件，每凑够一块（约 2 分钟，切点在附近最安静处）就分离并写入缓存。
/// 不是线程安全的，由调用方在同一个串行队列上调用 `step()`。
public final class LiveDiarizer {
    public let source: URL
    public let cacheURL: URL
    private let diarizer: SpeakerDiarizer
    private let options: DiarizationOptions
    private let config: BlockDiarizationConfig
    private let isStopped: () -> Bool
    private var cache: DiarizationCache
    private var resampler: Resampler?
    /// 已读取的原始帧数
    private var consumed: Int64 = 0
    /// 未分离的 16kHz 样本，buffer[0] 位于 bufferStart
    private var buffer: [Float] = []
    private var bufferStart = 0

    private static let sr = Preprocessor.targetRate

    /// - Parameter isStopped: 返回 true 后不再开始新的块（推理库无法中途中止，进行中的块会完成并写入）
    public init(source: URL, cacheURL: URL, key: DiarizationCache.Key, recognition: RecognitionSettings, diarizer: SpeakerDiarizer,
                config: BlockDiarizationConfig = BlockDiarizationConfig(), isStopped: @escaping () -> Bool = { false }) {
        self.source = source
        self.cacheURL = cacheURL
        self.diarizer = diarizer
        self.config = config
        self.isStopped = isStopped
        // 各块人数未知（某块可能只有部分人发言），识别时跨块关联后再按指定人数合并
        options = DiarizationOptions(numSpeakers: nil, threshold: recognition.clusterThreshold,
                                     minDurationOn: recognition.minDurationOn, minDurationOff: recognition.minDurationOff)
        cache = DiarizationCache(key: key)
    }

    /// 已分离的块数
    public var completedBlocks: Int { cache.blocks.count }

    /// 读取录音文件新增的部分；够一块时分离并写缓存。
    /// - Returns: 本次完成的块数
    @discardableResult
    public func step() throws -> Int {
        guard config.blockSec > 0 else { return 0 }
        readNewAudio()
        let block = Int(config.blockSec * Double(Self.sr))
        let search = Int(config.searchSec * Double(Self.sr))
        var done = 0
        // 目标切点之后还要有完整的搜索范围，切点才与整段分块一致
        while !isStopped(), buffer.count >= block + search {
            let cut = BlockPlanner.quietestCut(buffer, lo: max(block / 2, block - search), hi: block + search, target: block, sampleRate: Self.sr)
            let part = Self.normalized(Array(buffer[0..<cut]))
            let off = Double(bufferStart) / Double(Self.sr)
            let spans = diarizer.diarize(part, options: options) { [isStopped] _ in !isStopped() }
            cache.blocks.append(DiarizationCache.Block(
                start: bufferStart, end: bufferStart + cut,
                spans: spans.map { DiarizationCache.Span(speaker: $0.speaker, start: $0.start + off, end: $0.end + off) }))
            try JSONIO.write(cache, to: cacheURL)
            buffer.removeFirst(cut)
            bufferStart += cut
            done += 1
        }
        return done
    }

    /// 录音文件在不断增长：每次重新打开，读到当前末尾，重采样到 16kHz。
    private func readNewAudio() {
        guard let reader = try? WavReader(url: source), reader.frameCount > consumed else { return }
        if resampler == nil { resampler = Resampler(inputRate: reader.sampleRate, outputRate: Self.sr) }
        guard let resampler, resampler.inputRate == reader.sampleRate else { return }
        let chunk = reader.sampleRate * 10
        while consumed < reader.frameCount, !isStopped() {
            let buf = reader.readMono(startFrame: consumed, count: Int(min(Int64(chunk), reader.frameCount - consumed)))
            if buf.isEmpty { break }
            consumed += Int64(buf.count)
            buffer += resampler.process(buf)
        }
    }

    /// 按块做响度归一（与预处理相同的目标响度，识别时整轨归一的增益与之接近）。
    static func normalized(_ x: [Float]) -> [Float] {
        let gain = Preprocessor.loudnessGain(x, sampleRate: sr)
        guard gain != 1 else { return x }
        return x.map { Preprocessor.softClip($0 * gain) }
    }
}

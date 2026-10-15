import Foundation
import MeetingASRCore
import SherpaOnnx
import SherpaOnnxC

// sherpa-onnx 适配层：把上游 Swift 封装接到 MeetingASRCore 的引擎协议上。

/// 离线识别：Paraformer-zh / FireRedASR2-CTC / FireRedASR-AED。
public final class SherpaRecognizer: SpeechRecognizer {
    public let kind: AsrModelKind
    public var modelName: String { kind.modelName }
    public var providesTimestamps: Bool { kind.providesTimestamps }
    private let recognizer: SherpaOnnxOfflineRecognizer

    public init(paths: ModelPaths, kind: AsrModelKind = .paraformer, numThreads: Int) throws {
        guard let dir = paths.asrDirectory(kind) else {
            throw EngineError.modelMissing(paths.root.appendingPathComponent(kind.directory).path)
        }
        self.kind = kind
        let tokens = dir.appendingPathComponent("tokens.txt").path
        let model: SherpaOnnxOfflineModelConfig
        switch kind {
        case .paraformer:
            model = sherpaOnnxOfflineModelConfig(
                tokens: tokens,
                paraformer: sherpaOnnxOfflineParaformerModelConfig(model: dir.appendingPathComponent("model.int8.onnx").path),
                numThreads: numThreads, provider: "cpu")
        case .fireRedAsrCtc:
            model = sherpaOnnxOfflineModelConfig(
                tokens: tokens, numThreads: numThreads, provider: "cpu",
                fireRedAsrCtc: sherpaOnnxOfflineFireRedAsrCtcModelConfig(model: dir.appendingPathComponent("model.int8.onnx").path))
        case .fireRedAsrAed:
            model = sherpaOnnxOfflineModelConfig(
                tokens: tokens, numThreads: numThreads, provider: "cpu",
                fireRedAsr: sherpaOnnxOfflineFireRedAsrModelConfig(
                    encoder: dir.appendingPathComponent("encoder.int8.onnx").path,
                    decoder: dir.appendingPathComponent("decoder.int8.onnx").path))
        }
        var config = sherpaOnnxOfflineRecognizerConfig(featConfig: sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80), modelConfig: model)
        recognizer = SherpaOnnxOfflineRecognizer(config: &config)
    }

    public func recognize(_ samples: [Float]) -> RecognitionResult {
        guard samples.count >= 1600 else { return RecognitionResult(text: "") }
        let r = recognizer.decode(samples: samples, sampleRate: 16_000)
        let text = r.text
        var pieces: [(String, Double)] = []
        let raw = r.result.pointee
        let ts = r.timestamps
        if let arr = raw.tokens_arr, ts.count == Int(raw.count) {
            for i in 0..<Int(raw.count) {
                guard let p = arr[i] else { continue }
                pieces.append((String(cString: p), Double(ts[i])))
            }
        }
        return RecognitionResult(text: text, tokens: SubwordMerger.merge(pieces))
    }
}

/// CT-Transformer 中英标点。
public final class SherpaPunctuator: Punctuator {
    private let punct: SherpaOnnxOfflinePunctuationWrapper

    public init?(paths: ModelPaths, numThreads: Int) {
        guard paths.hasPunctuation else { return nil }
        let model = sherpaOnnxOfflinePunctuationModelConfig(ctTransformer: paths.punctuation.path, numThreads: numThreads, provider: "cpu")
        var config = sherpaOnnxOfflinePunctuationConfig(model: model)
        punct = SherpaOnnxOfflinePunctuationWrapper(config: &config)
        if punct.ptr == nil { return nil }
    }

    public func punctuate(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return punct.addPunct(text: text)
    }
}

/// pyannote segmentation 3.0 + CAM++ + 快速聚类。
public final class SherpaDiarizer: SpeakerDiarizer {
    private let paths: ModelPaths
    private let numThreads: Int
    private var sd: SherpaOnnxOfflineSpeakerDiarizationWrapper?
    private var builtFor: DiarizationOptions?

    public init(paths: ModelPaths, numThreads: Int) throws {
        for u in [paths.segmentation, paths.embedding] where !FileManager.default.fileExists(atPath: u.path) {
            throw EngineError.modelMissing(u.path)
        }
        self.paths = paths
        self.numThreads = numThreads
        _ = try build(DiarizationOptions())
    }

    private func makeConfig(_ o: DiarizationOptions) -> SherpaOnnxOfflineSpeakerDiarizationConfig {
        let seg = sherpaOnnxOfflineSpeakerSegmentationModelConfig(
            pyannote: sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(model: paths.segmentation.path),
            numThreads: numThreads)
        let emb = sherpaOnnxSpeakerEmbeddingExtractorConfig(model: paths.embedding.path, numThreads: numThreads)
        let cluster = sherpaOnnxFastClusteringConfig(numClusters: o.numSpeakers.map { max(1, $0) } ?? -1, threshold: o.threshold)
        return sherpaOnnxOfflineSpeakerDiarizationConfig(segmentation: seg, embedding: emb, clustering: cluster,
                                                         minDurationOn: o.minDurationOn, minDurationOff: o.minDurationOff)
    }

    private func build(_ o: DiarizationOptions) throws -> SherpaOnnxOfflineSpeakerDiarizationWrapper {
        if let sd, let b = builtFor, b.minDurationOn == o.minDurationOn, b.minDurationOff == o.minDurationOff {
            if b != o {
                // 只有聚类参数变化时可直接更新
                var config = makeConfig(o)
                sd.setConfig(config: &config)
                builtFor = o
            }
            return sd
        }
        var config = makeConfig(o)
        let w = SherpaOnnxOfflineSpeakerDiarizationWrapper(config: &config)
        guard w.impl != nil else { throw EngineError.initFailed("speaker diarization") }
        sd = w
        builtFor = o
        return w
    }

    public func diarize(_ samples: [Float], options: DiarizationOptions, progress: @escaping (Double) -> Bool) -> [RawSpan] {
        guard samples.count > 16_000 / 2, let sd = try? build(options) else { return [] }
        let box = ProgressBox(progress)
        let opaque = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ProgressBox>.fromOpaque(opaque).release() }
        let result = SherpaOnnxOfflineSpeakerDiarizationProcessWithCallback(
            sd.impl, samples, Int32(samples.count),
            { processed, total, arg in
                guard let arg else { return 0 }
                let box = Unmanaged<ProgressBox>.fromOpaque(arg).takeUnretainedValue()
                // 当前 sherpa-onnx 忽略返回值，无法中途中止；取消在分离结束后由流水线检查
                _ = box.callback(total > 0 ? Double(processed) / Double(total) : 0)
                return 0
            }, opaque)
        guard let result else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result) }
        let n = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
        guard n > 0, let p = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result) else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(p) }
        return (0..<n).map { RawSpan(speaker: "\(p[$0].speaker)", start: Double(p[$0].start), end: Double(p[$0].end)) }
    }

    private final class ProgressBox {
        let callback: (Double) -> Bool
        init(_ c: @escaping (Double) -> Bool) { callback = c }
    }
}

/// CAM++ 声纹提取。
public final class SherpaEmbedder: SpeakerEmbedder {
    public let modelName = EmbeddingModel.current
    private let extractor: SherpaOnnxSpeakerEmbeddingExtractorWrapper

    public init(paths: ModelPaths, numThreads: Int) throws {
        guard FileManager.default.fileExists(atPath: paths.embedding.path) else { throw EngineError.modelMissing(paths.embedding.path) }
        var config = sherpaOnnxSpeakerEmbeddingExtractorConfig(model: paths.embedding.path, numThreads: numThreads)
        extractor = SherpaOnnxSpeakerEmbeddingExtractorWrapper(config: &config)
        guard extractor.impl != nil else { throw EngineError.initFailed("speaker embedding") }
    }

    public func embed(_ samples: [Float]) -> [Float]? {
        guard samples.count >= 16_000 / 2 else { return nil }
        let stream = extractor.createStream()
        stream.acceptWaveform(samples: samples, sampleRate: 16_000)
        stream.inputFinished()
        let v = extractor.compute(stream: stream)
        return v.isEmpty ? nil : VectorMath.normalized(v)
    }
}

/// Silero VAD。
public final class SherpaVAD: VoiceActivityDetector {
    private let paths: ModelPaths

    public init(paths: ModelPaths) throws {
        guard FileManager.default.fileExists(atPath: paths.vad.path) else { throw EngineError.modelMissing(paths.vad.path) }
        self.paths = paths
    }

    public func detect(_ samples: [Float]) -> [ClosedRange<Double>] {
        // 每次检测新建实例，避免状态残留；模型很小，开销可忽略
        let silero = sherpaOnnxSileroVadModelConfig(model: paths.vad.path, threshold: 0.5, minSilenceDuration: 0.3,
                                                    minSpeechDuration: 0.25, windowSize: 512, maxSpeechDuration: 30)
        var config = sherpaOnnxVadModelConfig(sileroVad: silero, sampleRate: 16_000, numThreads: 1)
        let vad = SherpaOnnxVoiceActivityDetectorWrapper(config: &config, buffer_size_in_seconds: 60)
        var out: [ClosedRange<Double>] = []
        func collect() {
            while !vad.isEmpty() {
                let seg = vad.front()
                let s = Double(seg.start) / 16_000
                out.append(s...(s + Double(seg.n) / 16_000))
                vad.pop()
            }
        }
        let window = 512
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + window * 50)
            vad.acceptWaveform(samples: Array(samples[i..<end]))
            collect()
            i = end
        }
        vad.flush()
        collect()
        return out
    }
}

/// 创建全套引擎。
public enum SherpaEngineFactory {
    /// - Parameter asrModel: 所选识别模型；未安装时使用 Paraformer
    public static func make(paths: ModelPaths, numThreads: Int = 4, asrModel: AsrModelKind = .paraformer) throws -> EngineSet {
        try paths.validate()
        let punct = SherpaPunctuator(paths: paths, numThreads: numThreads)
        let kind = paths.hasASR(asrModel) ? asrModel : .paraformer
        let recognizer = try SherpaRecognizer(paths: paths, kind: kind, numThreads: numThreads)
        var models = ModelVersions.bundled
        models.asr = recognizer.modelName
        if punct == nil { models.punctuation = nil }
        return EngineSet(
            recognizer: recognizer,
            punctuator: punct,
            diarizer: try SherpaDiarizer(paths: paths, numThreads: numThreads),
            embedder: try SherpaEmbedder(paths: paths, numThreads: numThreads),
            vad: try SherpaVAD(paths: paths),
            models: models
        )
    }

    public static var version: String { getSherpaOnnxVersion() }
}

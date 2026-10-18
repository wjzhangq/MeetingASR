import Foundation

/// 线程安全的有界段队列：满时生产者阻塞（不丢段），关闭且取空后消费者退出。
public final class SegmentQueue {
    private var items: [Segment] = []
    private let capacity: Int
    private var closed = false
    private let cond = NSCondition()

    public init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    /// 入队；队列满时阻塞。
    public func enqueue(_ segment: Segment) {
        cond.lock()
        defer { cond.unlock() }
        while items.count >= capacity, !closed { cond.wait() }
        guard !closed else { return }
        items.append(segment)
        cond.broadcast()
    }

    /// 出队；队列空时阻塞，关闭且取空后返回 nil。
    public func dequeue() -> Segment? {
        cond.lock()
        defer { cond.unlock() }
        while items.isEmpty, !closed { cond.wait() }
        guard !items.isEmpty else { return nil }
        let s = items.removeFirst()
        cond.broadcast()
        return s
    }

    /// 关闭队列并唤醒所有等待者。
    public func close() {
        cond.lock()
        defer { cond.unlock() }
        closed = true
        cond.broadcast()
    }

    public var count: Int {
        cond.lock(); defer { cond.unlock() }
        return items.count
    }
}

/// 段流水线处理器：双队列 + 两个 worker 并行处理。
public final class SegmentPipeline {
    private let config: SegmentClusteringConfig
    private let sampleRate: Int
    
    public init(config: SegmentClusteringConfig, sampleRate: Int = 16_000) {
        self.config = config
        self.sampleRate = sampleRate
    }
    
    /// 处理一批段（ASR 和声纹并行）。
    /// - Parameters:
    ///   - segments: 待处理的段（只填了 id/track/start/end/speechStart/speechEnd）
    ///   - samples: 本轨完整音频
    ///   - recognizer: ASR 引擎（不跨线程共享，每个 worker 持有自己的实例）
    ///   - embedder: 声纹引擎
    /// - Returns: 处理后的段（填充了 text/tokens/embedding/subwindows/isMixed）
    public func process(
        _ segments: [Segment],
        samples: [Float],
        recognizer: SpeechRecognizer,
        embedder: SpeakerEmbedder
    ) -> [Segment] {
        guard !segments.isEmpty else { return [] }

        let maxAsrDuration = 60.0  // 单段 ASR 最大输入长度（秒）
        let maxAsrSamples = Int(maxAsrDuration * Double(sampleRate))

        let queueASR = SegmentQueue(capacity: 64)
        let queueEmb = SegmentQueue(capacity: 64)
        
        // 结果字典：id → 段
        var results: [Int: Segment] = [:]
        let lock = NSLock()
        
        let group = DispatchGroup()
        
        // ASR worker
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [sampleRate, maxAsrSamples] in
            defer { group.leave() }
            while let seg = queueASR.dequeue() {
                var s = seg
                let audio = Self.slice(samples, s.start, s.end, sampleRate: sampleRate)
                if audio.count > maxAsrSamples {
                    let lenSec = Double(audio.count) / Double(sampleRate)
                    print("⚠️  段 #\(s.id): ASR 输入 \(String(format: "%.1f", lenSec))s / \(audio.count) 采样点，超过安全长度")
                }
                let result = recognizer.recognize(audio)
                s.text = result.text
                s.tokens = result.tokens.map { TranscriptToken(t: $0.t, start: $0.start + s.start) }

                lock.lock()
                // 检查是否为切分的子段
                let isSplit = s.metadata?["isSplit"] == "true"
                if isSplit, var existing = results[s.id] {
                    // 合并子段：拼接文本，扩展时间范围
                    existing.text = existing.text + s.text
                    existing.tokens = existing.tokens + s.tokens
                    existing.start = min(existing.start, s.start)
                    existing.end = max(existing.end, s.end)
                    existing.speechStart = min(existing.speechStart, s.speechStart)
                    existing.speechEnd = max(existing.speechEnd, s.speechEnd)
                    results[s.id] = existing
                } else {
                    // 清理内部元数据
                    s.metadata?.removeValue(forKey: "subIndex")
                    s.metadata?.removeValue(forKey: "isSplit")
                    if s.metadata?.isEmpty == true { s.metadata = nil }
                    results[s.id] = s
                }
                lock.unlock()
            }
        }
        
        // 声纹 worker
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [sampleRate] in
            defer { group.leave() }
            while let seg = queueEmb.dequeue() {
                var s = seg
                self.extractEmbedding(for: &s, samples: samples, embedder: embedder, sampleRate: sampleRate)
                
                lock.lock()
                if var existing = results[s.id] {
                    // ASR 已完成，合并声纹字段
                    existing.embedding = s.embedding
                    existing.subwindows = s.subwindows
                    existing.isShort = s.isShort
                    existing.isMixed = s.isMixed
                    results[s.id] = existing
                } else {
                    // ASR 还没完成，先记录声纹部分
                    results[s.id] = s
                }
                lock.unlock()
            }
        }
        
        // 生产者：每个段同时送入两个队列
        // ASR 队列：长段需要切分（避免 ONNX Runtime 维度错误）
        for seg in segments {
            let duration = seg.speechEnd - seg.speechStart

            if duration > maxAsrDuration {
                // 切分成多个 ≤60s 的子段
                let numSubSegments = Int(ceil(duration / maxAsrDuration))
                print("⚠️  段 #\(seg.id): 语音 \(String(format: "%.1f", duration))s 超过 \(Int(maxAsrDuration))s 限制，切分为 \(numSubSegments) 个子段")
                var subStart = seg.speechStart
                var subIndex = 0
                while subStart < seg.speechEnd {
                    let subEnd = min(subStart + maxAsrDuration, seg.speechEnd)
                    var subSeg = seg
                    subSeg.speechStart = subStart
                    subSeg.speechEnd = subEnd
                    // 重新计算 start/end（保持原有的 padding 比例）
                    let originalPadBefore = seg.speechStart - seg.start
                    let originalPadAfter = seg.end - seg.speechEnd
                    subSeg.start = max(seg.start, subStart - originalPadBefore)
                    subSeg.end = min(seg.end, subEnd + originalPadAfter)
                    // 保持 id 相同以便合并，但用内部标记区分子段
                    subSeg.metadata = ["subIndex": "\(subIndex)", "isSplit": "true"]
                    queueASR.enqueue(subSeg)
                    subStart = subEnd
                    subIndex += 1
                }
            } else {
                queueASR.enqueue(seg)
            }

            // 声纹队列：总是使用完整段
            queueEmb.enqueue(seg)
        }
        queueASR.close()
        queueEmb.close()
        
        group.wait()
        
        return segments.map { results[$0.id] ?? $0 }
    }
    
    private func extractEmbedding(
        for segment: inout Segment,
        samples: [Float],
        embedder: SpeakerEmbedder,
        sampleRate: Int
    ) {
        let dur = segment.speechDuration
        
        if dur < config.shortSegmentSec {
            segment.isShort = true
            let audio = Self.slice(samples, segment.start, segment.end, sampleRate: sampleRate)
            segment.embedding = embedder.embed(audio) ?? []
        } else if dur < config.longSegmentSec {
            let audio = Self.slice(samples, segment.start, segment.end, sampleRate: sampleRate)
            segment.embedding = embedder.embed(audio) ?? []
        } else {
            extractSubwindows(for: &segment, samples: samples, embedder: embedder, sampleRate: sampleRate)
        }
    }
    
    private func extractSubwindows(
        for segment: inout Segment,
        samples: [Float],
        embedder: SpeakerEmbedder,
        sampleRate: Int
    ) {
        let windowSec = config.subwindowSec
        let stepSec = config.subwindowStepSec
        let halfWindow = windowSec / 2
        
        var subwindows: [SubwindowEmbedding] = []
        var center = segment.speechStart + halfWindow
        
        while center + halfWindow <= segment.speechEnd {
            let windowStart = center - halfWindow
            let windowEnd = center + halfWindow
            let audio = Self.slice(samples, windowStart, windowEnd, sampleRate: sampleRate)
            
            if let emb = embedder.embed(audio) {
                subwindows.append(SubwindowEmbedding(start: windowStart, end: windowEnd, embedding: emb))
            }
            center += stepSec
        }
        
        guard !subwindows.isEmpty else { return }
        
        segment.subwindows = subwindows
        segment.embedding = VectorMath.meanNormalized(subwindows.map(\.embedding))
        segment.isMixed = detectMixed(subwindows)
    }
    
    private func detectMixed(_ subwindows: [SubwindowEmbedding]) -> Bool {
        guard subwindows.count >= 3 else { return false }
        
        var similarities: [Double] = []
        for i in 0..<(subwindows.count - 1) {
            let sim = VectorMath.cosine(subwindows[i].embedding, subwindows[i + 1].embedding)
            similarities.append(sim)
        }
        
        for i in 0..<similarities.count {
            let sim = similarities[i]
            guard sim < config.mixedValley else { continue }
            
            let leftSide = similarities[0..<i]
            let rightSide = similarities[(i + 1)...]
            
            if !leftSide.isEmpty && !rightSide.isEmpty {
                let leftAvg = leftSide.reduce(0, +) / Double(leftSide.count)
                let rightAvg = rightSide.reduce(0, +) / Double(rightSide.count)
                
                if leftAvg >= config.mixedSideSimilarity && rightAvg >= config.mixedSideSimilarity {
                    return true
                }
            }
        }
        
        return false
    }
    
    private static func slice(_ samples: [Float], _ start: Double, _ end: Double, sampleRate: Int) -> [Float] {
        let a = max(0, Int(start * Double(sampleRate)))
        let b = min(samples.count, Int(end * Double(sampleRate)))
        return b > a ? Array(samples[a..<b]) : []
    }
}

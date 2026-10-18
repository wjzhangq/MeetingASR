import Foundation

/// 短段与混合段的事后归属。
public struct SegmentAssigner: Sendable {
    private let config: SegmentClusteringConfig
    
    public init(config: SegmentClusteringConfig = SegmentClusteringConfig()) {
        self.config = config
    }
    
    /// 为短段分配说话人。
    public func assignShortSegments(_ segments: [Segment]) -> [Segment] {
        let clusterCentroids = computeClusterCentroids(segments)
        guard !clusterCentroids.isEmpty else { return segments }
        
        var result = segments
        
        for i in result.indices {
            guard result[i].isShort, !result[i].embedding.isEmpty, result[i].cluster == nil else { continue }
            
            // 与各簇中心比较
            var bestCluster: String?
            var bestSim = -2.0
            
            for (cid, centroid) in clusterCentroids {
                let sim = VectorMath.cosine(result[i].embedding, centroid)
                if sim >= config.shortAssignSimilarity && sim > bestSim {
                    bestSim = sim
                    bestCluster = cid
                }
            }
            
            if let cluster = bestCluster {
                result[i].cluster = cluster
            } else {
                // 时间就近归属
                result[i].cluster = nearestSpeaker(at: i, in: result, within: config.shortAssignNearbySec)
            }
        }
        
        return result
    }
    
    /// 拆分混合段。
    public func splitMixedSegments(_ segments: [Segment]) -> [Segment] {
        let clusterCentroids = computeClusterCentroids(segments)
        guard !clusterCentroids.isEmpty else { return segments }
        
        var result: [Segment] = []
        
        for seg in segments {
            if seg.isMixed && !seg.subwindows.isEmpty {
                result.append(contentsOf: splitOne(seg, clusterCentroids: clusterCentroids))
            } else {
                result.append(seg)
            }
        }
        
        return result
    }
    
    private func splitOne(_ segment: Segment, clusterCentroids: [String: [Float]]) -> [Segment] {
        guard !segment.subwindows.isEmpty else { return [segment] }
        
        // 每个子窗口归到最近的簇
        var labels: [String] = []
        for subwindow in segment.subwindows {
            var bestCluster: String?
            var bestSim = -2.0
            for (cid, centroid) in clusterCentroids {
                let sim = VectorMath.cosine(subwindow.embedding, centroid)
                if sim > bestSim {
                    bestSim = sim
                    bestCluster = cid
                }
            }
            labels.append(bestCluster ?? "unknown")
        }
        
        // 平滑标签
        labels = smoothLabels(labels, subwindows: segment.subwindows)
        
        // 如果平滑后只剩一种标签，不拆分
        let uniqueLabels = Set(labels)
        if uniqueLabels.count == 1 {
            var seg = segment
            seg.cluster = labels.first
            seg.isMixed = false
            return [seg]
        }
        
        // 在标签变化处切分
        return splitByLabels(segment, labels: labels)
    }
    
    private func smoothLabels(_ labels: [String], subwindows: [SubwindowEmbedding]) -> [String] {
        guard labels.count >= 3 else { return labels }
        
        var result = labels
        var runs: [(label: String, range: Range<Int>)] = []
        
        // 识别游程
        var i = 0
        while i < result.count {
            let label = result[i]
            var j = i
            while j < result.count && result[j] == label {
                j += 1
            }
            runs.append((label: label, range: i..<j))
            i = j
        }
        
        // 合并短游程
        for k in 1..<(runs.count - 1) {
            let run = runs[k]
            let duration = subwindows[run.range.upperBound - 1].end - subwindows[run.range.lowerBound].start
            
            if duration < config.smoothRunSec,
               runs[k - 1].label == runs[k + 1].label,
               runs[k - 1].label != run.label {
                for idx in run.range {
                    result[idx] = runs[k - 1].label
                }
            }
        }
        
        return result
    }
    
    private func splitByLabels(_ segment: Segment, labels: [String]) -> [Segment] {
        var segments: [Segment] = []
        var currentLabel: String?
        var currentTokens: [TranscriptToken] = []
        var rangeStart = segment.start
        
        for (i, label) in labels.enumerated() {
            let subwindow = segment.subwindows[i]
            let splitTime = (subwindow.start + subwindow.end) / 2
            
            if label != currentLabel, let prevLabel = currentLabel {
                // 标签变化，切分
                let tokensInRange = segment.tokens.filter { $0.start < splitTime }
                let text = TokenText.join(tokensInRange)
                
                var newSeg = Segment(
                    id: segment.id,
                    track: segment.track,
                    start: rangeStart,
                    end: splitTime,
                    speechStart: rangeStart,
                    speechEnd: splitTime
                )
                newSeg.text = text
                newSeg.tokens = tokensInRange
                newSeg.cluster = prevLabel
                segments.append(newSeg)
                
                currentTokens = segment.tokens.filter { $0.start >= splitTime }
                rangeStart = splitTime
            }
            
            currentLabel = label
        }
        
        // 最后一段
        if let label = currentLabel {
            let text = TokenText.join(currentTokens)
            var newSeg = Segment(
                id: segment.id,
                track: segment.track,
                start: rangeStart,
                end: segment.end,
                speechStart: rangeStart,
                speechEnd: segment.end
            )
            newSeg.text = text
            newSeg.tokens = currentTokens
            newSeg.cluster = label
            segments.append(newSeg)
        }
        
        return segments.isEmpty ? [segment] : segments
    }
    
    private func nearestSpeaker(at idx: Int, in segments: [Segment], within sec: Double) -> String? {
        let seg = segments[idx]
        let window = sec
        
        var nearest: (cluster: String, dist: Double)?
        
        for (i, other) in segments.enumerated() {
            guard i != idx, other.track == seg.track, let cluster = other.cluster else { continue }
            
            let dist = if other.end <= seg.start {
                seg.start - other.end
            } else if other.start >= seg.end {
                other.start - seg.end
            } else {
                0.0
            }
            
            if dist <= window {
                if nearest == nil || dist < nearest!.dist {
                    nearest = (cluster: cluster, dist: dist)
                }
            }
        }
        
        return nearest?.cluster
    }
    
    private func computeClusterCentroids(_ segments: [Segment]) -> [String: [Float]] {
        var stats: [String: [[Float]]] = [:]
        
        for seg in segments {
            guard let cid = seg.cluster, !seg.embedding.isEmpty, !seg.isMixed else { continue }
            stats[cid, default: []].append(seg.embedding)
        }
        
        return stats.mapValues { VectorMath.meanNormalized($0) }
    }
}

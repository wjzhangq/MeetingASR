import Foundation

/// VAD + 固定窗口说话人分离配置（优化版）。
public struct FastDiarizationConfig: Sendable, Equatable {
    /// 提取声纹的窗口长度（秒）
    public var windowSec: Double = 1.5
    /// 窗口步长（秒）
    public var stepSec: Double = 0.75
    /// 粗分阶段：簇中心相似度阈值（在线聚类）
    public var coarseThreshold: Double = 0.65
    /// 细化阶段：层次聚类合并阈值
    public var fineThreshold: Double = 0.70
    /// 最小说话人持续时长（秒），短于此值的簇将被合并
    public var minSpeakerDuration: Double = 2.0
    /// 碎簇合并时的最低相似度
    public var tinySimilarity: Double = 0.45

    public init() {}
}

/// 快速说话人分离：VAD + 固定窗口 + 两阶段聚类。
/// 优化点：
/// 1. 用 VAD 切出语音段，避免 pyannote 的滑窗推理开销
/// 2. 在语音段内按固定窗口提取声纹，向量数量可控
/// 3. 先与人物库匹配（分类），只对未识别窗口聚类
/// 4. 两阶段聚类：粗分快速在线聚类 + 细化层次合并
public struct FastDiarizer: Sendable {
    public var config: FastDiarizationConfig

    public init(config: FastDiarizationConfig = FastDiarizationConfig()) {
        self.config = config
    }

    /// 窗口声纹。
    public struct Window: Sendable {
        /// 窗口中心时间（秒）
        public var time: Double
        /// 归一化声纹
        public var embedding: [Float]
        /// 已匹配的人物 ID（nil 表示未识别）
        public var personId: String?
        /// 分配的簇 ID
        public var clusterId: String?

        public init(time: Double, embedding: [Float], personId: String? = nil) {
            self.time = time
            self.embedding = embedding
            self.personId = personId
        }
    }

    /// 在 VAD 语音段内按固定窗口提取声纹。
    /// - Parameters:
    ///   - speechRanges: VAD 检测到的语音区间（秒）
    ///   - totalDuration: 音频总时长（秒）
    ///   - embed: 给定区间提取声纹的闭包
    /// - Returns: 窗口列表
    public func extractWindows(speechRanges: [ClosedRange<Double>], totalDuration: Double,
                              embed: (Double, Double) -> [Float]?) -> [Window] {
        var windows: [Window] = []
        let halfWindow = config.windowSec / 2

        for range in speechRanges {
            let start = range.lowerBound
            let end = range.upperBound

            // 窗口中心从 start + halfWindow 开始，步长 stepSec
            var center = start + halfWindow
            while center + halfWindow <= end {
                let windowStart = max(0, center - halfWindow)
                let windowEnd = min(totalDuration, center + halfWindow)

                if let emb = embed(windowStart, windowEnd) {
                    windows.append(Window(time: center, embedding: emb))
                }
                center += config.stepSec
            }
        }

        return windows
    }

    /// 第一步：与人物库匹配，识别出已知说话人。
    /// - Parameters:
    ///   - windows: 窗口列表
    ///   - people: 人物库
    ///   - threshold: 匹配阈值
    ///   - aggregation: 聚合方式
    /// - Returns: 标注了 personId 的窗口列表
    public func matchKnownSpeakers(_ windows: [Window], people: [Person], threshold: Double,
                                   aggregation: SampleAggregation = .max) -> [Window] {
        guard !people.isEmpty else { return windows }

        let matcher = SpeakerMatcher(threshold: threshold, aggregation: aggregation)
        var result = windows

        for i in result.indices {
            var bestScore = 0.0
            var bestPerson: String?

            for person in people where !person.samples.isEmpty {
                let score = matcher.similarity(result[i].embedding, to: person)
                if score >= threshold && score > bestScore {
                    bestScore = score
                    bestPerson = person.id
                }
            }

            result[i].personId = bestPerson
        }

        return result
    }

    /// 第二步：粗分 - 在线聚类未识别窗口。
    /// 顺序扫描窗口，与已有簇中心比较，相似度超过阈值则并入，否则新建簇。
    /// 复杂度 O(n * k)，n 为窗口数，k 为簇数（通常 k << n）。
    public func coarseClustering(_ windows: [Window]) -> [Window] {
        var result = windows
        // 保存未归一化的累加和：并入时只需 O(d) 更新中心，避免重算全部成员
        var clusters: [(id: String, sum: [Float], centroid: [Float])] = []
        var nextId = 0

        for i in result.indices {
            // 已识别的窗口不参与聚类
            if let pid = result[i].personId {
                result[i].clusterId = "known_\(pid)"
                continue
            }

            let emb = result[i].embedding
            var bestSim = -1.0
            var bestCluster = -1
            for (idx, cluster) in clusters.enumerated() {
                let sim = VectorMath.cosine(emb, cluster.centroid)
                if sim > bestSim {
                    bestSim = sim
                    bestCluster = idx
                }
            }

            if bestSim >= config.coarseThreshold, bestCluster >= 0, clusters[bestCluster].sum.count == emb.count {
                result[i].clusterId = clusters[bestCluster].id
                for k in emb.indices { clusters[bestCluster].sum[k] += emb[k] }
                clusters[bestCluster].centroid = VectorMath.normalized(clusters[bestCluster].sum)
            } else {
                let id = "C\(nextId)"
                nextId += 1
                result[i].clusterId = id
                clusters.append((id: id, sum: emb, centroid: VectorMath.normalized(emb)))
            }
        }

        return result
    }

    /// 第三步：细化 - 层次聚类合并相似簇。
    /// 把粗分得到的簇中心做层次聚类（AHC），合并过于接近的簇。
    public func fineClustering(_ windows: [Window], numSpeakers: Int?) -> [Window] {
        // 统计每个簇的中心和时长
        var clusterStats: [String: (centroid: [Float], duration: Double, windows: [Int])] = [:]

        for (i, w) in windows.enumerated() {
            guard let cid = w.clusterId, !cid.hasPrefix("known_") else { continue }

            if clusterStats[cid] == nil {
                clusterStats[cid] = (centroid: [], duration: 0, windows: [])
            }
            clusterStats[cid]!.duration += config.stepSec
            clusterStats[cid]!.windows.append(i)
        }

        // 计算每个簇的加权中心
        for cid in clusterStats.keys {
            let indices = clusterStats[cid]!.windows
            var sum = [Float](repeating: 0, count: windows[indices[0]].embedding.count)
            for idx in indices {
                for k in sum.indices {
                    sum[k] += windows[idx].embedding[k]
                }
            }
            clusterStats[cid]!.centroid = VectorMath.normalized(sum)
        }

        guard !clusterStats.isEmpty else { return windows }

        // 层次聚类：每次合并最相似的一对
        var groups: [Set<String>] = clusterStats.keys.map { [$0] }

        func groupCentroid(_ g: Set<String>) -> [Float] {
            var sum = [Float](repeating: 0, count: clusterStats[g.first!]!.centroid.count)
            var totalDuration = 0.0
            for cid in g {
                let weight = Float(clusterStats[cid]!.duration)
                totalDuration += Double(weight)
                for k in sum.indices {
                    sum[k] += weight * clusterStats[cid]!.centroid[k]
                }
            }
            return totalDuration > 0 ? VectorMath.normalized(sum) : []
        }

        // 按相似度合并
        while groups.count > 1 {
            let centroids = groups.map(groupCentroid)
            var bestPair: (Int, Int, Double)?

            for a in groups.indices where !centroids[a].isEmpty {
                for b in groups.indices where b > a && !centroids[b].isEmpty {
                    let sim = VectorMath.cosine(centroids[a], centroids[b])
                    if sim > (bestPair?.2 ?? -2) {
                        bestPair = (a, b, sim)
                    }
                }
            }

            guard let (a, b, sim) = bestPair, sim >= config.fineThreshold else { break }

            // 合并 b 到 a
            groups[a].formUnion(groups[b])
            groups.remove(at: b)
        }

        // 如果指定了人数，继续合并到目标数量（不考虑阈值）
        if let targetCount = numSpeakers, targetCount > 0 {
            while groups.count > targetCount {
                let centroids = groups.map(groupCentroid)
                var bestPair: (Int, Int, Double)?

                for a in groups.indices where !centroids[a].isEmpty {
                    for b in groups.indices where b > a && !centroids[b].isEmpty {
                        let sim = VectorMath.cosine(centroids[a], centroids[b])
                        if sim > (bestPair?.2 ?? -2) {
                            bestPair = (a, b, sim)
                        }
                    }
                }

                guard let (a, b, _) = bestPair else { break }
                groups[a].formUnion(groups[b])
                groups.remove(at: b)
            }
        }

        // 构建簇映射
        var mergeMap: [String: String] = [:]
        for group in groups {
            // 组内选时长最长的簇 ID 作为代表
            let representative = group.max { clusterStats[$0]!.duration < clusterStats[$1]!.duration }!
            for cid in group {
                mergeMap[cid] = representative
            }
        }

        // 应用映射
        var result = windows
        for i in result.indices {
            if let cid = result[i].clusterId, !cid.hasPrefix("known_"), let newId = mergeMap[cid] {
                result[i].clusterId = newId
            }
        }

        return result
    }

    /// 第四步：合并碎簇。
    /// 将总时长过短的簇并入最相似的簇。
    public func mergeTinyClusters(_ windows: [Window]) -> [Window] {
        guard config.minSpeakerDuration > 0 else { return windows }

        // 统计每个簇的时长和中心
        var clusterStats: [String: (duration: Double, centroid: [Float], indices: [Int])] = [:]

        for (i, w) in windows.enumerated() {
            guard let cid = w.clusterId else { continue }

            if clusterStats[cid] == nil {
                clusterStats[cid] = (duration: 0, centroid: [], indices: [])
            }
            clusterStats[cid]!.duration += config.stepSec
            clusterStats[cid]!.indices.append(i)
        }

        // 计算中心
        for cid in clusterStats.keys {
            let indices = clusterStats[cid]!.indices
            var sum = [Float](repeating: 0, count: windows[indices[0]].embedding.count)
            for idx in indices {
                for k in sum.indices {
                    sum[k] += windows[idx].embedding[k]
                }
            }
            clusterStats[cid]!.centroid = VectorMath.normalized(sum)
        }

        // 找出碎簇，按时长升序
        let tinyClusters = clusterStats.keys
            .filter { clusterStats[$0]!.duration < config.minSpeakerDuration }
            .sorted { clusterStats[$0]!.duration < clusterStats[$1]!.duration }

        guard !tinyClusters.isEmpty else { return windows }

        // 依次合并碎簇
        var mergeMap: [String: String] = [:]
        var currentStats = clusterStats

        for tiny in tinyClusters {
            guard currentStats[tiny] != nil else { continue }

            // 找最相似的非碎簇
            let candidates = currentStats.keys.filter { cid in
                cid != tiny && currentStats[cid]!.duration >= config.minSpeakerDuration
            }

            guard !candidates.isEmpty else { continue }

            let tinyCenter = currentStats[tiny]!.centroid
            var bestSim = -1.0
            var bestTarget: String?

            for candidate in candidates {
                let sim = VectorMath.cosine(tinyCenter, currentStats[candidate]!.centroid)
                if sim >= config.tinySimilarity && sim > bestSim {
                    bestSim = sim
                    bestTarget = candidate
                }
            }

            // 合并到最相似的簇
            if let target = bestTarget {
                mergeMap[tiny] = target

                // 更新目标簇统计
                currentStats[target]!.duration += currentStats[tiny]!.duration
                currentStats[target]!.indices.append(contentsOf: currentStats[tiny]!.indices)

                // 重新计算中心
                let indices = currentStats[target]!.indices
                var sum = [Float](repeating: 0, count: windows[indices[0]].embedding.count)
                for idx in indices {
                    for k in sum.indices {
                        sum[k] += windows[idx].embedding[k]
                    }
                }
                currentStats[target]!.centroid = VectorMath.normalized(sum)

                // 移除碎簇
                currentStats.removeValue(forKey: tiny)
            }
        }

        // 应用映射
        var result = windows
        for i in result.indices {
            if let cid = result[i].clusterId, let newId = mergeMap[cid] {
                result[i].clusterId = newId
            }
        }

        return result
    }

    /// 将窗口簇转换为时间片段。
    /// 相邻同簇窗口合并为一个连续片段。
    public func windowsToSpans(_ windows: [Window]) -> [RawSpan] {
        guard !windows.isEmpty else { return [] }

        var spans: [RawSpan] = []
        let sortedWindows = windows.sorted { $0.time < $1.time }

        var currentSpeaker: String?
        var currentStart: Double?
        var currentEnd: Double?
        let halfWindow = config.windowSec / 2

        for w in sortedWindows {
            let speaker = w.personId ?? w.clusterId ?? "unknown"
            let start = w.time - halfWindow
            let end = w.time + halfWindow

            if speaker == currentSpeaker, let prevEnd = currentEnd, start - prevEnd < config.stepSec * 1.5 {
                // 同一说话人的相邻窗口，扩展片段
                currentEnd = end
            } else {
                // 不同说话人或有间隔，保存前一片段并开始新片段
                if let spk = currentSpeaker, let s = currentStart, let e = currentEnd {
                    spans.append(RawSpan(speaker: spk, start: s, end: e))
                }
                currentSpeaker = speaker
                currentStart = start
                currentEnd = end
            }
        }

        // 保存最后一个片段
        if let spk = currentSpeaker, let s = currentStart, let e = currentEnd {
            spans.append(RawSpan(speaker: spk, start: s, end: e))
        }

        return spans
    }

    /// 完整的快速分离流程。
    /// - Parameters:
    ///   - speechRanges: VAD 语音区间
    ///   - totalDuration: 音频总时长
    ///   - embed: 声纹提取闭包
    ///   - people: 人物库（可选）
    ///   - matchThreshold: 人物匹配阈值
    ///   - numSpeakers: 指定人数（nil 则自动确定）
    /// - Returns: 说话人片段
    public func diarize(speechRanges: [ClosedRange<Double>], totalDuration: Double,
                       embed: (Double, Double) -> [Float]?,
                       people: [Person] = [],
                       matchThreshold: Double = 0.6,
                       numSpeakers: Int? = nil) -> [RawSpan] {
        // 1. 提取窗口声纹
        var windows = extractWindows(speechRanges: speechRanges, totalDuration: totalDuration, embed: embed)

        guard !windows.isEmpty else { return [] }

        // 2. 匹配已知说话人
        if !people.isEmpty {
            windows = matchKnownSpeakers(windows, people: people, threshold: matchThreshold)
        }

        // 3. 粗分：在线聚类
        windows = coarseClustering(windows)

        // 4. 细化：层次聚类
        windows = fineClustering(windows, numSpeakers: numSpeakers)

        // 5. 合并碎簇
        windows = mergeTinyClusters(windows)

        // 6. 转换为片段
        return windowsToSpans(windows)
    }
}

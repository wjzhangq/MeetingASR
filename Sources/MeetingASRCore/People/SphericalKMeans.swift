import Foundation

/// 确定性随机数生成器（SplitMix64），保证跨平台一致。
struct SeededRandom {
    private var state: UInt64
    
    init(seed: UInt64) {
        self.state = seed
    }
    
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z &>> 27)) &* 0x94d049bb133111eb
        return z ^ (z &>> 31)
    }
    
    mutating func nextDouble() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

/// 球面 K-Means 聚类（余弦相似度）。
public struct SphericalKMeans: Sendable {
    public struct Item {
        public var id: Int
        public var vector: [Float]
        public var weight: Double
        
        public init(id: Int, vector: [Float], weight: Double) {
            self.id = id
            self.vector = vector
            self.weight = weight
        }
    }
    
    public init() {}
    
    /// K-Means 聚类。
    /// - Returns: 每个 item 的簇下标（0..<k）
    public func cluster(_ items: [Item], k: Int, config: SegmentClusteringConfig) -> [Int] {
        guard !items.isEmpty, k > 0 else { return [] }
        let kClamped = min(k, items.count)
        guard kClamped > 1 else { return Array(repeating: 0, count: items.count) }
        
        // K-Means++ 初始化。距离耗尽时中心数会少于 k，后面按实际中心数迭代。
        var rng = SeededRandom(seed: config.kmeansSeed)
        var centers = kMeansPlusPlusInit(items, k: kClamped, rng: &rng)
        guard !centers.isEmpty else { return [] }
        let kActual = centers.count
        var assignments = [Int](repeating: 0, count: items.count)
        
        for _ in 0..<config.kmeansMaxIterations {
            var changed = false
            for i in items.indices {
                let newCluster = nearestCenter(items[i].vector, centers: centers)
                if assignments[i] != newCluster {
                    assignments[i] = newCluster
                    changed = true
                }
            }
            
            if !changed { break }
            
            // 空簇保留上一轮中心，避免滤掉零向量后下标前移。
            centers = updateCenters(items, assignments: assignments, k: kActual, previous: centers)
        }
        
        return assignments
    }
    
    private func kMeansPlusPlusInit(_ items: [Item], k: Int, rng: inout SeededRandom) -> [[Float]] {
        guard !items.isEmpty else { return [] }
        
        var centers: [[Float]] = []
        
        // 随机选第一个中心
        let firstIdx = Int(rng.nextDouble() * Double(items.count))
        centers.append(items[firstIdx].vector)
        
        // K-Means++：按距离平方加权选择后续中心
        for _ in 1..<k {
            var distances: [Double] = []
            for item in items {
                let minDist = centers.map { 1.0 - VectorMath.cosine(item.vector, $0) }.min() ?? 0
                distances.append(max(0, minDist * minDist))
            }
            
            let total = distances.reduce(0, +)
            guard total > 0 else { break }
            
            var r = rng.nextDouble() * total
            for (i, d) in distances.enumerated() {
                r -= d
                if r <= 0 {
                    centers.append(items[i].vector)
                    break
                }
            }
        }
        
        return centers
    }
    
    private func nearestCenter(_ vec: [Float], centers: [[Float]]) -> Int {
        var bestIdx = 0
        var bestSim = -2.0
        for (i, center) in centers.enumerated() {
            let sim = VectorMath.cosine(vec, center)
            if sim > bestSim {
                bestSim = sim
                bestIdx = i
            }
        }
        return bestIdx
    }
    
    private func updateCenters(_ items: [Item], assignments: [Int], k: Int, previous: [[Float]]) -> [[Float]] {
        guard let dim = items.first?.vector.count, k > 0 else { return previous }
        
        var sums = [[Float]](repeating: [Float](repeating: 0, count: dim), count: k)
        var weights = [Double](repeating: 0, count: k)
        
        for (i, item) in items.enumerated() {
            let c = assignments[i]
            guard c >= 0, c < k, item.vector.count == dim else { continue }
            let w = Float(item.weight)
            weights[c] += item.weight
            for d in 0..<dim {
                sums[c][d] += w * item.vector[d]
            }
        }
        
        return (0..<k).map { c in
            if weights[c] > 0 { return VectorMath.normalized(sums[c]) }
            return c < previous.count ? previous[c] : sums[c]
        }
    }
}

/// 段聚类器：K-Means + 迭代合并 + 小簇吸收。
public struct SegmentClusterer: Sendable {
    private let config: SegmentClusteringConfig
    
    public init(config: SegmentClusteringConfig = SegmentClusteringConfig()) {
        self.config = config
    }
    
    /// 对一轨的段做聚类。
    /// - Parameters:
    ///   - targetCount: 本轨的说话人上限（来自「预计人数」）。给定时在阈值归并之后忽略阈值强制合并到该数；
    ///     nil 表示全自动，行为与未指定时完全一致。
    /// - Returns: 更新了 cluster 字段的段数组
    public func cluster(_ segments: [Segment], targetCount: Int? = nil) -> [Segment] {
        // 1. 筛选参与聚类的段
        let eligible = segments.enumerated().filter { idx, seg in
            seg.speechDuration >= config.shortSegmentSec && !seg.isMixed && !seg.embedding.isEmpty
        }

        guard !eligible.isEmpty else {
            return segments
        }

        // 2. K-Means
        // 指定人数时给 3 倍冗余：直接把 k 定成目标人数会让 KMeans 的初始化误差无从挽回，
        // 多分一些再归并回去更稳。
        var k = min(config.maxClusters, eligible.count)
        if let target = targetCount, target > 0 {
            k = min(k, target * 3)
        }
        let items = eligible.map { idx, seg in
            SphericalKMeans.Item(id: idx, vector: seg.embedding, weight: seg.speechDuration)
        }
        
        let kmeans = SphericalKMeans()
        let assignments = kmeans.cluster(items, k: k, config: config)

        // 去空簇并重新编号
        let usedClusters = Set(assignments)
        var clusterMap: [Int: String] = [:]
        for (i, c) in usedClusters.sorted().enumerated() {
            clusterMap[c] = "C\(i)"
        }
        
        var result = segments
        for (i, (idx, _)) in eligible.enumerated() {
            result[idx].cluster = clusterMap[assignments[i]]
        }
        
        // 3. 迭代合并
        result = mergeClusters(result)

        // 4. 小簇吸收
        result = mergeTinyClusters(result)

        // 5. 强制收到目标人数（指定了「预计人数」时）
        if let target = targetCount, target > 0 {
            result = forceMergeDown(result, to: target)
        }

        // 6. 重新分配。必须在强制合并之后：合并改了簇中心，段要按新中心重贴。
        result = reassignToFinalCenters(result)

        return result
    }

    /// 忽略相似度阈值，反复合并最相似的一对簇，直到簇数不超过 target。
    /// 用户明确给了人数，就以人数为准，不再让阈值说话。
    private func forceMergeDown(_ segments: [Segment], to target: Int) -> [Segment] {
        var result = segments
        var clusterStats = computeClusterStats(result)

        while clusterStats.count > target {
            var bestPair: (String, String)?
            var bestSim = -2.0

            let ids = clusterStats.keys.sorted()
            for i in ids.indices {
                for j in (i + 1)..<ids.count {
                    let a = ids[i], b = ids[j]
                    let sim = VectorMath.cosine(clusterStats[a]!.centroid, clusterStats[b]!.centroid)
                    if sim > bestSim {
                        bestSim = sim
                        bestPair = (a, b)
                    }
                }
            }

            // 找不到可合并的一对（簇中心为空等异常）就停手，不空转
            guard let (a, b) = bestPair else { break }

            // 保留时长长的那个标签
            let keep = clusterStats[a]!.duration >= clusterStats[b]!.duration ? a : b
            let drop = keep == a ? b : a
            for i in result.indices where result[i].cluster == drop {
                result[i].cluster = keep
            }
            clusterStats = computeClusterStats(result)
        }

        return renumber(result)
    }
    
    private func mergeClusters(_ segments: [Segment]) -> [Segment] {
        var result = segments
        var clusterStats = computeClusterStats(result)
        
        while clusterStats.count > 1 {
            var bestPair: (String, String)?
            var bestSim = -2.0
            
            let ids = clusterStats.keys.sorted()
            for i in ids.indices {
                for j in (i + 1)..<ids.count {
                    let a = ids[i], b = ids[j]
                    let sim = VectorMath.cosine(clusterStats[a]!.centroid, clusterStats[b]!.centroid)
                    if sim > bestSim {
                        bestSim = sim
                        bestPair = (a, b)
                    }
                }
            }
            
            guard let (a, b) = bestPair, bestSim >= config.mergeSimilarity else { break }
            
            for i in result.indices where result[i].cluster == b {
                result[i].cluster = a
            }
            clusterStats = computeClusterStats(result)
        }
        
        return renumber(result)
    }

    /// 簇标签按出现顺序重编为 C0、C1…，消除合并后留下的空号。
    private func renumber(_ segments: [Segment]) -> [Segment] {
        var result = segments
        let finalClusters = Set(result.compactMap(\.cluster)).sorted()
        let renameMap = Dictionary(uniqueKeysWithValues: finalClusters.enumerated().map { ($1, "C\($0)") })
        for i in result.indices {
            if let old = result[i].cluster, let new = renameMap[old] {
                result[i].cluster = new
            }
        }
        return result
    }
    
    private func mergeTinyClusters(_ segments: [Segment]) -> [Segment] {
        var clusterStats = computeClusterStats(segments)
        let tinyClusters = clusterStats.filter { $0.value.duration < config.minClusterSec }.keys.sorted()
        
        guard !tinyClusters.isEmpty else { return segments }
        
        var result = segments
        for tiny in tinyClusters {
            guard let tinyStats = clusterStats[tiny] else { continue }
            
            let candidates = clusterStats.filter { $0.key != tiny && $0.value.duration >= config.minClusterSec }
            guard !candidates.isEmpty else { continue }
            
            var bestTarget: String?
            var bestSim = -2.0
            for (cid, stats) in candidates {
                let sim = VectorMath.cosine(tinyStats.centroid, stats.centroid)
                if sim >= config.minClusterSimilarity && sim > bestSim {
                    bestSim = sim
                    bestTarget = cid
                }
            }
            
            if let target = bestTarget {
                for i in result.indices where result[i].cluster == tiny {
                    result[i].cluster = target
                }
                clusterStats = computeClusterStats(result)
            }
        }
        
        return result
    }
    
    private func reassignToFinalCenters(_ segments: [Segment]) -> [Segment] {
        let clusterStats = computeClusterStats(segments)
        var result = segments
        
        for i in result.indices {
            guard result[i].speechDuration >= config.shortSegmentSec,
                  !result[i].isMixed,
                  !result[i].embedding.isEmpty else { continue }
            
            var bestCluster: String?
            var bestSim = -2.0
            for (cid, stats) in clusterStats {
                let sim = VectorMath.cosine(result[i].embedding, stats.centroid)
                if sim > bestSim {
                    bestSim = sim
                    bestCluster = cid
                }
            }
            result[i].cluster = bestCluster
        }
        
        return result
    }
    
    private func computeClusterStats(_ segments: [Segment]) -> [String: (centroid: [Float], duration: Double)] {
        var stats: [String: (vectors: [[Float]], duration: Double)] = [:]
        
        for seg in segments {
            guard let cid = seg.cluster, !seg.embedding.isEmpty else { continue }
            if stats[cid] == nil {
                stats[cid] = (vectors: [], duration: 0)
            }
            stats[cid]!.vectors.append(seg.embedding)
            stats[cid]!.duration += seg.speechDuration
        }
        
        return stats.mapValues { (centroid: VectorMath.meanNormalized($0.vectors), duration: $0.duration) }
    }
}

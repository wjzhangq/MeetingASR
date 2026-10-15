import Foundation

/// 分离后的簇合并参数。
public struct ClusterMergeConfig: Sendable, Equatable {
    /// 两个簇声纹中心的余弦相似度 ≥ 该值时合并；0 关闭
    public var similarity: Double = 0.65
    /// 总时长短于该值（秒）的簇视为碎簇，并入最相近的簇；0 关闭
    public var minSpeakerSec: Double = 2
    /// 碎簇并入时的最低相似度
    public var tinySimilarity: Double = 0.45
    /// 每个簇用于计算声纹中心的片段数与片段长度
    public var clipsPerCluster: Int = 6
    public var clipMinSec: Double = 1
    public var clipMaxSec: Double = 6

    public init() {}
}

/// 说话人簇合并（解决分离分得过细，如 1 分钟会议出现 S6）：
/// 1. 两个簇与人物库中同一人匹配（≥ 匹配阈值）→ 合并；
/// 2. 人数未指定时，声纹中心相似度 ≥ similarity 的簇逐对合并；
/// 3. 总时长很短的碎簇并入最相近的簇。
public struct SpeakerClusterMerger: Sendable {
    public var config: ClusterMergeConfig

    public init(config: ClusterMergeConfig = ClusterMergeConfig()) {
        self.config = config
    }

    /// 簇的统计信息。
    public struct Cluster: Equatable, Sendable {
        public var id: String
        public var duration: Double
        /// 声纹中心（已归一化），无可用片段时为空
        public var centroid: [Float]
    }

    /// 人物匹配：声纹 → (人物 ID, 相似度)。
    public typealias Identify = ([Float]) -> (personId: String, score: Double)?

    /// - Parameters:
    ///   - fixedSpeakerCount: 用户指定了人数时不做相似度/碎簇合并（只做同一人物合并）
    ///   - embed: 给定区间（与 spans 同一时间轴）返回声纹，失败返回 nil
    /// - Returns: 重新标注后的片段（被合并簇改用保留簇的标签）
    public func merge(_ spans: [RawSpan], fixedSpeakerCount: Int?, matchThreshold: Double,
                      embed: (Double, Double) -> [Float]?, identify: Identify?) -> [RawSpan] {
        let clusters = clusterStats(spans, embed: embed)
        guard clusters.count > 1 else { return spans }
        let map = mergeMap(clusters, fixedSpeakerCount: fixedSpeakerCount, matchThreshold: matchThreshold, identify: identify)
        return spans.map { var s = $0; s.speaker = map[s.speaker] ?? s.speaker; return s }
    }

    /// 计算每个簇的时长与声纹中心（取最长的若干片段，每段取中间 clipMaxSec）。
    public func clusterStats(_ spans: [RawSpan], embed: (Double, Double) -> [Float]?) -> [Cluster] {
        var order: [String] = []
        var bySpeaker: [String: [RawSpan]] = [:]
        for s in spans where s.end > s.start {
            if bySpeaker[s.speaker] == nil { order.append(s.speaker) }
            bySpeaker[s.speaker, default: []].append(s)
        }
        return order.map { id in
            let list = bySpeaker[id]!
            let picked = list.filter { $0.duration >= config.clipMinSec }
                .sorted { $0.duration > $1.duration }
                .prefix(config.clipsPerCluster)
            let embs = picked.compactMap { s -> [Float]? in
                let mid = (s.start + s.end) / 2, half = min(s.duration, config.clipMaxSec) / 2
                return embed(mid - half, mid + half)
            }
            return Cluster(id: id, duration: list.reduce(0) { $0 + $1.duration }, centroid: VectorMath.meanNormalized(embs))
        }
    }

    /// 计算合并映射：簇 ID → 保留的簇 ID（组内时长最长者）。
    public func mergeMap(_ clusters: [Cluster], fixedSpeakerCount: Int?, matchThreshold: Double, identify: Identify?) -> [String: String] {
        // 每组：成员下标
        var groups: [[Int]] = clusters.indices.map { [$0] }

        func centroid(_ g: [Int]) -> [Float] {
            // 按时长加权的组中心
            var acc: [Float] = []
            for i in g where !clusters[i].centroid.isEmpty {
                let w = Float(clusters[i].duration)
                if acc.isEmpty { acc = [Float](repeating: 0, count: clusters[i].centroid.count) }
                guard acc.count == clusters[i].centroid.count else { continue }
                for k in acc.indices { acc[k] += w * clusters[i].centroid[k] }
            }
            return acc.isEmpty ? [] : VectorMath.normalized(acc)
        }
        func duration(_ g: [Int]) -> Double { g.reduce(0) { $0 + clusters[$1].duration } }
        func join(_ a: Int, _ b: Int) {
            groups[a].append(contentsOf: groups[b])
            groups.remove(at: b)
        }

        // 1. 与同一人物匹配的簇合并
        if let identify {
            var byPerson: [String: Int] = [:]
            var gi = 0
            while gi < groups.count {
                let c = centroid(groups[gi])
                if !c.isEmpty, let m = identify(c), m.score >= matchThreshold {
                    if let target = byPerson[m.personId] {
                        join(target, gi)
                        continue
                    }
                    byPerson[m.personId] = gi
                }
                gi += 1
            }
        }

        if fixedSpeakerCount == nil {
            // 2. 相似度合并：每次合并最相似的一对
            if config.similarity > 0 {
                while groups.count > 1 {
                    let cs = groups.map(centroid)
                    var best: (Int, Int, Double)?
                    for a in cs.indices where !cs[a].isEmpty {
                        for b in cs.indices where b > a && !cs[b].isEmpty {
                            let s = VectorMath.cosine(cs[a], cs[b])
                            if s > (best?.2 ?? -2) { best = (a, b, s) }
                        }
                    }
                    guard let (a, b, s) = best, s >= config.similarity else { break }
                    join(a, b)
                }
            }
            // 3. 碎簇并入最相近的非碎簇
            if config.minSpeakerSec > 0 {
                var changed = true
                while changed, groups.count > 1 {
                    changed = false
                    let cs = groups.map(centroid)
                    let tiny = groups.indices.filter { duration(groups[$0]) < config.minSpeakerSec && !cs[$0].isEmpty }
                        .sorted { duration(groups[$0]) < duration(groups[$1]) }
                    for t in tiny {
                        let cands = groups.indices.filter { $0 != t && !cs[$0].isEmpty && duration(groups[$0]) >= config.minSpeakerSec }
                        guard let target = cands.max(by: { VectorMath.cosine(cs[t], cs[$0]) < VectorMath.cosine(cs[t], cs[$1]) }),
                              VectorMath.cosine(cs[t], cs[target]) >= config.tinySimilarity else { continue }
                        join(target, t)
                        changed = true
                        break
                    }
                }
            }
        }

        var map: [String: String] = [:]
        for g in groups {
            let keep = g.max { clusters[$0].duration < clusters[$1].duration }!
            for i in g where i != keep { map[clusters[i].id] = clusters[keep].id }
        }
        return map
    }
}

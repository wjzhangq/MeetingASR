import Foundation

/// 长音频分块分离参数。
///
/// sherpa-onnx 的分离对整段音频一次完成：前半程（pyannote 切分）没有进度回调、中途无法取消，
/// 聚类的距离矩阵随声纹数平方增长（1 小时约 5600 个声纹）。长音频按块分离：每块独立聚类，
/// 块之间更新进度、检查取消，最后用声纹中心把各块的说话人统一编号。
public struct BlockDiarizationConfig: Sendable, Equatable {
    /// 块长（秒）；音频不超过 1.5 倍块长时不分块；0 关闭分块。
    /// 块越短，取消越及时、无回调阶段越短；聚类在块内完成，2 分钟足够区分说话人
    public var blockSec: Double = 120
    /// 在目标切点前后该范围内找最安静处切开（秒）
    public var searchSec: Double = 30
    /// 跨块说话人声纹中心相似度 ≥ 该值时视为同一人
    public var linkSimilarity: Double = 0.5

    public init() {}
}

public enum BlockPlanner {
    /// 把 [from, count) 切成若干块（样本下标），切点取目标位置附近能量最低的 0.2 秒帧中点。
    /// - Parameter from: 起点（前面部分已在录音期间分离，见 LiveDiarizer）
    public static func blocks(_ samples: [Float], sampleRate: Int, config: BlockDiarizationConfig, from: Int = 0) -> [Range<Int>] {
        let n = samples.count
        guard from < n else { return from == 0 ? [0..<n] : [] }
        let block = Int(config.blockSec * Double(sampleRate))
        guard block > 0, n - from > block + block / 2 else { return [from..<n] }
        let search = Int(config.searchSec * Double(sampleRate))
        var out: [Range<Int>] = []
        var start = from
        while n - start > block + block / 2 {
            let target = start + block
            let lo = max(start + block / 2, target - search), hi = min(n - block / 2, target + search)
            let cut = quietestCut(samples, lo: lo, hi: hi, target: target, sampleRate: sampleRate)
            out.append(start..<cut)
            start = cut
        }
        out.append(start..<n)
        return out
    }

    /// 在 [lo, hi) 内找能量最低的 0.2 秒帧，返回其中点；范围不足一帧时返回 target。
    public static func quietestCut(_ samples: [Float], lo: Int, hi: Int, target: Int, sampleRate: Int) -> Int {
        let frame = max(1, sampleRate / 5)
        var cut = target
        var best = Float.infinity
        var i = max(0, lo)
        let end = min(hi, samples.count)
        while i + frame <= end {
            var e: Float = 0
            for k in i..<(i + frame) { e += samples[k] * samples[k] }
            if e < best { best = e; cut = i + frame / 2 }
            i += frame
        }
        return cut
    }
}

/// 跨块说话人关联：同一块内的不同簇不合并（分离已判定为不同人，块内的过细问题由 SpeakerClusterMerger 处理），
/// 不同块的簇按声纹中心相似度逐对合并。
public enum CrossBlockLinker {
    public struct Item: Sendable, Equatable {
        public var id: String
        public var block: Int
        public var duration: Double
        /// 已归一化的声纹中心，空表示没有可用片段
        public var centroid: [Float]

        public init(id: String, block: Int, duration: Double, centroid: [Float]) {
            self.id = id
            self.block = block
            self.duration = duration
            self.centroid = centroid
        }
    }

    /// - Parameter fixedCount: 用户指定了人数时，在阈值合并后继续合并到不超过该人数
    /// - Returns: 簇 ID → 统一后的簇 ID（组内时长最长者）
    public static func link(_ items: [Item], similarity: Double, fixedCount: Int?) -> [String: String] {
        var groups: [[Int]] = items.indices.map { [$0] }
        func centroid(_ g: [Int]) -> [Float] {
            var acc: [Float] = []
            for i in g where !items[i].centroid.isEmpty {
                if acc.isEmpty { acc = [Float](repeating: 0, count: items[i].centroid.count) }
                guard acc.count == items[i].centroid.count else { continue }
                let w = Float(max(items[i].duration, 1e-3))
                for k in acc.indices { acc[k] += w * items[i].centroid[k] }
            }
            return acc.isEmpty ? [] : VectorMath.normalized(acc)
        }
        func blocks(_ g: [Int]) -> Set<Int> { Set(g.map { items[$0].block }) }

        /// 最相似的一对（可选：是否允许同块）
        func bestPair(allowSameBlock: Bool) -> (Int, Int, Double)? {
            let cs = groups.map(centroid)
            let bs = groups.map(blocks)
            var best: (Int, Int, Double)?
            for a in groups.indices where !cs[a].isEmpty {
                for b in groups.indices where b > a && !cs[b].isEmpty {
                    if !allowSameBlock, !bs[a].isDisjoint(with: bs[b]) { continue }
                    let s = VectorMath.cosine(cs[a], cs[b])
                    if s > (best?.2 ?? -2) { best = (a, b, s) }
                }
            }
            return best
        }
        func join(_ a: Int, _ b: Int) {
            groups[a].append(contentsOf: groups[b])
            groups.remove(at: b)
        }

        while let (a, b, s) = bestPair(allowSameBlock: false), s >= similarity { join(a, b) }
        if let k = fixedCount, k > 0 {
            while groups.count > k, let (a, b, _) = bestPair(allowSameBlock: false) ?? bestPair(allowSameBlock: true) { join(a, b) }
        }

        var map: [String: String] = [:]
        for g in groups {
            let keep = g.max { items[$0].duration < items[$1].duration }!
            for i in g { map[items[i].id] = items[keep].id }
        }
        return map
    }
}

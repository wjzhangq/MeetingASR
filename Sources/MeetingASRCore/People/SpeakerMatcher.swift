import Foundation

/// 说话人与人物的相似度聚合方式（M0 评估）。
public enum SampleAggregation: String, Codable, Sendable {
    /// 取该人物所有样本中的最高相似度
    case max
    /// 取所有样本相似度的均值
    case mean
}

/// 人物库匹配（4.6 匹配规则）。
public struct SpeakerMatcher: Sendable {
    public var threshold: Double
    public var aggregation: SampleAggregation

    public init(threshold: Double = 0.6, aggregation: SampleAggregation = .max) {
        self.threshold = threshold
        self.aggregation = aggregation
    }

    public struct Result: Equatable, Sendable {
        /// 达到阈值的一对一分配：说话人 → 匹配
        public var assigned: [String: SpeakerMatch]
        /// 每个说话人的最佳候选（不考虑一对一与阈值，记录用）
        public var best: [String: SpeakerMatch]
    }

    /// 计算说话人与人物的相似度。
    public func similarity(_ embedding: [Float], to person: Person) -> Double {
        let sims = person.samples.map { VectorMath.cosine(embedding, $0.embedding) }
        guard !sims.isEmpty else { return 0 }
        switch aggregation {
        case .max: return sims.max()!
        case .mean: return sims.reduce(0, +) / Double(sims.count)
        }
    }

    /// - Parameter speakers: (说话人 ID, 声纹)
    public func match(speakers: [(id: String, embedding: [Float])], people: [Person]) -> Result {
        let candidates = people.filter { !$0.samples.isEmpty }
        guard !speakers.isEmpty, !candidates.isEmpty else { return Result(assigned: [:], best: [:]) }
        let sim = speakers.map { s in candidates.map { similarity(s.embedding, to: $0) } }

        var best: [String: SpeakerMatch] = [:]
        for (i, s) in speakers.enumerated() {
            if let j = sim[i].indices.max(by: { sim[i][$0] < sim[i][$1] }) {
                best[s.id] = SpeakerMatch(personId: candidates[j].id, score: sim[i][j])
            }
        }

        // 低于阈值的配对权重置 0，避免为凑整体最优而牺牲达标配对
        let weights = sim.map { row in row.map { $0 >= threshold ? $0 : 0 } }
        let assignment = Hungarian.maximize(weights)
        var assigned: [String: SpeakerMatch] = [:]
        for (i, j) in assignment.enumerated() {
            guard let j, sim[i][j] >= threshold else { continue }
            assigned[speakers[i].id] = SpeakerMatch(personId: candidates[j].id, score: sim[i][j])
        }
        return Result(assigned: assigned, best: best)
    }
}

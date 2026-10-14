import Foundation

public enum VectorMath {
    public static func norm(_ v: [Float]) -> Float {
        var s: Float = 0
        for x in v { s += x * x }
        return sqrt(s)
    }

    public static func normalized(_ v: [Float]) -> [Float] {
        let n = norm(v)
        return n > 0 ? v.map { $0 / n } : v
    }

    /// 余弦相似度；维度不同或含零向量时返回 0。
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return Double(dot / (sqrt(na) * sqrt(nb)))
    }

    /// 各向量先归一化再取平均，最后再归一化。
    public static func meanNormalized(_ vs: [[Float]]) -> [Float] {
        let valid = vs.filter { !$0.isEmpty }
        guard let dim = valid.first?.count else { return [] }
        var acc = [Float](repeating: 0, count: dim)
        for v in valid where v.count == dim {
            let n = normalized(v)
            for i in 0..<dim { acc[i] += n[i] }
        }
        return normalized(acc)
    }
}

/// 匈牙利算法（Kuhn-Munkres），求矩形矩阵上的最大权一对一分配。
public enum Hungarian {
    /// - Parameter weights: rows × cols 的权重矩阵
    /// - Returns: 每行分配到的列下标（未分配为 nil）
    public static func maximize(_ weights: [[Double]]) -> [Int?] {
        let rows = weights.count
        guard rows > 0, let cols = weights.first?.count, cols > 0 else { return Array(repeating: nil, count: rows) }
        let n = max(rows, cols)
        let maxW = weights.flatMap { $0 }.max() ?? 0
        // 转为方阵最小化问题，补齐的格子代价为 maxW（相当于权重 0）
        var cost = [[Double]](repeating: [Double](repeating: maxW, count: n), count: n)
        for i in 0..<rows { for j in 0..<cols { cost[i][j] = maxW - weights[i][j] } }

        // 经典 O(n^3) 实现（下标从 1 开始）
        var u = [Double](repeating: 0, count: n + 1)
        var v = [Double](repeating: 0, count: n + 1)
        var p = [Int](repeating: 0, count: n + 1)
        var way = [Int](repeating: 0, count: n + 1)
        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minv = [Double](repeating: .infinity, count: n + 1)
            var used = [Bool](repeating: false, count: n + 1)
            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = Double.infinity
                var j1 = 0
                for j in 1...n where !used[j] {
                    let cur = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if cur < minv[j] { minv[j] = cur; way[j] = j0 }
                    if minv[j] < delta { delta = minv[j]; j1 = j }
                }
                for j in 0...n {
                    if used[j] { u[p[j]] += delta; v[j] -= delta } else { minv[j] -= delta }
                }
                j0 = j1
            } while p[j0] != 0
            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }
        var result = [Int?](repeating: nil, count: rows)
        for j in 1...n where p[j] >= 1 && p[j] <= rows && j <= cols {
            result[p[j] - 1] = j - 1
        }
        return result
    }
}

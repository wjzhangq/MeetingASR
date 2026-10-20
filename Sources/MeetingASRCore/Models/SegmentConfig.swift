import Foundation

/// VAD 分段参数（需实测标定）。
public struct SegmentVADConfig: Codable, Sendable, Equatable {
    /// 判定为语音的概率阈值
    public var threshold: Float = 0.5
    /// 停顿超过该时长才切段，越小切得越碎
    public var minSilenceDuration: Float = 0.4
    /// 过滤咳嗽、敲键盘等噪声
    public var minSpeechDuration: Float = 0.25
    /// 超长段强制切开，限制单段混入多人的概率
    /// 注意：sherpa-onnx VAD 的此参数可能失效，实测可输出数百秒的段
    public var maxSpeechDuration: Float = 12
    /// 前补边：VAD 边界常切掉首字起音
    public var padBefore: Double = 0.15
    /// 后补边：VAD 边界常切掉尾字收音
    public var padAfter: Double = 0.1

    public init() {}
}

/// 段级声纹与聚类参数（需实测标定）。
public struct SegmentClusteringConfig: Codable, Sendable, Equatable {
    /// 短于该值的段不参与聚类，事后归属
    public var shortSegmentSec: Double = 1.0
    /// 长于该值的段按子窗口提声纹
    public var longSegmentSec: Double = 4.0
    public var subwindowSec: Double = 2.0
    public var subwindowStepSec: Double = 1.0
    /// 相邻子窗口相似度低于该值视为低谷（疑似混合段）
    public var mixedValley: Double = 0.3
    /// 低谷两侧各自内部平均相似度下限
    public var mixedSideSimilarity: Double = 0.5
    /// K-Means 的 k 上限
    public var maxClusters: Int = 20
    public var kmeansMaxIterations: Int = 50
    /// 固定随机种子，保证同一段录音每次结果一样
    public var kmeansSeed: UInt64 = 20_251_017
    /// 簇中心相似度 ≥ 该值则合并
    public var mergeSimilarity: Double = 0.38
    /// 总时长短于该值的簇不单独成人
    public var minClusterSec: Double = 3.0
    /// 小簇并入时的最低相似度
    public var minClusterSimilarity: Double = 0.45
    /// 短段归属的最低相似度
    public var shortAssignSimilarity: Double = 0.25
    /// 短段就近归属的时间窗口
    public var shortAssignNearbySec: Double = 2.0
    /// 混合段标签平滑长度：持续不足该值的标签片段并入相邻片段
    public var smoothRunSec: Double = 1.5
    /// 同一说话人相邻段间隔小于该值合并为一轮
    public var turnMergeGap: Double = 1.0

    public init() {}
}

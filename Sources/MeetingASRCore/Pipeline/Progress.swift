import Foundation

/// 处理阶段（FR-P2 菜单栏显示当前阶段）。
public enum ProcessingStage: String, Sendable, CaseIterable {
    case preprocess
    case diarization
    case recognition
    case speakerID
    case output
    case cleanup

    public var displayName: String {
        switch self {
        case .preprocess: return "预处理"
        case .diarization: return "说话人分离"
        case .recognition: return "语音识别"
        case .speakerID: return "人物匹配"
        case .output: return "生成结果"
        case .cleanup: return "清理"
        }
    }

    /// 各阶段在总进度中的占比（按 1 小时会议实测耗时：分离约 70%、识别约 25%）
    var weight: Double {
        switch self {
        case .preprocess: return 0.03
        case .diarization: return 0.62
        case .recognition: return 0.30
        case .speakerID: return 0.03
        case .output: return 0.01
        case .cleanup: return 0.01
        }
    }

    var startFraction: Double {
        var acc = 0.0
        for s in Self.allCases {
            if s == self { return acc }
            acc += s.weight
        }
        return acc
    }
}

public struct ProcessingProgress: Sendable, Equatable {
    public var stage: ProcessingStage
    /// 总体进度 0...1
    public var fraction: Double

    public init(stage: ProcessingStage, fraction: Double) {
        self.stage = stage
        self.fraction = fraction
    }

    public static func at(_ stage: ProcessingStage, _ within: Double) -> ProcessingProgress {
        ProcessingProgress(stage: stage, fraction: stage.startFraction + stage.weight * min(1, max(0, within)))
    }

    public var percent: Int { Int((fraction * 100).rounded(.down)) }

    /// 当前阶段内的进度 0...1
    public var stageFraction: Double {
        min(1, max(0, (fraction - stage.startFraction) / stage.weight))
    }

    /// 当前阶段内的百分比
    public var stagePercent: Int { Int((stageFraction * 100).rounded(.down)) }
}

/// 线程安全的取消标志（FR-P7）。
public final class CancellationFlag: @unchecked Sendable {
    private var cancelled = false
    private let lock = NSLock()

    public init() {}

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func check() throws {
        if isCancelled { throw CancellationError() }
    }
}

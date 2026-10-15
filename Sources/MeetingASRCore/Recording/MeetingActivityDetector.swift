import Foundation

/// 会议开始/结束检测（与平台无关的状态机）。
///
/// 输入为定时采样的会议软件音频状态：会议软件进程正在采集麦克风（Core Audio
/// `kAudioProcessPropertyIsRunningInput`）视为进入通话；持续一段时间才判定会议开始，
/// 避免试听麦克风等短暂占用。会议中只要仍在采集或播放声音就保持；两者都停止一段时间后判定会议结束。
public struct MeetingActivityDetector: Sendable {
    public struct Config: Sendable, Equatable {
        /// 持续采集麦克风达到该时长判定会议开始
        public var startAfter: Double = 5
        /// 采集与播放都停止达到该时长判定会议结束
        public var endAfter: Double = 15

        public init() {}
    }

    /// 一次采样。
    public struct Observation: Sendable, Equatable {
        /// 正在采集麦克风的会议软件名称，nil 表示没有
        public var inputApp: String?
        /// 是否有会议软件正在播放声音
        public var outputActive: Bool

        public init(inputApp: String?, outputActive: Bool) {
            self.inputApp = inputApp
            self.outputActive = outputActive
        }
    }

    public enum Event: Sendable, Equatable {
        case started(app: String)
        case ended(app: String)
    }

    enum State: Sendable, Equatable {
        case idle
        case candidate(app: String, since: Double)
        case inMeeting(app: String, quietSince: Double?)
    }

    public var config: Config
    private(set) var state: State = .idle

    public init(config: Config = Config()) {
        self.config = config
    }

    /// 是否处于会议中（已判定开始、尚未结束）。
    public var inMeeting: Bool {
        if case .inMeeting = state { return true }
        return false
    }

    /// 当前会议软件名称（会议中或候选中）。
    public var currentApp: String? {
        switch state {
        case .idle: return nil
        case .candidate(let app, _), .inMeeting(let app, _): return app
        }
    }

    /// 输入一次采样，返回状态变化事件。
    public mutating func update(_ obs: Observation, now: Double) -> Event? {
        switch state {
        case .idle:
            if let app = obs.inputApp { state = .candidate(app: app, since: now) }
            return nil
        case .candidate(let app, let since):
            guard obs.inputApp != nil else {
                state = .idle
                return nil
            }
            if now - since >= config.startAfter {
                state = .inMeeting(app: app, quietSince: nil)
                return .started(app: app)
            }
            return nil
        case .inMeeting(let app, let quietSince):
            if obs.inputApp != nil || obs.outputActive {
                state = .inMeeting(app: app, quietSince: nil)
                return nil
            }
            let q = quietSince ?? now
            if now - q >= config.endAfter {
                state = .idle
                return .ended(app: app)
            }
            state = .inMeeting(app: app, quietSince: q)
            return nil
        }
    }

    /// 重置（关闭检测时）。
    public mutating func reset() {
        state = .idle
    }
}

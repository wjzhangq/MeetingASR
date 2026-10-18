import Foundation

/// 录音状态（FR-R1）。
public enum RecorderState: Equatable, Sendable {
    case idle
    case recording
    case paused
}

/// 会话时钟：把主机时间映射到"已录音频时间轴"（暂停区间被剔除）。
/// 所有音轨按同一时钟写入，从而在暂停、断流后保持对齐。线程安全。
public final class SessionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _state: RecorderState = .idle
    /// 当前这一段录音开始的主机时间
    private var runStartHost: Double = 0
    /// 之前各段累计的录音时长
    private var accumulated: Double = 0
    private var _startHost: Double?

    public init() {}

    public var state: RecorderState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    /// 会话开始的主机时间
    public var startHostTime: Double? {
        lock.lock(); defer { lock.unlock() }
        return _startHost
    }

    public func start(at host: Double) {
        lock.lock(); defer { lock.unlock() }
        _state = .recording
        runStartHost = host
        accumulated = 0
        _startHost = host
    }

    /// 暂停，返回暂停时刻的已录时长。
    @discardableResult
    public func pause(at host: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard _state == .recording else { return accumulated }
        accumulated += max(0, host - runStartHost)
        _state = .paused
        return accumulated
    }

    public func resume(at host: Double) {
        lock.lock(); defer { lock.unlock() }
        guard _state == .paused else { return }
        runStartHost = host
        _state = .recording
    }

    /// 停止，返回总录音时长。
    @discardableResult
    public func stop(at host: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        if _state == .recording { accumulated += max(0, host - runStartHost) }
        _state = .idle
        return accumulated
    }

    /// 某主机时间对应的会话时间；暂停中、未开始或早于本段开始时返回 nil。
    public func sessionTime(atHost host: Double) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard _state == .recording, host >= runStartHost - 0.05 else { return nil }
        return accumulated + max(0, host - runStartHost)
    }

    /// 当前已录时长（用于菜单栏显示）。
    public func elapsed(now host: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        switch _state {
        case .recording: return accumulated + max(0, host - runStartHost)
        case .paused, .idle: return accumulated
        }
    }
}

/// 按会话时钟写入的单条音轨：
/// - 记录首帧主机时间（FR-A4）；
/// - 输入出现空档（暂停后恢复、Tap 重新挂载、输入设备重建）时补静音，保证与其他音轨对齐；
/// - 暂停期间的数据丢弃（FR-R3）。
public final class AlignedTrackWriter: @unchecked Sendable {
    public let kind: TrackKind
    public let sampleRate: Int
    private let writer: WavWriter
    private let clock: SessionClock
    private let lock = NSLock()
    /// 首帧主机时间
    public private(set) var firstHostTime: Double?
    /// 首帧对应的会话时间
    private var startSessionTime: Double = 0
    /// 允许的时间偏差，超过则补静音或裁剪
    public var tolerance: Double = 0.05
    /// 实际写入文件的样本（含补上的静音）及其第一帧的会话时间。在写锁之外回调。
    public var onSamplesWritten: (([Float], Double) -> Void)?

    public init(kind: TrackKind, url: URL, sampleRate: Int, clock: SessionClock) throws {
        self.kind = kind
        self.sampleRate = sampleRate
        self.clock = clock
        writer = try WavWriter(url: url, sampleRate: sampleRate, channels: 1, format: .int16)
    }

    public var url: URL { writer.url }

    /// 已写入时长（秒）
    public var durationSec: Double {
        lock.lock(); defer { lock.unlock() }
        return writer.durationSec
    }

    /// 追加单声道样本。
    /// - Parameter hostTime: 该缓冲首帧的主机时间（秒）
    public func append(_ samples: [Float], hostTime: Double) {
        guard !samples.isEmpty, let t = clock.sessionTime(atHost: hostTime) else { return }
        var pieces: [([Float], Double)] = []
        lock.lock()
        if firstHostTime == nil {
            firstHostTime = hostTime
            startSessionTime = t
        }
        let expected = Int64(((t - startSessionTime) * Double(sampleRate)).rounded())
        let written = writer.framesWritten
        let tol = Int64(tolerance * Double(sampleRate))
        if expected > written + tol {
            var gap = Int(expected - written)
            var session = startSessionTime + Double(written) / Double(sampleRate)
            while gap > 0 {
                let n = min(sampleRate, gap)
                let zeros = [Float](repeating: 0, count: n)
                writer.write(zeros)
                pieces.append((zeros, session))
                session += Double(n) / Double(sampleRate)
                gap -= n
            }
            writer.write(samples)
            pieces.append((samples, session))
        } else if expected < written - tol {
            // 数据与已写内容重叠（时钟抖动），丢弃重叠部分
            let skip = Int(min(Int64(samples.count), written - expected))
            if skip < samples.count {
                let tail = Array(samples[skip...])
                let session = startSessionTime + Double(written) / Double(sampleRate)
                writer.write(tail)
                pieces.append((tail, session))
            }
        } else {
            let session = startSessionTime + Double(written) / Double(sampleRate)
            writer.write(samples)
            pieces.append((samples, session))
        }
        let callback = onSamplesWritten
        lock.unlock()
        for (chunk, session) in pieces {
            callback?(chunk, session)
        }
    }

    /// 定期刷新 WAV 头，异常退出后仍可读取。
    public func flushHeader() {
        lock.lock(); defer { lock.unlock() }
        writer.updateHeader()
    }

    public func close() throws {
        lock.lock(); defer { lock.unlock() }
        try writer.close()
    }
}

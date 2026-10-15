import Foundation

/// 进度心跳：推理库内部没有进度回调的阶段（如 pyannote 切分、聚类），按预计用时在后台线程持续推进进度，
/// 避免界面长时间停在同一个百分比。
///
/// - 估计值按 1 - e^(-t/预计用时) 逼近区间上限，不会到达，实际耗时比预计长时仍缓慢前进；
/// - 收到真实进度时以真实值为准；上报值单调不减；
/// - 所有上报都在内部锁内串行执行（调用方的进度回调不必线程安全）。
public final class ProgressTicker: @unchecked Sendable {
    private let lock = NSLock()
    private let report: (Double) -> Void
    private var timer: DispatchSourceTimer?
    private var last: Double
    private var stopped = false
    /// 当前估计区间
    private var from: Double = 0
    private var to: Double = 0
    private var expected: Double = 1
    private var since = Date()
    private var estimating = false

    public init(start: Double = 0, interval: Double = 0.5, report: @escaping (Double) -> Void) {
        self.report = report
        last = start
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "meetingasr.progress", qos: .utility))
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    deinit { stop() }

    /// 开始在 [from, to) 内按预计用时估计进度。
    public func estimate(from: Double, to: Double, expectedSeconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        self.from = max(from, last)
        self.to = max(to, self.from)
        expected = max(0.1, expectedSeconds)
        since = Date()
        estimating = true
    }

    /// 真实进度：停止估计并上报（不小于已上报值）。
    public func set(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        estimating = false
        emit(value)
    }

    /// 停止心跳；之后不再上报。
    public func stop() {
        lock.lock()
        stopped = true
        estimating = false
        let t = timer
        timer = nil
        lock.unlock()
        t?.cancel()
    }

    private func tick() {
        lock.lock()
        defer { lock.unlock() }
        guard estimating else { return }
        let x = Date().timeIntervalSince(since) / expected
        emit(from + (to - from) * (1 - exp(-x)))
    }

    /// 调用时须持有锁。
    private func emit(_ v: Double) {
        // 至少前进 0.1% 才上报，避免高频回调刷屏
        guard !stopped, v > last + 1e-6, v - last >= 0.001 || v >= 1 else { return }
        last = v
        report(v)
    }
}

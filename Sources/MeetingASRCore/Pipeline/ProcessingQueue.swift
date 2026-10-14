import Foundation

/// 队列事件，供 UI 订阅。
public enum ProcessingEvent: Sendable {
    case queued(MeetingPaths, position: Int)
    case started(MeetingPaths)
    case progress(MeetingPaths, ProcessingProgress)
    case finished(MeetingPaths, Transcript)
    case failed(MeetingPaths, String)
    case cancelled(MeetingPaths)
}

/// 识别任务队列：后台串行执行（处理中允许开始新的录音，新任务排队）。
public final class ProcessingQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [MeetingPaths] = []
    private var current: (MeetingPaths, CancellationFlag)?
    private var running = false
    private let worker = DispatchQueue(label: "meetingasr.processing", qos: .utility)
    private let makeProcessor: () throws -> MeetingProcessor
    private var processor: MeetingProcessor?
    private let onEvent: @Sendable (ProcessingEvent) -> Void

    /// - Parameters:
    ///   - makeProcessor: 惰性创建处理器（首次任务时加载模型）；每个任务前调用 `configure` 更新参数
    ///   - onEvent: 事件回调（在后台线程调用）
    public init(makeProcessor: @escaping () throws -> MeetingProcessor, onEvent: @escaping @Sendable (ProcessingEvent) -> Void) {
        self.makeProcessor = makeProcessor
        self.onEvent = onEvent
    }

    /// 每个任务开始前用于刷新参数（设置、热词）的回调。
    public var configure: ((inout ProcessingOptions) -> Void)?

    public func enqueue(_ meeting: MeetingPaths) {
        lock.lock()
        if pending.contains(meeting) || current?.0 == meeting {
            lock.unlock()
            return
        }
        pending.append(meeting)
        let pos = pending.count + (current == nil ? 0 : 1)
        let shouldStart = !running
        running = true
        lock.unlock()
        onEvent(.queued(meeting, position: pos))
        if shouldStart { worker.async { self.drain() } }
    }

    /// 取消某个任务（正在执行或排队中）。
    public func cancel(_ meeting: MeetingPaths) {
        lock.lock()
        if let idx = pending.firstIndex(of: meeting) {
            pending.remove(at: idx)
            lock.unlock()
            onEvent(.cancelled(meeting))
            return
        }
        let flag = current?.0 == meeting ? current?.1 : nil
        lock.unlock()
        flag?.cancel()
    }

    public func cancelCurrent() {
        lock.lock()
        let flag = current?.1
        lock.unlock()
        flag?.cancel()
    }

    public var currentMeeting: MeetingPaths? {
        lock.lock(); defer { lock.unlock() }
        return current?.0
    }

    public var queuedMeetings: [MeetingPaths] {
        lock.lock(); defer { lock.unlock() }
        return (current.map { [$0.0] } ?? []) + pending
    }

    public var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty else {
                running = false
                current = nil
                lock.unlock()
                return
            }
            let m = pending.removeFirst()
            let flag = CancellationFlag()
            current = (m, flag)
            lock.unlock()

            onEvent(.started(m))
            do {
                if processor == nil { processor = try makeProcessor() }
                guard let p = processor else { continue }
                configure?(&p.options)
                let t = try p.process(m, cancel: flag) { [onEvent] pr in onEvent(.progress(m, pr)) }
                onEvent(.finished(m, t))
            } catch is CancellationError {
                onEvent(.cancelled(m))
            } catch {
                onEvent(.failed(m, String(describing: error)))
            }
            lock.lock()
            current = nil
            lock.unlock()
        }
    }
}

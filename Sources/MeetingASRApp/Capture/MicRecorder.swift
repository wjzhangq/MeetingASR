import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import MeetingASRCore
import os

/// 使用 AVAudioEngine 采集麦克风（FR-A3）。
/// - 可选系统回声消除（Voice Processing，FR-A8）；
/// - 输入设备变化（插拔蓝牙耳机等）时自动重建采集链路，已录内容不丢失（FR-R8）。
/// - 修复：buildEngine 移出主线程，防止 HAL 插件卡死冻结 UI
final class MicRecorder {
    private let log = Logger(subsystem: "com.meetingasr.app", category: "mic")
    private let writer: AlignedTrackWriter
    private let preferredUID: String?
    private let voiceProcessing: Bool
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private let ioQueue = DispatchQueue(label: "meetingasr.mic.io", qos: .userInitiated)
    private let engineQueue = DispatchQueue(label: "meetingasr.mic.engine", qos: .userInitiated)
    private var resampler: Resampler?
    private var running = false
    private var rebuildWorkItem: DispatchWorkItem?

    /// 当前使用的输入设备名（展示用），跨线程访问需要锁保护
    private var _deviceName: String = ""
    var deviceName: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _deviceName
    }
    var onDeviceChange: ((String) -> Void)?

    /// 首次启动允许等待的时间。CoreAudio 查询硬件格式通常 <1s，
    /// 第三方 HAL 插件（虚拟声卡、聚合设备）可能更慢，超时后报错而不是无限等待。
    private static let startTimeout: TimeInterval = 8
    /// 停止时等待拆除的时间。engineQueue 卡在 CoreAudio 里时放弃等待，避免卡住调用方。
    private static let teardownTimeout: TimeInterval = 5
    /// 重建失败的最大次数
    private static let maxRebuildAttempts = 3

    /// 保护跨线程访问的字段：running / deviceName / rebuildWorkItem
    private let stateLock = NSLock()

    init(writer: AlignedTrackWriter, preferredDeviceUID: String?, voiceProcessing: Bool) {
        self.writer = writer
        self.preferredUID = preferredDeviceUID
        self.voiceProcessing = voiceProcessing
    }

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        setRunning(true)
        // buildEngine 在 engineQueue 上执行：CoreAudio 查询卡住时不会冻结调用方线程。
        // 这里仍然同步等待（有上限），保持 start() 要么成功要么抛错的语义。
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        engineQueue.async { [weak self] in
            guard let self else { done.signal(); return }
            do {
                try self.buildEngine()
                box.set(.success(()))
            } catch {
                box.set(.failure(error))
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + Self.startTimeout) == .success else {
            setRunning(false)
            log.error("mic start timed out after \(Self.startTimeout, privacy: .public)s; CoreAudio HAL may be unresponsive")
            throw CoreAudioError(kAudioHardwareNotRunningError, "麦克风启动超时，音频设备无响应")
        }
        if case .failure(let error) = box.get() {
            setRunning(false)
            throw error
        }
        // 跟随系统默认输入设备变化
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRebuild(reason: "默认输入设备变化") }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(.system, &defaultInputAddress, .main, block)
    }

    func stop() {
        setRunning(false)
        stateLock.lock()
        rebuildWorkItem?.cancel()
        rebuildWorkItem = nil
        stateLock.unlock()
        if let block = deviceListener {
            AudioObjectRemovePropertyListenerBlock(.system, &defaultInputAddress, .main, block)
        }
        deviceListener = nil
        // 拆除也放到 engineQueue，并限时等待：队列卡在 CoreAudio 时不拖住调用方。
        // 强引用 self：deinit 也走这条路径，weak self 会在那里直接变 nil 导致不拆除。
        let done = DispatchSemaphore(value: 0)
        engineQueue.async {
            self.teardownEngine()
            done.signal()
        }
        if done.wait(timeout: .now() + Self.teardownTimeout) == .timedOut {
            log.error("mic teardown timed out; engine queue stuck in CoreAudio")
        }
    }

    // MARK: - 跨线程状态

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func setRunning(_ value: Bool) {
        stateLock.lock()
        running = value
        stateLock.unlock()
    }

    private func setDeviceName(_ name: String) {
        stateLock.lock()
        _deviceName = name
        stateLock.unlock()
    }

    /// 在 engineQueue 上写、在主线程读，用锁保证可见性
    private final class ResultBox {
        private let lock = NSLock()
        private var value: Result<Void, Error>?
        func set(_ v: Result<Void, Error>) {
            lock.lock()
            if value == nil { value = v }
            lock.unlock()
        }
        func get() -> Result<Void, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    // MARK: - 采集链路（engineQueue 专属）

    /// 构建并启动 AVAudioEngine。必须在 engineQueue 上调用。
    /// 会同步查询 CoreAudio 硬件，第三方 HAL 插件可能慢（1-5 秒）或卡死。
    private func buildEngine() throws {
        dispatchPrecondition(condition: .onQueue(engineQueue))

        let engine = AVAudioEngine()
        // 这个调用可能慢：AVFAudio 会枚举设备、查询子设备、格式等，涉及多次 IPC 到 coreaudiod。
        // 第三方 HAL 插件（虚拟声卡、聚合设备）响应慢或卡住时，此调用阻塞数秒甚至无限期挂起。
        let input = engine.inputNode

        // 选择输入设备：优先用户指定的设备，不存在时回落到系统默认
        var deviceID = preferredUID.flatMap(AudioDevices.device(uid:)) ?? AudioDevices.defaultInput
        if let id = deviceID, let unit = input.audioUnit {
            var dev = id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                log.error("set input device failed: \(status)")
                deviceID = AudioDevices.defaultInput
            }
        }
        let name = deviceID.map(AudioDevices.name) ?? "默认输入"
        setDeviceName(name)

        if voiceProcessing {
            do { try input.setVoiceProcessingEnabled(true) } catch { log.error("voice processing unavailable: \(String(describing: error), privacy: .public)") }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CoreAudioError(kAudioHardwareBadDeviceError, "麦克风输入格式无效")
        }
        let rate = Int(format.sampleRate.rounded())
        let resampler = rate == writer.sampleRate ? nil : Resampler(inputRate: rate, outputRate: writer.sampleRate)
        self.resampler = resampler
        let writer = self.writer
        let ioQueue = self.ioQueue
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            let mono = Self.mono(buffer)
            guard !mono.isEmpty else { return }
            let host = when.isHostTimeValid ? HostTime.seconds(when.hostTime) : HostTime.now
            // 文件写入放到串行队列，避免阻塞音频线程
            ioQueue.async {
                let out = resampler?.process(mono) ?? mono
                writer.append(out, hostTime: host)
            }
        }
        // 配置变化时重建（只在主线程），engine 用 weak self 避免捕获循环
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.scheduleRebuild(reason: "音频配置变化")
        }
        engine.prepare()
        try engine.start()
        // start() 可能已经超时返回并抛错（HAL 卡住时），此时调用方认为麦克风没启动。
        // 这里必须检查：否则这个迟到建成的 engine 会在无人管理的情况下继续写入音轨。
        guard isRunning else {
            input.removeTap(onBus: 0)
            engine.stop()
            if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
            configObserver = nil
            resampler = nil
            log.info("discarded late-built mic engine; recorder already stopped")
            throw CoreAudioError(kAudioHardwareNotRunningError, "麦克风已停止，放弃本次构建")
        }
        self.engine = engine
        log.info("mic started: \(name, privacy: .public) @\(rate)")
    }

    /// 停止并释放 engine。必须在 engineQueue 上调用。
    private func teardownEngine() {
        dispatchPrecondition(condition: .onQueue(engineQueue))

        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        // 等待已排队的写入完成
        ioQueue.sync {}
        resampler = nil
    }

    /// 合并短时间内的多次变化通知后重建。
    /// 重建在 engineQueue 串行执行，不阻塞主线程（防止 CoreAudio HAL 慢响应冻结 UI）。
    private func scheduleRebuild(reason: String) {
        guard isRunning else { return }

        stateLock.lock()
        // 取消待执行的重建任务，新通知会重新调度
        rebuildWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.log.info("rebuild mic: \(reason, privacy: .public)")
            self.performRebuild()
        }
        rebuildWorkItem = work
        stateLock.unlock()

        // 0.5 秒后执行重建，合并短时间内的多次设备变化通知
        engineQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// 在 engineQueue 上重建 engine，带超时和重试。
    /// 调用方确保只从 engineQueue 调用，且已通过 weak self 检查。
    private func performRebuild() {
        dispatchPrecondition(condition: .onQueue(engineQueue))
        teardownEngine()
        attemptRebuild(1)
    }

    /// 重建尝试（递归调用，attempt 为当前次数）
    private func attemptRebuild(_ attempt: Int) {
        dispatchPrecondition(condition: .onQueue(engineQueue))
        guard isRunning else { return }

        // CoreAudio 查询慢时也不阻塞 UI：这个 do-catch 已经在后台队列里了
        do {
            try buildEngine()
            // 通知主线程设备名变化
            let name = deviceName  // lock 保护的读
            DispatchQueue.main.async { [weak self] in
                self?.onDeviceChange?(name)
            }
            log.info("mic rebuild succeeded (attempt \(attempt, privacy: .public))")
        } catch {
            log.error("rebuild failed (attempt \(attempt, privacy: .public)/\(Self.maxRebuildAttempts, privacy: .public)): \(String(describing: error), privacy: .public)")
            if attempt < Self.maxRebuildAttempts, isRunning {
                // 退避重试：第 1 次失败等 2 秒，第 2 次等 4 秒，第 3 次等 6 秒
                let delay = Double(attempt) * 2
                let nextAttempt = attempt + 1
                engineQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.attemptRebuild(nextAttempt)
                }
            } else {
                log.error("mic rebuild exhausted; mic capture unavailable")
            }
        }
    }

    private static func mono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        let ch = Int(buffer.format.channelCount)
        guard frames > 0, ch > 0 else { return [] }
        if let data = buffer.floatChannelData {
            var out = [Float](repeating: 0, count: frames)
            let inv = 1 / Float(ch)
            if buffer.format.isInterleaved {
                let p = data[0]
                for i in 0..<frames { for c in 0..<ch { out[i] += p[i * ch + c] * inv } }
            } else {
                for c in 0..<ch {
                    let p = data[c]
                    for i in 0..<frames { out[i] += p[i] * inv }
                }
            }
            return out
        }
        return PCMConvert.monoFloat(buffer.audioBufferList, format: buffer.format.streamDescription.pointee, frames: frames)
    }

    deinit {
        stop()
    }
}

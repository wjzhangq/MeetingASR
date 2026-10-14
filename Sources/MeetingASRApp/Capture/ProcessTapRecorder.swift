import AudioToolbox
import CoreAudio
import Foundation
import MeetingASRCore
import os

/// 使用 Core Audio Process Tap 采集会议软件输出音频（FR-A1/A2）。
/// 同一软件的多个音频子进程纳入同一个 Tap；进程重启或新增子进程时自动重新挂载（FR-A6）。
final class ProcessTapRecorder {
    private let log = Logger(subsystem: "com.meetingasr.app", category: "tap")
    private let apps: [CaptureApp]
    private let writer: AlignedTrackWriter
    private let queue = DispatchQueue(label: "meetingasr.tap.io", qos: .userInitiated)
    private var observer: AudioProcessListObserver?
    private var pollTimer: DispatchSourceTimer?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapFormat = AudioStreamBasicDescription()
    private var resampler: Resampler?
    private var currentProcesses: Set<AudioObjectID> = []
    private var running = false

    /// 当前被采集的进程 Bundle ID（展示用）
    private(set) var capturedBundleIDs: [String] = []
    /// 挂载状态变化回调（主线程）
    var onStatusChange: ((_ attached: Bool, _ bundleIDs: [String]) -> Void)?

    init(apps: [CaptureApp], writer: AlignedTrackWriter) {
        self.apps = apps
        self.writer = writer
    }

    /// 开始采集。目标进程不在运行时也可开始，等进程出现后自动挂载。
    func start() throws {
        try queue.sync {
            running = true
            try refreshLocked(force: true)
        }
        observer = AudioProcessListObserver(queue: queue) { [weak self] in
            try? self?.refreshLocked(force: false)
        }
        // 兜底轮询，防止遗漏通知
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: 3)
        t.setEventHandler { [weak self] in try? self?.refreshLocked(force: false) }
        t.resume()
        pollTimer = t
    }

    func stop() {
        observer?.invalidate()
        observer = nil
        pollTimer?.cancel()
        pollTimer = nil
        queue.sync {
            running = false
            teardownLocked()
        }
    }

    var isAttached: Bool { queue.sync { aggregateID != kAudioObjectUnknown } }

    // MARK: - 挂载

    /// 在 queue 上调用。
    private func refreshLocked(force: Bool) throws {
        guard running else { return }
        let procs = AudioProcessList.matching(apps)
        let ids = Set(procs.map(\.objectID))
        guard force || ids != currentProcesses else { return }
        teardownLocked()
        currentProcesses = ids
        capturedBundleIDs = Array(Set(procs.map(\.bundleID))).sorted()
        guard !ids.isEmpty else {
            notify(attached: false)
            return
        }
        do {
            try setupLocked(processes: Array(ids))
            log.info("tap attached: \(self.capturedBundleIDs.joined(separator: ","), privacy: .public)")
            notify(attached: true)
        } catch {
            log.error("tap setup failed: \(String(describing: error), privacy: .public)")
            teardownLocked()
            currentProcesses = []
            notify(attached: false)
            if force { throw error }
        }
    }

    private func notify(attached: Bool) {
        let ids = capturedBundleIDs
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?(attached, ids) }
    }

    private func setupLocked(processes: [AudioObjectID]) throws {
        // 等价于 initStereoMixdownOfProcesses:。通过 ObjC 属性名（KVC）设置，
        // 不依赖各 SDK 版本 Swift 导入名的差异（processes 为 NSArray<NSNumber *>）。
        let desc = CATapDescription()
        let tapUUID = UUID()
        desc.setValue(processes.map { NSNumber(value: $0) }, forKey: "processes")
        desc.setValue(true, forKey: "mixdown")
        desc.setValue(false, forKey: "mono")
        desc.setValue(false, forKey: "exclusive")
        desc.setValue(true, forKey: "privateTap")
        desc.setValue(0, forKey: "muteBehavior") // CATapUnmuted：不影响用户正常收听
        desc.setValue(tapUUID, forKey: "UUID")
        desc.setValue("MeetingASR Tap", forKey: "name")
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(desc, &tap), "创建 Process Tap")
        tapID = tap

        tapFormat = try tap.read(kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())

        guard let output = AudioDevices.defaultSystemOutput,
              let outputUID = output.readString(kAudioDevicePropertyDeviceUID) else {
            throw CoreAudioError(kAudioHardwareBadDeviceError, "获取默认输出设备")
        }
        let aggUID = "MeetingASR-\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MeetingASR Aggregate",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUUID.uuidString,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg), "创建聚合设备")
        aggregateID = agg

        let rate = Int(tapFormat.mSampleRate.rounded())
        resampler = rate == writer.sampleRate ? nil : Resampler(inputRate: rate, outputRate: writer.sampleRate)
        let format = tapFormat
        let writer = self.writer
        var pid: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&pid, agg, queue) { [weak self] _, inInputData, inInputTime, _, _ in
            guard let self else { return }
            var samples = PCMConvert.monoFloat(inInputData, format: format)
            guard !samples.isEmpty else { return }
            let ts = inInputTime.pointee
            let host = ts.mFlags.contains(.hostTimeValid) ? HostTime.seconds(ts.mHostTime) : HostTime.now
            if let r = self.resampler { samples = r.process(samples) }
            writer.append(samples, hostTime: host)
        }, "创建 IOProc")
        procID = pid
        try check(AudioDeviceStart(agg, pid), "启动聚合设备")
    }

    private func teardownLocked() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        resampler = nil
    }

    deinit {
        stop()
    }
}

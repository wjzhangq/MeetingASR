import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import MeetingASRCore
import os

/// 使用 AVAudioEngine 采集麦克风（FR-A3）。
/// - 可选系统回声消除（Voice Processing，FR-A8）；
/// - 输入设备变化（插拔蓝牙耳机等）时自动重建采集链路，已录内容不丢失（FR-R8）。
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
    private var resampler: Resampler?
    private var running = false
    private var rebuildPending = false

    /// 当前使用的输入设备名（展示用）
    private(set) var deviceName: String = ""
    var onDeviceChange: ((String) -> Void)?

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
        running = true
        try buildEngine()
        // 跟随系统默认输入设备变化
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRebuild(reason: "默认输入设备变化") }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(.system, &defaultInputAddress, .main, block)
    }

    func stop() {
        running = false
        if let block = deviceListener {
            AudioObjectRemovePropertyListenerBlock(.system, &defaultInputAddress, .main, block)
        }
        deviceListener = nil
        teardownEngine()
    }

    // MARK: - 采集链路

    private func buildEngine() throws {
        let engine = AVAudioEngine()
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
        deviceName = deviceID.map(AudioDevices.name) ?? "默认输入"

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
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.scheduleRebuild(reason: "音频配置变化")
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        log.info("mic started: \(self.deviceName, privacy: .public) @\(rate)")
    }

    private func teardownEngine() {
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
    private func scheduleRebuild(reason: String) {
        guard running, !rebuildPending else { return }
        rebuildPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.rebuildPending = false
            guard self.running else { return }
            self.log.info("rebuild mic: \(reason, privacy: .public)")
            self.teardownEngine()
            var attempt = 0
            func tryBuild() {
                do {
                    try self.buildEngine()
                    self.onDeviceChange?(self.deviceName)
                } catch {
                    attempt += 1
                    self.log.error("rebuild failed: \(String(describing: error), privacy: .public)")
                    if attempt < 5, self.running {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tryBuild() }
                    }
                }
            }
            tryBuild()
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

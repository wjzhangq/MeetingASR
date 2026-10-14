import AudioToolbox
import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let context: String

    init(_ status: OSStatus, _ context: String) {
        self.status = status
        self.context = context
    }

    var description: String { "\(context) 失败（OSStatus \(status)）" }
}

@inline(__always)
func check(_ status: OSStatus, _ context: String) throws {
    guard status == noErr else { throw CoreAudioError(status, context) }
}

/// mach 主机时间 ↔ 秒。
enum HostTime {
    private static let factor: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) / 1e9
    }()

    static func seconds(_ host: UInt64) -> Double { Double(host) * factor }
    static var now: Double { seconds(mach_absolute_time()) }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    private func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func hasProperty(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var addr = address(selector, scope)
        return AudioObjectHasProperty(self, &addr)
    }

    func read<T>(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) throws -> T {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &value), "读取属性 \(selector)")
        return value
    }

    func readArray<T>(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) throws -> [T] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size), "读取属性大小 \(selector)")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var values = [T](repeating: initial, count: count)
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &values), "读取属性 \(selector)")
        return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    func readString(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var ref: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &ref) == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }
}

/// 音频设备信息（麦克风输入设备选择，FR-C1）。
struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDevices {
    static func all() -> [AudioDeviceID] {
        (try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, initial: AudioDeviceID(0))) ?? []
    }

    static func hasInput(_ id: AudioDeviceID) -> Bool {
        let streams = (try? id.readArray(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, initial: AudioStreamID(0))) ?? []
        return !streams.isEmpty
    }

    static func inputDevices() -> [AudioDeviceInfo] {
        all().filter(hasInput).compactMap { id in
            guard let uid = id.readString(kAudioDevicePropertyDeviceUID) else { return nil }
            let name = id.readString(kAudioObjectPropertyName) ?? uid
            // 排除本应用创建的私有聚合设备
            if uid.hasPrefix("MeetingASR-") { return nil }
            return AudioDeviceInfo(id: id, uid: uid, name: name)
        }
    }

    static func device(uid: String) -> AudioDeviceID? {
        all().first { $0.readString(kAudioDevicePropertyDeviceUID) == uid }
    }

    static var defaultInput: AudioDeviceID? {
        let id = (try? AudioObjectID.system.read(kAudioHardwarePropertyDefaultInputDevice, initial: AudioDeviceID(0))) ?? 0
        return id == 0 ? nil : id
    }

    static var defaultSystemOutput: AudioDeviceID? {
        let id = (try? AudioObjectID.system.read(kAudioHardwarePropertyDefaultSystemOutputDevice, initial: AudioDeviceID(0))) ?? 0
        return id == 0 ? nil : id
    }

    static func name(_ id: AudioDeviceID) -> String {
        id.readString(kAudioObjectPropertyName) ?? "未知设备"
    }

    /// 输出设备是否为内置扬声器（外放时提示使用耳机，4.3 对策 3）。
    static func isBuiltInSpeaker(_ id: AudioDeviceID) -> Bool {
        let transport = (try? id.read(kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0
        guard transport == kAudioDeviceTransportTypeBuiltIn else { return false }
        let source = (try? id.read(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput, initial: UInt32(0))) ?? 0
        // 'ispk' = 内置扬声器，'hdpn' = 耳机插孔
        return source != 0x6864706E
    }
}

/// 把 AudioBufferList 中的 Float32 PCM 混为单声道。
enum PCMConvert {
    static func monoFloat(_ abl: UnsafePointer<AudioBufferList>, format: AudioStreamBasicDescription, frames: Int? = nil) -> [Float] {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bytesPerSample = Int(format.mBitsPerChannel / 8)
        guard bytesPerSample > 0, list.count > 0 else { return [] }

        if nonInterleaved {
            let n = frames ?? Int(list[0].mDataByteSize) / bytesPerSample
            var out = [Float](repeating: 0, count: n)
            let inv = 1 / Float(list.count)
            for buf in list {
                guard let data = buf.mData else { continue }
                accumulate(data, count: min(n, Int(buf.mDataByteSize) / bytesPerSample), stride: 1, offset: 0, isFloat: isFloat, bytes: bytesPerSample, scale: inv, into: &out)
            }
            return out
        }
        let buf = list[0]
        let ch = max(1, Int(buf.mNumberChannels))
        let n = frames ?? Int(buf.mDataByteSize) / (bytesPerSample * ch)
        guard let data = buf.mData, n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        let inv = 1 / Float(ch)
        for c in 0..<ch {
            accumulate(data, count: n, stride: ch, offset: c, isFloat: isFloat, bytes: bytesPerSample, scale: inv, into: &out)
        }
        return out
    }

    private static func accumulate(_ data: UnsafeMutableRawPointer, count: Int, stride: Int, offset: Int, isFloat: Bool, bytes: Int, scale: Float, into out: inout [Float]) {
        if isFloat && bytes == 4 {
            let p = data.assumingMemoryBound(to: Float.self)
            for i in 0..<count { out[i] += p[i * stride + offset] * scale }
        } else if !isFloat && bytes == 2 {
            let p = data.assumingMemoryBound(to: Int16.self)
            for i in 0..<count { out[i] += Float(p[i * stride + offset]) / 32768 * scale }
        } else if !isFloat && bytes == 4 {
            let p = data.assumingMemoryBound(to: Int32.self)
            for i in 0..<count { out[i] += Float(p[i * stride + offset]) / 2_147_483_648 * scale }
        }
    }
}

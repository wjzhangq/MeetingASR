import AppKit
import CoreAudio
import Foundation
import MeetingASRCore

/// 一个可被 Tap 的音频进程。
struct AudioProcess: Hashable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningOutput: Bool
}

/// 通过 kAudioHardwarePropertyProcessObjectList 枚举音频进程，按 Bundle ID 匹配会议软件（3.1）。
enum AudioProcessList {
    static func all() -> [AudioProcess] {
        let ids = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList, initial: AudioObjectID(0))) ?? []
        return ids.compactMap { id in
            let pid = (try? id.read(kAudioProcessPropertyPID, initial: pid_t(-1))) ?? -1
            var bundle = id.readString(kAudioProcessPropertyBundleID) ?? ""
            if bundle.isEmpty, pid > 0 {
                bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            }
            guard !bundle.isEmpty else { return nil }
            let running = ((try? id.read(kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0) != 0
            return AudioProcess(objectID: id, pid: pid, bundleID: bundle, isRunningOutput: running)
        }
    }

    /// 属于已启用会议软件的全部音频进程（含子进程）。
    static func matching(_ apps: [CaptureApp]) -> [AudioProcess] {
        let enabled = apps.filter(\.enabled)
        return all().filter { p in enabled.contains { $0.matches(bundleID: p.bundleID) } }
    }

    /// 正在运行的会议软件名称（检测用，FR-A5）。也检查 NSWorkspace，因为未发声的应用可能还不在音频进程列表里。
    static func runningApps(_ apps: [CaptureApp]) -> [String] {
        let enabled = apps.filter(\.enabled)
        let audio = matching(apps).map(\.bundleID)
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        return enabled.filter { app in (audio + running).contains { app.matches(bundleID: $0) } }.map(\.name)
    }
}

/// 监听音频进程列表变化（会议软件重启、新增子进程，FR-A6）。
final class AudioProcessListObserver {
    private var block: AudioObjectPropertyListenerBlock?
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private let queue: DispatchQueue

    init(queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.queue = queue
        let b: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        block = b
        AudioObjectAddPropertyListenerBlock(.system, &address, queue, b)
    }

    func invalidate() {
        if let block {
            AudioObjectRemovePropertyListenerBlock(.system, &address, queue, block)
        }
        block = nil
    }

    deinit { invalidate() }
}

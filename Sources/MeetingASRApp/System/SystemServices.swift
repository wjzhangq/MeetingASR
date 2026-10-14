import AppKit
import Carbon.HIToolbox
import Foundation
import IOKit.pwr_mgt
import MeetingASRCore
import ServiceManagement
import UserNotifications

// MARK: - 睡眠（FR-R7）

/// 录音期间阻止系统空闲睡眠；系统强制睡眠时回调暂停，唤醒后回调提示。
@MainActor
final class SleepGuard {
    private var assertionID: IOPMAssertionID = 0
    private var observers: [NSObjectProtocol] = []
    var onWillSleep: (() -> Void)?
    var onDidWake: (() -> Void)?

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onWillSleep?() }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onDidWake?() }
        })
    }

    func preventIdleSleep(_ on: Bool) {
        if on, assertionID == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "MeetingASR 正在录音" as CFString, &assertionID)
        } else if !on, assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }
}

// MARK: - 全局快捷键（FR-R6）

/// 基于 Carbon RegisterEventHotKey 的全局快捷键，不需要辅助功能权限。
final class HotkeyManager {
    static let shared = HotkeyManager()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    func register(id: UInt32, _ setting: HotkeySetting?, handler: @escaping () -> Void) {
        unregister(id: id)
        guard let setting else { return }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x4D415352), id: id) // 'MASR'
        let status = RegisterEventHotKey(setting.keyCode, setting.modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[id] = ref
            handlers[id] = handler
        }
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers.removeValue(forKey: id)
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotkeyManager.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// 快捷键显示文本，如 ⌥⌘R
    static func describe(_ s: HotkeySetting?) -> String {
        guard let s else { return "未设置" }
        var t = ""
        if s.modifiers & UInt32(controlKey) != 0 { t += "⌃" }
        if s.modifiers & UInt32(optionKey) != 0 { t += "⌥" }
        if s.modifiers & UInt32(shiftKey) != 0 { t += "⇧" }
        if s.modifiers & UInt32(cmdKey) != 0 { t += "⌘" }
        return t + (keyName(s.keyCode) ?? "#\(s.keyCode)")
    }

    static func keyName(_ code: UInt32) -> String? {
        let map: [UInt32: String] = [
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
            45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
            29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
            49: "Space", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        ]
        return map[code]
    }

    /// NSEvent 修饰键 → Carbon 修饰键
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
}

// MARK: - 系统通知（FR-P3）

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    /// 点击通知时打开的会议目录名
    var onOpenMeeting: ((String) -> Void)?

    func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String, meeting: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let meeting { content.userInfo = ["meeting": meeting] }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let name = response.notification.request.content.userInfo["meeting"] as? String
        Task { @MainActor in
            if let name { self.onOpenMeeting?(name) }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - 开机自启动（FR-C5）

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

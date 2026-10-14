import AppKit
import MeetingASRCore
import SwiftUI

/// MeetingASR：菜单栏常驻（LSUIElement），仅 Apple Silicon。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController!
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let state = AppState.shared
        statusBar = StatusBarController(state: state)
        Notifier.shared.setup()
        Notifier.shared.onOpenMeeting = { [weak self] name in self?.statusBar.showPreview(name) }
        state.registerHotkeys()

        if !state.settings.onboardingDone {
            showOnboarding()
        } else {
            promptUnfinished()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 正在录音时退出：先正常停止，保证文件完整，下次启动继续识别
        if AppState.shared.recorderState != .idle {
            AppState.shared.stop()
        }
        return .terminateNow
    }

    private func showOnboarding() {
        let view = OnboardingView { [weak self] in
            AppState.shared.settings.onboardingDone = true
            AppState.shared.saveSettings()
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
            self?.statusBar.showPopover()
        }
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "欢迎使用 MeetingASR"
        w.contentViewController = NSHostingController(rootView: view)
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        onboardingWindow = w
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 异常退出后检测未识别的录音，提示继续识别（FR-R9）。
    private func promptUnfinished() {
        let state = AppState.shared
        let list = state.checkUnfinished()
        guard !list.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "发现 \(list.count) 个未识别的录音"
        alert.informativeText = list.prefix(5).map { "· \($0.title)（\(TranscriptWriter.clock($0.durationSec))）" }.joined(separator: "\n")
            + "\n\n可能由于上次异常退出或识别失败。是否现在继续识别？"
        alert.addButton(withTitle: "继续识别")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            for m in list { state.retry(m.paths.name) }
            _ = state.checkUnfinished()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

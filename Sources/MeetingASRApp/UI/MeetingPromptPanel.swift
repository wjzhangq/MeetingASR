import AppKit
import SwiftUI

/// 提示无操作时自动关闭的秒数
let meetingPromptTimeout: TimeInterval = 5

/// 检测到会议时的“是否开始录音”提示：屏幕右上角的浮动小窗，不激活本应用（不打断会议软件），
/// 回车或全局快捷键（开始/停止，默认 ⌥⌘R）确认，Esc 关闭；无操作时倒计时结束自动关闭（本次不录）。
@MainActor
final class MeetingPromptPanel {
    enum Result {
        case start
        case skip
        case timeout
    }

    private var panel: NSPanel?
    private var timer: Timer?
    private var completion: ((Result) -> Void)?
    private let model = MeetingPromptModel()

    var isShown: Bool { panel != nil }

    func show(title: String, detail: String, hotkey: String?, completion: @escaping (Result) -> Void) {
        close(nil)
        self.completion = completion
        model.title = title
        model.detail = detail
        model.hotkey = hotkey
        model.remaining = meetingPromptTimeout

        let view = MeetingPromptView(model: model, onStart: { [weak self] in self?.close(.start) },
                                     onSkip: { [weak self] in self?.close(.skip) })
        let host = NSHostingView(rootView: view)
        let p = KeyablePanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                             styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = host
        p.setContentSize(host.fittingSize)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - p.frame.width - 16, y: f.maxY - p.frame.height - 16))
        }
        // 成为 key 窗口以响应回车 / Esc，但不激活应用（会议软件保持前台）
        p.makeKeyAndOrderFront(nil)
        panel = p

        let start = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.remaining = max(0, meetingPromptTimeout - Date().timeIntervalSince(start))
                if self.model.remaining <= 0 { self.close(.timeout) }
            }
        }
    }

    /// 全局快捷键确认
    func confirm() { close(.start) }

    /// 会议已结束等情况下直接关闭
    func dismiss() { close(.skip) }

    private func close(_ result: Result?) {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        let c = completion
        completion = nil
        if let result { c?(result) }
    }
}

/// 无标题栏样式下仍可成为 key 窗口，以接收回车 / Esc。
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class MeetingPromptModel: ObservableObject {
    @Published var title = ""
    @Published var detail = ""
    @Published var hotkey: String?
    @Published var remaining: TimeInterval = meetingPromptTimeout
}

private struct MeetingPromptView: View {
    @ObservedObject var model: MeetingPromptModel
    let onStart: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "record.circle").foregroundStyle(.red).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title).font(.headline)
                    Text(model.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ProgressView(value: model.remaining, total: meetingPromptTimeout)
                .progressViewStyle(.linear)
            HStack {
                Text("\(Int(model.remaining.rounded(.up))) 秒后自动关闭").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("本次不录", action: onSkip)
                    .keyboardShortcut(.cancelAction)
                Button(model.hotkey.map { "开始录音（\($0)）" } ?? "开始录音", action: onStart)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

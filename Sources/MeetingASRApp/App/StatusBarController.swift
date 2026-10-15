import AppKit
import Combine
import MeetingASRCore
import SwiftUI
import UniformTypeIdentifiers

/// 菜单栏图标与弹层（FR-R1、3.4）。
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let state: AppState
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let router = PanelRouter()
    private var cancellables: Set<AnyCancellable> = []
    private var windows: [String: NSWindow] = [:]
    private var settingsWindow: NSWindow?
    private var auxWindow: NSWindow?

    init(state: AppState) {
        self.state = state
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let actions = PanelActions(
            start: { [weak self] req in self?.start(req) },
            recognizeFile: { [weak self] in self?.chooseFile() },
            openWindow: { [weak self] name in self?.openPreviewWindow(name) },
            openSettings: { [weak self] in self?.openSettings() },
            quit: { [weak self] in self?.quit() }
        )
        let root = MenuPanelView(state: state, router: router, actions: actions)
        popover.contentViewController = NSHostingController(rootView: root)

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
            // 拖拽音频文件到菜单栏图标直接识别（FR-F5）
            let drop = DropView(frame: button.bounds) { [weak self] url in self?.confirmFile(url) }
            drop.autoresizingMask = [.width, .height]
            button.addSubview(drop)
        }
        state.onMeetingDeleted = { [weak self] name in
            self?.router.forget(name)
            self?.windows[name]?.close()
        }
        state.onMeetingRenamed = { [weak self] name, title in
            self?.windows[name]?.title = title
        }
        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateButton() } }
            .store(in: &cancellables)
        updateButton()
    }

    // MARK: - 图标

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let symbol: String
        var tint: NSColor?
        var title = ""
        switch state.phase {
        case .recording:
            symbol = "record.circle.fill"
            tint = .systemRed
            title = " " + TranscriptWriter.clock(state.elapsed)
        case .paused:
            symbol = "pause.circle.fill"
            tint = .systemOrange
            title = " " + TranscriptWriter.clock(state.elapsed)
        case .processing:
            symbol = "waveform.badge.magnifyingglass"
            if let p = state.currentProcessing { title = " \(p.progress.percent)%" }
        case .idle:
            symbol = "waveform"
        }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "MeetingASR")
        img?.isTemplate = tint == nil
        button.image = img
        button.contentTintColor = tint
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium),
            .foregroundColor: tint ?? NSColor.labelColor,
        ])
    }

    // MARK: - 弹层

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover(route: PanelRouter.Route? = nil) {
        if let route { router.route = route }
        guard let button = statusItem.button else { return }
        state.refreshRecent()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        if case .startForm = router.route { router.route = .menu }
    }

    /// 打开某次会议的结果预览（通知点击、FR-V1）。
    func showPreview(_ name: String) {
        showPopover(route: .preview(name))
    }

    // MARK: - 录音

    private func start(_ req: AppState.StartRequest) {
        popover.performClose(nil)
        switch state.preflight() {
        case .ok:
            state.startRecording(req)
        case .micPermissionDenied:
            let a = NSAlert()
            a.messageText = "无法访问麦克风"
            a.informativeText = "请在 系统设置 › 隐私与安全性 › 麦克风 中允许 MeetingASR。"
            a.addButton(withTitle: "打开系统设置")
            a.addButton(withTitle: "取消")
            if a.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        case .appNotRunning:
            // FR-A5：会议软件未运行时提示，并允许仅录麦克风
            let names = state.settings.captureApps.filter(\.enabled).map(\.name).joined(separator: "、")
            let a = NSAlert()
            a.messageText = "未检测到会议软件"
            a.informativeText = "\(names) 当前未在运行。可以仅录制麦克风，或继续等待会议软件启动后自动开始采集。"
            if state.settings.captureSource.includesMic { a.addButton(withTitle: "仅录麦克风") }
            a.addButton(withTitle: "开始并等待会议软件")
            a.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            let r = a.runModal()
            var req = req
            if state.settings.captureSource.includesMic {
                if r == .alertFirstButtonReturn {
                    req.micOnlyConfirmed = true
                    state.startRecording(req)
                } else if r == .alertSecondButtonReturn {
                    state.startRecording(req)
                }
            } else if r == .alertFirstButtonReturn {
                state.startRecording(req)
            }
        }
    }

    // MARK: - 文件识别

    private func chooseFile() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "选择要识别的音频文件"
        panel.allowedContentTypes = AudioFileOpener.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        confirmFile(url)
    }

    private func confirmFile(_ url: URL) {
        guard AudioFileOpener.supportedExtensions.contains(url.pathExtension.lowercased()) else {
            state.lastError = "不支持的文件格式：\(url.lastPathComponent)"
            return
        }
        let duration: Double
        do {
            let src = try AudioFileOpener.open(url)
            duration = Double(src.frameCount) / Double(src.sampleRate)
        } catch {
            state.lastError = "无法打开音频：\(error)"
            return
        }
        let view = FileRecognizeView(url: url, duration: duration, onStart: { [weak self] range, speakers in
            self?.auxWindow?.close()
            self?.state.recognizeFile(url, range: range, speakers: speakers)
            self?.showPopover(route: .menu)
        }, onCancel: { [weak self] in self?.auxWindow?.close() })
        showAux(view, title: "识别音频文件")
    }

    // MARK: - 窗口

    func openPreviewWindow(_ name: String) {
        popover.performClose(nil)
        if let w = windows[name] {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = router.previewModel(name)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = model.title
        w.contentViewController = NSHostingController(rootView: PreviewView(model: model).frame(minWidth: 520, minHeight: 400))
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        windows[name] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windows[name] = nil }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "MeetingASR 设置"
            w.contentViewController = NSHostingController(rootView: SettingsView(state: state))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showAux<V: View>(_ view: V, title: String) {
        auxWindow?.close()
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = title
        w.contentViewController = NSHostingController(rootView: view)
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        auxWindow = w
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeAux() {
        auxWindow?.close()
    }

    private func quit() {
        if state.recorderState != .idle {
            let a = NSAlert()
            a.messageText = "正在录音"
            a.informativeText = "退出前要停止录音吗？停止后的录音将在下次启动时继续识别。"
            a.addButton(withTitle: "停止并退出")
            a.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return }
            state.stop()
        }
        NSApp.terminate(nil)
    }
}

/// 覆盖在菜单栏按钮上的透明拖放区域；鼠标点击转发给按钮。
private final class DropView: NSView {
    private let onDrop: (URL) -> Void

    init(frame: NSRect, onDrop: @escaping (URL) -> Void) {
        self.onDrop = onDrop
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        (superview as? NSButton)?.performClick(nil)
    }

    private func audioURL(_ info: NSDraggingInfo) -> URL? {
        guard let url = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first,
              AudioFileOpener.supportedExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        audioURL(sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = audioURL(sender) else { return false }
        DispatchQueue.main.async { self.onDrop(url) }
        return true
    }
}

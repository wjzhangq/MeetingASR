import AppKit
import MeetingASRCore
import SwiftUI

/// 菜单栏弹层内的导航。
@MainActor
final class PanelRouter: ObservableObject {
    enum Route: Equatable {
        case menu
        case startForm
        case preview(String)
    }

    @Published var route: Route = .menu
    private var models: [String: PreviewModel] = [:]

    func previewModel(_ name: String) -> PreviewModel {
        if let m = models[name] {
            m.reload()
            return m
        }
        let m = PreviewModel(meeting: AppState.shared.layout.meeting(named: name), state: AppState.shared)
        models[name] = m
        return m
    }
}

/// 菜单栏主面板（3.2 录音控制、3.4 入口、3.7 文件识别）。
struct MenuPanelView: View {
    @ObservedObject var state: AppState
    @ObservedObject var router: PanelRouter
    var actions: PanelActions

    var body: some View {
        Group {
            switch router.route {
            case .menu:
                menu
            case .startForm:
                StartRecordingForm(state: state, onCancel: { router.route = .menu }, onStart: { req in
                    router.route = .menu
                    actions.start(req)
                })
            case .preview(let name):
                PreviewView(model: router.previewModel(name), onBack: { router.route = .menu }, onOpenWindow: { actions.openWindow(name) })
                    .frame(width: 560, height: 600)
            }
        }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeader
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                controls
                Divider().padding(.vertical, 4)
                MenuRow(title: "查看最近结果", icon: "doc.text.magnifyingglass", enabled: state.latestCompleted != nil) {
                    if let m = state.latestCompleted { router.route = .preview(m.paths.name) }
                }
                MenuRow(title: "识别音频文件…", icon: "waveform.badge.plus") { actions.recognizeFile() }
                Divider().padding(.vertical, 4)
                recentList
                Divider().padding(.vertical, 4)
                MenuRow(title: "设置…", icon: "gearshape", shortcut: "⌘,") { actions.openSettings() }
                MenuRow(title: "退出 MeetingASR", icon: "power", shortcut: "⌘Q") { actions.quit() }
            }
            .padding(6)
        }
        .frame(width: 320)
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                switch state.phase {
                case .recording:
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    Text("录音中").bold()
                    Spacer()
                    Text(TranscriptWriter.clock(state.elapsed)).font(.body.monospacedDigit())
                case .paused:
                    Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                    Text("已暂停").bold()
                    Spacer()
                    Text(TranscriptWriter.clock(state.elapsed)).font(.body.monospacedDigit()).foregroundStyle(.secondary)
                case .processing:
                    Image(systemName: "gearshape.2.fill").foregroundStyle(.blue)
                    Text("处理中").bold()
                    Spacer()
                case .idle:
                    Image(systemName: "waveform").foregroundStyle(.secondary)
                    Text("空闲").bold()
                    Spacer()
                }
            }
            if let p = state.currentProcessing {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(p.progress.stage.displayName) \(p.progress.percent)%").font(.caption)
                        Spacer()
                        Button("取消") { state.cancelProcessing(p.name) }.controlSize(.small).buttonStyle(.borderless)
                    }
                    ProgressView(value: p.progress.fraction).progressViewStyle(.linear)
                    Text(meetingTitle(p.name)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if !state.queued.isEmpty {
                Text("排队中：\(state.queued.count) 个").font(.caption2).foregroundStyle(.secondary)
            }
            if state.recorderState != .idle {
                if let tap = state.tapStatus { Text(tap).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                if let mic = state.micDevice { Text("麦克风：\(mic)").font(.caption2).foregroundStyle(.secondary) }
            }
            if let err = state.lastError {
                HStack(alignment: .top) {
                    Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { state.lastError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
            }
            if !state.unfinished.isEmpty {
                HStack {
                    Text("有 \(state.unfinished.count) 个未识别的录音").font(.caption)
                    Spacer()
                    Button("继续识别") {
                        for m in state.unfinished { state.retry(m.paths.name) }
                        _ = state.checkUnfinished()
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var controls: some View {
        switch state.recorderState {
        case .idle:
            MenuRow(title: "开始录音", icon: "record.circle", shortcut: HotkeyManager.describe(state.settings.hotkeyStartStop)) {
                router.route = .startForm
            }
        case .recording:
            MenuRow(title: "暂停", icon: "pause.circle", shortcut: HotkeyManager.describe(state.settings.hotkeyPauseResume)) { state.pause() }
            MenuRow(title: "停止", icon: "stop.circle", shortcut: HotkeyManager.describe(state.settings.hotkeyStartStop)) { state.stop() }
        case .paused:
            MenuRow(title: "继续", icon: "play.circle", shortcut: HotkeyManager.describe(state.settings.hotkeyPauseResume)) { state.resume() }
            MenuRow(title: "停止", icon: "stop.circle", shortcut: HotkeyManager.describe(state.settings.hotkeyStartStop)) { state.stop() }
        }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("最近会议").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 2)
            if state.recent.isEmpty {
                Text("暂无").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
            ForEach(state.recent) { m in
                Button {
                    router.route = .preview(m.paths.name)
                } label: {
                    HStack(spacing: 6) {
                        statusIcon(m)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(m.title).lineLimit(1)
                            Text(dateText(m.createdAt) + " · " + TranscriptWriter.clock(m.durationSec))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                }
                .buttonStyle(HoverButtonStyle())
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ m: MeetingSummary) -> some View {
        if state.processing[m.paths.name] != nil {
            ProgressView().controlSize(.mini)
        } else {
            switch m.status {
            case .done: Image(systemName: "checkmark.circle").foregroundStyle(.green)
            case .recording: Image(systemName: "record.circle").foregroundStyle(.red)
            case .pending, .processing: Image(systemName: "hourglass").foregroundStyle(.secondary)
            case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
            }
        }
    }

    private func meetingTitle(_ name: String) -> String {
        state.recent.first { $0.paths.name == name }?.title ?? name
    }

    private func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "今天 HH:mm" : "MM-dd HH:mm"
        return f.string(from: d)
    }
}

/// 面板中触发的、需要 AppKit 处理的动作。
struct PanelActions {
    var start: (AppState.StartRequest) -> Void
    var recognizeFile: () -> Void
    var openWindow: (String) -> Void
    var openSettings: () -> Void
    var quit: () -> Void
}

struct MenuRow: View {
    let title: String
    let icon: String
    var shortcut: String? = nil
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 18)
                Text(title)
                Spacer()
                if let shortcut, shortcut != "未设置" {
                    Text(shortcut).font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
        }
        .buttonStyle(HoverButtonStyle())
        .disabled(!enabled)
    }
}

struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 5).fill(hover && enabled ? Color.accentColor.opacity(0.2) : .clear))
                .onHover { hover = $0 }
        }
    }
}

/// 开始录音前填写会议标题和预计说话人数（FR-R5，可跳过）。
struct StartRecordingForm: View {
    @ObservedObject var state: AppState
    var onCancel: () -> Void
    var onStart: (AppState.StartRequest) -> Void
    @State private var title = ""
    @State private var autoCount = true
    @State private var count = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("开始录音").font(.headline)
            TextField("会议标题（可选）", text: $title).textFieldStyle(.roundedBorder).onSubmit(start)
            HStack {
                Toggle("说话人数自动", isOn: $autoCount)
                Spacer()
                Stepper("\(count) 人", value: $count, in: 1...20).disabled(autoCount)
            }
            Text("采集源：\(state.settings.captureSource.displayName)").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("跳过并开始") { onStart(AppState.StartRequest()) }
                Spacer()
                Button("取消", action: onCancel)
                Button("开始", action: start).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear {
            if let n = state.settings.recognition.defaultSpeakerCount {
                autoCount = false
                count = n
            }
        }
    }

    private func start() {
        onStart(AppState.StartRequest(title: title, expectedSpeakers: autoCount ? nil : count))
    }
}

import AppKit
import MeetingASRCore
import SwiftUI

enum Palette {
    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo, .mint, .red, .cyan, .yellow]
    static func color(_ i: Int) -> Color { colors[i % colors.count] }

    /// "#RRGGBB" → Color
    static func color(hex: String?) -> Color? {
        guard let hex, let (r, g, b) = PersonColor.components(hex) else { return nil }
        return Color(.sRGB, red: r, green: g, blue: b)
    }

    /// Color → "#RRGGBB"
    static func hex(_ c: Color) -> String? {
        guard let n = NSColor(c).usingColorSpace(.sRGB) else { return nil }
        return PersonColor.hex(r: Double(n.redComponent), g: Double(n.greenComponent), b: Double(n.blueComponent))
    }
}

/// 结果预览：顶部说话人卡片区，正文逐字稿（FR-V1 ~ V5、FR-N5 ~ N10）。
struct PreviewView: View {
    @ObservedObject var model: PreviewModel
    var onBack: (() -> Void)?
    var onOpenWindow: (() -> Void)?
    @State private var renaming: MeetingTarget?
    @State private var deleting: MeetingTarget?

    private var target: MeetingTarget { MeetingTarget(name: model.meeting.name, title: model.title) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let t = model.transcript {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        speakerCards
                        if let err = model.error {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                        Divider()
                        transcriptBody(t)
                    }
                    .padding(12)
                }
            } else {
                statusPlaceholder
            }
        }
        .onDisappear { model.stopPlayback() }
        .meetingManageAlerts(renaming: $renaming, deleting: $deleting, onRenamed: { model.reload() })
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let onBack {
                Button(action: onBack) { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .help("返回")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.headline).lineLimit(1)
                if let t = model.transcript {
                    Text("\(TranscriptWriter.clock(t.durationSec)) · \(t.speakers.count) 位说话人 · \(t.segments.count) 段")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.transcript != nil {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索", text: $model.searchText).textFieldStyle(.plain).frame(width: 90)
                    if model.matchCount > 0 {
                        Text("\(model.matchCount)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                Button { model.copyAll() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("复制全文")
            }
            Button { model.revealInFinder() } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless).help("在 Finder 中显示")
            Menu {
                Button("重命名…") { renaming = target }
                Divider()
                Button("删除会议…", role: .destructive) { model.stopPlayback(); deleting = target }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(AppState.shared.isBusy(model.meeting.name))
                .help("重命名或删除会议")
            if let onOpenWindow {
                Button(action: onOpenWindow) { Image(systemName: "macwindow") }
                    .buttonStyle(.borderless).help("在独立窗口打开")
            }
        }
        .padding(10)
    }

    private var statusPlaceholder: some View {
        VStack(spacing: 8) {
            Spacer()
            switch model.meta?.status {
            case .processing, .pending:
                ProgressView()
                Text("正在识别…").foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text("识别失败").font(.headline)
                Text(model.meta?.error ?? "").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("重新识别") { AppState.shared.retry(model.meeting.name); model.reload() }
            case .cancelled:
                Text("识别已取消").font(.headline)
                Button("重新识别") { AppState.shared.retry(model.meeting.name); model.reload() }
            case .recording:
                Text("正在录音").foregroundStyle(.secondary)
            default:
                Text("没有结果").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var speakerCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(model.cards) { card in
                SpeakerCardView(card: card, model: model)
            }
        }
    }

    private func transcriptBody(_ t: Transcript) -> some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(model.blocks) { b in
                VStack(alignment: .leading, spacing: 4) {
                    if b.pauseBefore {
                        Text("（暂停）").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                    HStack(spacing: 6) {
                        Circle().fill(model.color(for: b.speaker)).frame(width: 8, height: 8)
                        Text(t.displayName(of: b.speaker)).font(.subheadline.bold())
                            .foregroundStyle(model.color(for: b.speaker))
                        Text("\(TranscriptWriter.clock(b.start)) – \(TranscriptWriter.clock(b.end))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(highlighted(b.text))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 搜索关键字高亮（FR-V5）
    private func highlighted(_ text: String) -> AttributedString {
        var s = AttributedString(text)
        let q = model.searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return s }
        var search = s.startIndex..<s.endIndex
        while let r = s[search].range(of: q, options: .caseInsensitive) {
            s[r].backgroundColor = .yellow.opacity(0.5)
            search = r.upperBound..<s.endIndex
        }
        return s
    }
}

/// 说话人卡片（FR-N5、N6）。
struct SpeakerCardView: View {
    let card: PreviewModel.Card
    @ObservedObject var model: PreviewModel
    @State private var input = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    private var color: Color { model.color(for: card.id, fallback: card.colorIndex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(card.speaker.name).font(.headline).lineLimit(1)
                if card.speaker.name != card.id {
                    Text(card.id).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                badge
            }
            HStack(spacing: 6) {
                Label(TranscriptWriter.clock(card.duration), systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                Text(card.speaker.track == .mic ? "麦克风" : card.speaker.track == .system ? "会议软件" : "文件")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                ForEach(Array(card.clips.enumerated()), id: \.offset) { i, clip in
                    Button { model.play(clip) } label: {
                        Image(systemName: model.playingClip == clip.file ? "stop.circle.fill" : "play.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("试听特征片段 \(i + 1)（\(TranscriptWriter.clock(clip.start))）")
                }
            }
            if editing {
                editor
            } else {
                HStack(spacing: 6) {
                    Button(card.speaker.source == .none ? "命名" : "修改") {
                        input = card.speaker.source == .none ? "" : card.speaker.name
                        editing = true
                        focused = true
                    }
                    if card.speaker.source == .auto {
                        Button("确认") { model.confirm(card.id) }.help("确认自动识别结果")
                    }
                    Menu("更多") {
                        Button("标为“多人”") { model.markMultiple(card.id) }
                        if card.speaker.source != .none {
                            Button("清除姓名") { model.clear(card.id) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.4)))
    }

    @ViewBuilder
    private var badge: some View {
        switch card.speaker.source {
        case .auto:
            Text("自动识别").font(.caption2).padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(Color.green.opacity(0.2)))
                .help(card.bestMatch.map { String(format: "相似度 %.2f", $0.score) } ?? "")
        case .none:
            Text("未命名").font(.caption2).padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(Color.gray.opacity(0.2)))
        case .user:
            Text("已标注").font(.caption2).padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(Color.blue.opacity(0.15)))
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                TextField("输入姓名或从人物库选择", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(commit)
                Button("确定", action: commit).keyboardShortcut(.defaultAction)
                Button("取消") { editing = false }
            }
            .controlSize(.small)
            let sugg = model.suggestions(for: input).filter { $0.name != input }
            if !sugg.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sugg.prefix(5)) { p in
                        Button {
                            model.assign(person: p, to: card.id)
                            editing = false
                        } label: {
                            HStack {
                                Text(p.name)
                                Spacer()
                                Text("样本 \(p.samples.count)").font(.caption2).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }
        }
    }

    private func commit() {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            model.clear(card.id)
        } else {
            model.assign(name: name, to: card.id)
        }
        editing = false
    }
}

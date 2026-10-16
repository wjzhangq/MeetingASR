import AVFoundation
import AppKit
import MeetingASRCore
import SwiftUI

/// 声纹库（人物库，FR-C6）：独立窗口管理人物、颜色、样本。
struct PeopleLibraryView: View {
    @ObservedObject var state: AppState
    @State private var people: [Person] = []
    @State private var selection: String?
    @State private var renameText = ""
    @State private var mergeTarget: String = ""
    @State private var error: String?
    @State private var player: AVAudioPlayer?

    private var selected: Person? { people.first { $0.id == selection } }

    var body: some View {
        HStack(spacing: 12) {
            peopleList
            if let p = selected {
                detail(p)
            } else {
                emptyDetail
            }
        }
        .padding(12)
        .frame(minWidth: 640, minHeight: 440)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .peopleLibraryChanged)) { _ in reload() }
        .onChange(of: selection) { _, _ in renameText = selected?.name ?? "" }
    }

    // MARK: - 列表

    private var peopleList: some View {
        List(people, selection: $selection) { p in
            PersonRow(person: p).tag(p.id)
        }
        .frame(width: 200)
    }

    private var emptyDetail: some View {
        VStack {
            Spacer()
            Text(people.isEmpty ? "人物库为空。在会议结果中为说话人填写姓名后会自动加入。" : "选择一个人物")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 详情

    private func detail(_ p: Person) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(p.name).font(.title3.bold())
            Text("ID \(p.id) · \(p.samples.count) 条声纹样本").font(.caption).foregroundStyle(.secondary)
            renameRow(p)
            colorRow(p)
            mergeRow(p)
            Text("样本来源").font(.headline)
            sampleList(p)
            HStack {
                Spacer()
                Button("删除人物", role: .destructive) { confirmDelete(p) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { renameText = p.name }
    }

    private func renameRow(_ p: Person) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("新姓名", text: $renameText).textFieldStyle(.roundedBorder)
                Button("改名") { run { try state.people.rename(personId: p.id, to: renameText) } }
            }
            Text("改名不会回溯修改历史会议的逐字稿。").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func mergeRow(_ p: Person) -> some View {
        HStack {
            Picker("合并到", selection: $mergeTarget) {
                Text("选择人物").tag("")
                ForEach(people.filter { $0.id != p.id }) { other in
                    Text(other.name).tag(other.id)
                }
            }
            Button("合并") {
                let target = mergeTarget
                guard !target.isEmpty else { return }
                run { try state.people.merge(p.id, into: target) }
                selection = target
            }
        }
    }

    private func sampleList(_ p: Person) -> some View {
        let dir = state.layout.personDir(p.id)
        let samples = Array(p.samples.enumerated())
        return List(samples, id: \.offset) { item in
            SampleRow(sample: item.element) { clip in play(dir.appendingPathComponent(clip)) }
        }
    }

    /// 颜色：色板快速选择 + 自定义取色，恢复默认则按会议内顺序取色
    private func colorRow(_ p: Person) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("颜色")
                ForEach(PersonColor.palette, id: \.self) { hex in
                    ColorSwatch(hex: hex, selected: p.color == hex) { setColor(p, hex) }
                }
                ColorPicker("", selection: colorBinding(p), supportsOpacity: false)
                    .labelsHidden()
                    .help("自定义颜色")
                if p.color != nil {
                    Button("默认") { setColor(p, nil) }.controlSize(.small).help("恢复默认：按会议内顺序取色")
                }
            }
            Text("该颜色用于所有会议中此人的说话人卡片与逐字稿。").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func colorBinding(_ p: Person) -> Binding<Color> {
        Binding(
            get: { Palette.color(hex: p.color) ?? .gray },
            set: { c in if let hex = Palette.hex(c) { setColor(p, hex) } }
        )
    }

    // MARK: - 操作

    private func confirmDelete(_ p: Person) {
        let alert = NSAlert()
        alert.messageText = "删除“\(p.name)”？"
        alert.informativeText = "将删除该人物的全部声纹样本与片段，之后的会议不再自动识别此人。历史会议逐字稿不受影响。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            run { try state.people.delete(personId: p.id) }
            selection = nil
        }
    }

    private func setColor(_ p: Person, _ hex: String?) {
        guard p.color != hex else { return }
        run { try state.people.setColor(personId: p.id, to: hex) }
    }

    private func reload() {
        state.people.reload()
        people = state.people.people.sorted { $0.name < $1.name }
    }

    private func run(_ body: () throws -> Void) {
        do {
            try body()
            error = nil
            NotificationCenter.default.post(name: .peopleLibraryChanged, object: nil)
        } catch {
            self.error = "\(error)"
        }
        reload()
    }

    private func play(_ url: URL) {
        player?.stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }
}

private struct PersonRow: View {
    let person: Person

    var body: some View {
        HStack {
            Circle()
                .fill(Palette.color(hex: person.color) ?? Color.secondary.opacity(0.4))
                .frame(width: 10, height: 10)
            Text(person.name)
            Spacer()
            Text("\(person.samples.count)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SampleRow: View {
    let sample: PersonSample
    let onPlay: (String) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(sample.meeting).lineLimit(1)
                Text(sample.speaker + " · " + (sample.source == .auto ? "自动识别" : "用户标注"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let clip = sample.clips.first {
                Button { onPlay(clip) } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.borderless)
            }
        }
    }
}

private struct ColorSwatch: View {
    let hex: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Palette.color(hex: hex) ?? Color.gray)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(Color.primary, lineWidth: selected ? 2 : 0))
        }
        .buttonStyle(.plain)
        .help(hex)
    }
}

extension Notification.Name {
    /// 声纹库内容（姓名、颜色、合并、删除）变化，预览需刷新颜色
    static let peopleLibraryChanged = Notification.Name("MeetingASR.peopleLibraryChanged")
}

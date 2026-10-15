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

    var body: some View {
        HStack(spacing: 12) {
            List(people, selection: $selection) { p in
                HStack {
                    Circle().fill(Palette.color(hex: p.color) ?? Color.secondary.opacity(0.4)).frame(width: 10, height: 10)
                    Text(p.name)
                    Spacer()
                    Text("\(p.samples.count)").font(.caption).foregroundStyle(.secondary)
                }
                .tag(p.id)
            }
            .frame(width: 200)
            if let p = people.first(where: { $0.id == selection }) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(p.name).font(.title3.bold())
                    Text("ID \(p.id) · \(p.samples.count) 条声纹样本").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("新姓名", text: $renameText).textFieldStyle(.roundedBorder)
                        Button("改名") { run { try state.people.rename(personId: p.id, to: renameText) } }
                    }
                    Text("改名不会回溯修改历史会议的逐字稿。").font(.caption2).foregroundStyle(.secondary)
                    colorRow(p)
                    HStack {
                        Picker("合并到", selection: $mergeTarget) {
                            Text("选择人物").tag("")
                            ForEach(people.filter { $0.id != p.id }) { Text($0.name).tag($0.id) }
                        }
                        Button("合并") {
                            let target = mergeTarget
                            guard !target.isEmpty else { return }
                            run { try state.people.merge(p.id, into: target) }
                            selection = target
                        }
                    }
                    Text("样本来源").font(.headline)
                    List(Array(p.samples.enumerated()), id: \.offset) { _, s in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(s.meeting).lineLimit(1)
                                Text("\(s.speaker) · \(s.source == .auto ? "自动识别" : "用户标注")").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let clip = s.clips.first {
                                Button { play(state.layout.personDir(p.id).appendingPathComponent(clip)) } label: { Image(systemName: "play.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("删除人物", role: .destructive) {
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
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }
                .onAppear { renameText = p.name }
                .onChange(of: selection) { _, _ in renameText = people.first { $0.id == selection }?.name ?? "" }
            } else {
                VStack {
                    Spacer()
                    Text(people.isEmpty ? "人物库为空。在会议结果中为说话人填写姓名后会自动加入。" : "选择一个人物")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .frame(minWidth: 640, minHeight: 440)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .peopleLibraryChanged)) { _ in reload() }
    }

    /// 颜色：色板快速选择 + 自定义取色，恢复默认则按会议内顺序取色
    @ViewBuilder
    private func colorRow(_ p: Person) -> some View {
        HStack(spacing: 6) {
            Text("颜色")
            ForEach(PersonColor.palette, id: \.self) { hex in
                Button { setColor(p, hex) } label: {
                    Circle().fill(Palette.color(hex: hex) ?? .gray).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.primary, lineWidth: p.color == hex ? 2 : 0))
                }
                .buttonStyle(.plain)
                .help(hex)
            }
            ColorPicker("", selection: Binding(
                get: { Palette.color(hex: p.color) ?? .gray },
                set: { if let hex = Palette.hex($0) { setColor(p, hex) } }
            ), supportsOpacity: false)
            .labelsHidden()
            .help("自定义颜色")
            if p.color != nil {
                Button("默认") { setColor(p, nil) }.controlSize(.small).help("恢复默认：按会议内顺序取色")
            }
        }
        Text("该颜色用于所有会议中此人的说话人卡片与逐字稿。").font(.caption2).foregroundStyle(.secondary)
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
}

extension Notification.Name {
    /// 声纹库内容（姓名、颜色、合并、删除）变化，预览需刷新颜色
    static let peopleLibraryChanged = Notification.Name("MeetingASR.peopleLibraryChanged")

    private func play(_ url: URL) {
        player?.stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }
}

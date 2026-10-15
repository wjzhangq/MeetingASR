import AVFoundation
import AppKit
import MeetingASRCore
import SwiftUI

/// 设置窗口（3.8）。
struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        TabView {
            GeneralSettings(state: state).tabItem { Label("通用", systemImage: "gearshape") }
            CaptureSettings(state: state).tabItem { Label("采集", systemImage: "mic") }
            RecognitionSettingsView(state: state).tabItem { Label("识别", systemImage: "text.bubble") }
            HotwordSettings(state: state).tabItem { Label("热词", systemImage: "text.badge.star") }
            PeopleSettings(state: state).tabItem { Label("人物库", systemImage: "person.2") }
        }
        .padding(16)
        .frame(width: 560, height: 460)
    }
}

// MARK: - 通用

private struct GeneralSettings: View {
    @ObservedObject var state: AppState
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("登录时自动启动", isOn: Binding(
                    get: { state.settings.launchAtLogin },
                    set: { on in
                        do {
                            try LoginItem.set(on)
                            state.settings.launchAtLogin = on
                            state.saveSettings()
                            loginError = nil
                        } catch {
                            loginError = "设置失败：\(error.localizedDescription)"
                        }
                    }))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            Section("全局快捷键") {
                LabeledContent("开始 / 停止") {
                    HotkeyRecorder(value: Binding(get: { state.settings.hotkeyStartStop }, set: { state.settings.hotkeyStartStop = $0; state.saveSettings() }))
                }
                LabeledContent("暂停 / 继续") {
                    HotkeyRecorder(value: Binding(get: { state.settings.hotkeyPauseResume }, set: { state.settings.hotkeyPauseResume = $0; state.saveSettings() }))
                }
            }
            Section("数据") {
                LabeledContent("存储目录") {
                    Button(state.layout.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        NSWorkspace.shared.open(state.layout.root)
                    }
                    .buttonStyle(.link)
                }
                Text("所有数据仅保存在本机，运行时不联网。识别完成后原始录音立即删除，仅保留文字结果和每位说话人的少量特征片段。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// 快捷键录制按钮。
struct HotkeyRecorder: View {
    @Binding var value: HotkeySetting?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button(recording ? "请按下快捷键…" : HotkeyManager.describe(value)) {
                recording ? stopRecording() : startRecording()
            }
            .frame(minWidth: 120)
            if value != nil {
                Button { value = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc 取消
                stopRecording()
                return nil
            }
            let mods = HotkeyManager.carbonModifiers(event.modifierFlags)
            // 至少需要一个修饰键，避免占用普通按键
            guard mods != 0 else { return nil }
            value = HotkeySetting(keyCode: UInt32(event.keyCode), modifiers: mods)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - 采集

private struct CaptureSettings: View {
    @ObservedObject var state: AppState
    @State private var devices: [AudioDeviceInfo] = []
    @State private var newName = ""
    @State private var newBundle = ""

    var body: some View {
        Form {
            Section("采集源") {
                Picker("录制", selection: Binding(get: { state.settings.captureSource }, set: { state.settings.captureSource = $0; state.saveSettings() })) {
                    ForEach(CaptureSource.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("麦克风") {
                Picker("输入设备", selection: Binding(get: { state.settings.micDeviceUID ?? "" }, set: { state.settings.micDeviceUID = $0.isEmpty ? nil : $0; state.saveSettings() })) {
                    Text("系统默认").tag("")
                    ForEach(devices) { Text($0.name).tag($0.uid) }
                }
                Toggle("回声消除（外放时减少远端声音串入麦克风）", isOn: Binding(get: { state.settings.micVoiceProcessing }, set: { state.settings.micVoiceProcessing = $0; state.saveSettings() }))
            }
            Section("会议软件（按 Bundle ID 匹配，含子进程）") {
                ForEach(state.settings.captureApps) { app in
                    HStack {
                        Toggle(isOn: Binding(get: { app.enabled }, set: { on in
                            if let i = state.settings.captureApps.firstIndex(where: { $0.id == app.id }) {
                                state.settings.captureApps[i].enabled = on
                                state.saveSettings()
                            }
                        })) {
                            VStack(alignment: .leading) {
                                Text(app.name)
                                Text(app.bundleIDs.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            state.settings.captureApps.removeAll { $0.id == app.id }
                            state.saveSettings()
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("名称", text: $newName).frame(width: 100)
                    TextField("Bundle ID，多个用逗号分隔", text: $newBundle)
                    Button("添加") {
                        let ids = newBundle.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        guard !ids.isEmpty else { return }
                        state.settings.captureApps.append(CaptureApp(name: newName.isEmpty ? ids[0] : newName, bundleIDs: ids))
                        state.saveSettings()
                        newName = ""; newBundle = ""
                    }
                }
                Button("恢复默认列表") { state.settings.captureApps = CaptureApp.defaults; state.saveSettings() }
                    .buttonStyle(.link)
            }
        }
        .formStyle(.grouped)
        .onAppear { devices = AudioDevices.inputDevices() }
    }
}

// MARK: - 识别

private struct RecognitionSettingsView: View {
    @ObservedObject var state: AppState

    private func binding<T>(_ kp: WritableKeyPath<RecognitionSettings, T>) -> Binding<T> {
        Binding(get: { state.settings.recognition[keyPath: kp] }, set: { state.settings.recognition[keyPath: kp] = $0; state.saveSettings() })
    }

    var body: some View {
        Form {
            Section("说话人数") {
                Picker("默认", selection: Binding(get: { state.settings.recognition.defaultSpeakerCount ?? 0 }, set: { state.settings.recognition.defaultSpeakerCount = $0 == 0 ? nil : $0; state.saveSettings() })) {
                    Text("自动").tag(0)
                    ForEach(1...12, id: \.self) { Text("\($0) 人").tag($0) }
                }
            }
            Section("高级") {
                LabeledContent("聚类阈值 \(String(format: "%.2f", state.settings.recognition.clusterThreshold))") {
                    Slider(value: binding(\.clusterThreshold), in: 0.2...0.9, step: 0.05)
                }
                Text("人数未知时使用。越小分得越细（说话人越多）。").font(.caption).foregroundStyle(.secondary)
                LabeledContent("相似说话人合并 \(state.settings.recognition.clusterMergeSimilarity > 0 ? String(format: "%.2f", state.settings.recognition.clusterMergeSimilarity) : "关闭")") {
                    Slider(value: binding(\.clusterMergeSimilarity), in: 0...0.9, step: 0.05)
                }
                Text("分离后声纹相似度达到该值的说话人合并为一人，0 为关闭。越小合并越多。与人物库同一人匹配的说话人总会合并。").font(.caption).foregroundStyle(.secondary)
                Stepper("发言少于 \(Int(state.settings.recognition.minSpeakerSec)) 秒的说话人并入最相近者", value: binding(\.minSpeakerSec), in: 0...10, step: 1)
                LabeledContent("声纹匹配阈值 \(String(format: "%.2f", state.settings.recognition.matchThreshold))") {
                    Slider(value: binding(\.matchThreshold), in: 0.3...0.9, step: 0.05)
                }
                Text("相似度达到阈值时直接标注姓名。越大越严格（误标少、漏标多）。").font(.caption).foregroundStyle(.secondary)
                Stepper("每位说话人保存特征片段：\(state.settings.recognition.clipsPerSpeaker) 段", value: binding(\.clipsPerSpeaker), in: 1...6)
                Stepper("每个人物最多样本：\(state.settings.recognition.maxSamplesPerPerson) 条", value: binding(\.maxSamplesPerPerson), in: 5...50)
                Stepper("推理线程：\(state.settings.recognition.numThreads)", value: binding(\.numThreads), in: 1...16)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 热词

private struct HotwordSettings: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("一行一个词（项目名、产品名、人名）。识别后按拼音近似纠正为热词写法；人物库中的姓名会自动加入。")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $state.hotwordsText)
                .font(.body.monospaced())
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Text("\(HotwordList(text: state.hotwordsText).words.count) 个热词").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([AppSupport.hotwordsFile]) }
                Button("保存") { state.saveHotwords() }.keyboardShortcut("s")
            }
        }
        .onDisappear { state.saveHotwords() }
    }
}

// MARK: - 人物库（FR-C6）

private struct PeopleSettings: View {
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
                    Text(p.name)
                    Spacer()
                    Text("\(p.samples.count)").font(.caption).foregroundStyle(.secondary)
                }
                .tag(p.id)
            }
            .frame(width: 180)
            if let p = people.first(where: { $0.id == selection }) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(p.name).font(.title3.bold())
                    Text("ID \(p.id) · \(p.samples.count) 条声纹样本").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("新姓名", text: $renameText).textFieldStyle(.roundedBorder)
                        Button("改名") { run { try state.people.rename(personId: p.id, to: renameText) } }
                    }
                    Text("改名不会回溯修改历史会议的逐字稿。").font(.caption2).foregroundStyle(.secondary)
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
        .onAppear(perform: reload)
    }

    private func reload() {
        state.people.reload()
        people = state.people.people.sorted { $0.name < $1.name }
    }

    private func run(_ body: () throws -> Void) {
        do {
            try body()
            error = nil
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

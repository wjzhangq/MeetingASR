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
                LabeledContent("声纹库") {
                    Button("打开声纹库…") { state.openPeopleLibrary?() }
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

                // 场景说明
                VStack(alignment: .leading, spacing: 4) {
                    Text("• 仅麦克风：录制你的声音，适合单人演示、讲座或播客").font(.caption).foregroundStyle(.secondary)
                    Text("• 仅会议软件：录制会议中所有人的声音，适合多人远程会议").font(.caption).foregroundStyle(.secondary)
                    Text("• 麦克风 + 会议软件：同时录制两路音轨，可分离本地和远程声音").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("麦克风") {
                Picker("输入设备", selection: Binding(get: { state.settings.micDeviceUID ?? "" }, set: { state.settings.micDeviceUID = $0.isEmpty ? nil : $0; state.saveSettings() })) {
                    Text("系统默认").tag("")
                    ForEach(devices) { Text($0.name).tag($0.uid) }
                }
                Toggle("回声消除（外放时减少远端声音串入麦克风）", isOn: Binding(get: { state.settings.micVoiceProcessing }, set: { state.settings.micVoiceProcessing = $0; state.saveSettings() }))
            }
            Section("会议检测") {
                Toggle("会议软件开始通话时提示是否录音", isOn: Binding(get: { state.settings.meetingDetection }, set: { state.settings.meetingDetection = $0; state.saveSettings() }))
                Toggle("会议结束时自动停止录音并识别", isOn: Binding(get: { state.settings.autoStopOnMeetingEnd }, set: { state.settings.autoStopOnMeetingEnd = $0; state.saveSettings() }))
                Text("按下方已启用的会议软件检测：持续占用麦克风 5 秒视为会议开始，停止通话（不再采集也不再播放声音）15 秒视为会议结束。只会自动停止检测到会议的录音。提示出现在屏幕右上角：回车或“开始 / 停止”快捷键确认，Esc 关闭，5 秒无操作自动关闭。").font(.caption).foregroundStyle(.secondary)
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
    @StateObject private var installer = AsrModelInstaller()
    /// 安装完成后刷新“已安装”状态
    @State private var installedVersion = 0

    private func binding<T>(_ kp: WritableKeyPath<RecognitionSettings, T>) -> Binding<T> {
        Binding(get: { state.settings.recognition[keyPath: kp] }, set: { state.settings.recognition[keyPath: kp] = $0; state.saveSettings() })
    }

    var body: some View {
        Form {
            Section("识别模型") {
                Picker("模型", selection: binding(\.asrModel)) {
                    ForEach(AsrModelKind.allCases, id: \.self) { k in
                        Text(k.displayName + (AsrModelInstaller.isInstalled(k) ? "" : "（未安装）")).tag(k)
                    }
                }
                .id(installedVersion)
                let kind = state.settings.recognition.asrModel
                if !AsrModelInstaller.isInstalled(kind) {
                    HStack {
                        Text("未安装时使用 Paraformer。").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        switch installer.state {
                        case .downloading(let p):
                            ProgressView(value: p).frame(width: 120)
                            Button("取消") { installer.cancel() }
                        case .extracting:
                            ProgressView().controlSize(.small)
                            Text("正在解压…").font(.caption)
                        case .idle, .failed:
                            Button("下载安装") {
                                installer.install(kind) { _ in installedVersion += 1 }
                            }
                            .disabled(installer.installing != nil)
                        }
                    }
                    if case .failed(let msg) = installer.state {
                        Text("安装失败：\(msg)").font(.caption).foregroundStyle(.red)
                    }
                }
                Text("SenseVoice 支持中英日韩粤多语种。切换后从下一次识别生效。").font(.caption).foregroundStyle(.secondary)
            }
            Section("识别方式") {
                Picker("方式", selection: binding(\.recognitionMode)) {
                    ForEach(RecognitionMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text("先识别再分配说话人：按长句识别，上下文更完整，重叠语音不会重复。模型不输出字级时间戳时自动按段识别。").font(.caption).foregroundStyle(.secondary)
            }
            Section("推理后端") {
                Picker("执行后端", selection: binding(\.inferenceProvider)) {
                    ForEach(InferenceProvider.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text("默认使用 CPU。神经引擎在部分机型上更快；变长音频若变慢或内存升高，保持 CPU。切换后从下一次识别生效。").font(.caption).foregroundStyle(.secondary)
            }
            Section("录音时识别") {
                Toggle("录音期间提前识别", isOn: Binding(get: { state.settings.liveDiarization }, set: { state.settings.liveDiarization = $0; state.saveSettings() }))
                Text("语音段闭合后就在后台做识别和声纹，停止后只补尾段并做聚类。会占用一些 CPU，可随时关闭。从下一次录音生效。").font(.caption).foregroundStyle(.secondary)
            }
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

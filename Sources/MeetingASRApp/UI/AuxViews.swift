import AVFoundation
import AppKit
import MeetingASRCore
import SwiftUI

/// 识别音频文件：可指定时间范围与说话人数（FR-F1 ~ F3）。
struct FileRecognizeView: View {
    let url: URL
    let duration: Double
    var onStart: (ClosedRange<Double>?, Int?) -> Void
    var onCancel: () -> Void

    @State private var useRange = false
    @State private var startText = "00:00:00"
    @State private var endText = ""
    @State private var autoCount = true
    @State private var count = 2
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("识别音频文件").font(.headline)
            HStack {
                Image(systemName: "waveform")
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(TranscriptWriter.clock(duration)).foregroundStyle(.secondary).font(.body.monospacedDigit())
            }
            Toggle("只识别部分时间范围", isOn: $useRange)
            if useRange {
                HStack {
                    TextField("开始", text: $startText).textFieldStyle(.roundedBorder).frame(width: 100)
                    Text("至")
                    TextField("结束", text: $endText).textFieldStyle(.roundedBorder).frame(width: 100)
                    Text("格式 时:分:秒 或 秒").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Toggle("说话人数自动", isOn: $autoCount)
                Spacer()
                Stepper("\(count) 人", value: $count, in: 1...20).disabled(autoCount)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("结果保存到 会议目录，源文件不会被修改或删除。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("开始识别", action: start).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { endText = TranscriptWriter.clock(duration) }
    }

    private func start() {
        var range: ClosedRange<Double>?
        if useRange {
            guard let s = Self.parseTime(startText), let e = Self.parseTime(endText), e > s else {
                error = "时间范围无效"
                return
            }
            range = max(0, s)...min(duration, e)
        }
        onStart(range, autoCount ? nil : count)
    }

    /// 支持 "1:02:03"、"02:03"、"123.5"
    static func parseTime(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }
}

/// 首次启动引导：申请权限，展示录音告知与声纹信息告知（第 5、6 章）。
struct OnboardingView: View {
    var onDone: () -> Void
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "waveform.circle.fill").font(.system(size: 40)).foregroundStyle(.red)
                VStack(alignment: .leading) {
                    Text("欢迎使用 MeetingASR").font(.title2.bold())
                    Text("本地会议录音与识别").foregroundStyle(.secondary)
                }
            }
            GroupBox("隐私说明") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("录音、识别、结果全部在本机完成，运行时不联网。", systemImage: "lock.shield")
                    Label("识别完成后立即删除原始录音，只保留文字结果。", systemImage: "trash")
                    Label("录音时菜单栏图标变为红色。请在录音前告知与会者。", systemImage: "record.circle")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            GroupBox("声纹信息告知") {
                Text("为在后续会议中自动标注姓名，App 会为每位说话人保存少量特征音频片段和声纹向量，并在你填写姓名后存入本机人物库（~/Documents/MeetingASR/people）。你可以随时在 设置 › 人物库 中删除。")
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(4)
            }
            GroupBox("权限") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("麦克风", systemImage: "mic")
                        Spacer()
                        switch micStatus {
                        case .authorized: Text("已允许").foregroundStyle(.green)
                        case .denied, .restricted:
                            Button("打开系统设置") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                            }
                        default:
                            Button("允许") {
                                Task {
                                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                                    micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                                }
                            }
                        }
                    }
                    HStack(alignment: .top) {
                        Label("系统录音（会议软件声音）", systemImage: "speaker.wave.2")
                        Spacer()
                        Text("首次录制会议软件时系统会弹窗请求").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(4)
            }
            HStack {
                Spacer()
                Button("开始使用", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

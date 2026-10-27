import AppKit
import Foundation
import MeetingASRCore
import MeetingASREngine
import os

/// 菜单栏显示的总体状态（FR-R1）。
enum AppPhase: Equatable {
    case idle
    case recording
    case paused
    case processing
}

/// 应用状态中心：录音控制、识别队列、最近会议、设置。
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let layout: StorageLayout
    let store: MeetingStore
    let people: PeopleStore
    private let log = Logger(subsystem: "com.meetingasr.app", category: "app")

    @Published var settings: AppSettings
    @Published private(set) var recorderState: RecorderState = .idle
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var processing: [String: ProcessingProgress] = [:]
    @Published private(set) var queued: [String] = []
    @Published private(set) var recent: [MeetingSummary] = []
    @Published private(set) var unfinished: [MeetingSummary] = []
    @Published var tapStatus: String?
    @Published var micDevice: String?
    @Published var lastError: String?
    @Published var hotwordsText: String

    private(set) var session: RecordingSession?
    private var queue: ProcessingQueue!
    private var ticker: Timer?
    let sleepGuard = SleepGuard()
    let meetingWatcher = MeetingWatcher()
    /// 本次录音期间检测到过会议（会议结束时才自动停止，避免误停手动开始的其他录音）
    private var meetingSeenDuringRecording = false
    /// 检测到会议时的“是否开始录音”提示
    private let meetingPrompt = MeetingPromptPanel()
    /// 录音期间按段提前识别。pyannote 实时分离不再启动。
    private var liveRecognition: LiveRecognitionRunner?
    /// 系统强制睡眠导致的暂停，唤醒后询问是否继续
    private var pausedBySleep = false

    var phase: AppPhase {
        switch recorderState {
        case .recording: return .recording
        case .paused: return .paused
        case .idle: return processing.isEmpty && queued.isEmpty ? .idle : .processing
        }
    }

    /// 当前正在处理的会议及进度（FR-P2）
    var currentProcessing: (name: String, progress: ProcessingProgress)? {
        processing.first.map { ($0.key, $0.value) }
    }

    private init() {
        let layout = StorageLayout.default
        let settings = AppSettings.load()
        let people = PeopleStore(layout: layout, maxSamplesPerPerson: settings.recognition.maxSamplesPerPerson)
        self.layout = layout
        self.settings = settings
        self.people = people
        store = MeetingStore(layout: layout)
        hotwordsText = HotwordList.load().words.joined(separator: "\n")
        try? layout.ensureDirectories()
        queue = ProcessingQueue(makeProcessor: {
            guard let paths = ModelPaths.locate() else { throw EngineError.modelMissing("Contents/Resources/models") }
            let settings = AppSettings.load()
            let engines = try SherpaEngineFactory.make(paths: paths, numThreads: settings.recognition.numThreads, asrModel: settings.recognition.asrModel, provider: settings.recognition.inferenceProvider.providerString)
            return MeetingProcessor(engines: engines, store: MeetingStore(layout: layout), people: people,
                                    options: ProcessingOptions(recognition: settings.recognition, hotwords: HotwordList.load()))
        }) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        // 每个任务开始前读取最新的设置与热词
        queue.configure = { opts in
            let s = AppSettings.load()
            opts.recognition = s.recognition
            opts.hotwords = HotwordList.load()
            people.maxSamplesPerPerson = s.recognition.maxSamplesPerPerson
        }
        sleepGuard.onWillSleep = { [weak self] in self?.handleSleep() }
        sleepGuard.onDidWake = { [weak self] in self?.handleWake() }
        meetingWatcher.onStarted = { [weak self] app in self?.handleMeetingStarted(app) }
        meetingWatcher.onEnded = { [weak self] app in self?.handleMeetingEnded(app) }
        refreshRecent()
        configureMeetingWatcher()
    }

    // MARK: - 会议检测

    /// 按设置启停会议检测。
    func configureMeetingWatcher() {
        if settings.meetingDetection || settings.autoStopOnMeetingEnd {
            meetingWatcher.start(apps: settings.captureApps)
        } else {
            meetingWatcher.stop()
        }
    }

    private func handleMeetingStarted(_ app: String) {
        if session != nil {
            // 已在录音（手动开始）：会议结束时可自动停止
            meetingSeenDuringRecording = true
            return
        }
        guard settings.meetingDetection, !meetingPrompt.isShown else { return }
        // 不激活本应用、不打断会议软件；回车 / 开始停止快捷键确认，5 秒无操作自动关闭
        meetingPrompt.show(
            title: "检测到 \(app) 会议，开始录音？",
            detail: settings.autoStopOnMeetingEnd ? "会议结束后将自动停止录音并开始识别。" : "可随时在菜单栏停止录音。",
            hotkey: settings.hotkeyStartStop.map { HotkeyManager.describe($0) }
        ) { [weak self] result in
            // 提示期间会议已结束或已手动开始则不再开始
            guard let self, result == .start, self.session == nil, self.meetingWatcher.inMeeting else { return }
            switch self.preflight() {
            case .micPermissionDenied:
                self.lastError = "麦克风权限被拒绝，请在 系统设置 › 隐私与安全性 中允许"
            case .ok, .appNotRunning:
                self.startRecording(StartRequest())
            }
        }
    }

    private func handleMeetingEnded(_ app: String) {
        if meetingPrompt.isShown { meetingPrompt.dismiss() }
        guard settings.autoStopOnMeetingEnd, session != nil, meetingSeenDuringRecording else { return }
        stop()
        Notifier.shared.post(title: "\(app) 会议已结束", body: "已自动停止录音并开始识别。")
    }

    // MARK: - 设置

    func saveSettings() {
        let before = AppSettings.load().recognition
        do { try settings.save() } catch { lastError = "保存设置失败：\(error)" }
        // 识别模型或线程数变化：下个任务重新加载模型
        if before.asrModel != settings.recognition.asrModel || before.numThreads != settings.recognition.numThreads {
            queue.reloadEngines()
        }
        people.maxSamplesPerPerson = settings.recognition.maxSamplesPerPerson
        registerHotkeys()
        configureMeetingWatcher()
    }

    func saveHotwords() {
        do { try HotwordList(text: hotwordsText).save() } catch { lastError = "保存热词失败：\(error)" }
    }

    func registerHotkeys() {
        HotkeyManager.shared.register(id: 1, settings.hotkeyStartStop) { [weak self] in self?.toggleStartStop() }
        HotkeyManager.shared.register(id: 2, settings.hotkeyPauseResume) { [weak self] in self?.togglePause() }
    }

    // MARK: - 录音控制（3.2）

    struct StartRequest {
        var title: String = ""
        var expectedSpeakers: Int?
        /// 会议软件未运行时用户确认仅录麦克风
        var micOnlyConfirmed = false
    }

    enum StartCheck {
        case ok
        /// 目标会议进程未运行（FR-A5）
        case appNotRunning
        case micPermissionDenied
    }

    /// 开始前检查（FR-A5）。
    func preflight() -> StartCheck {
        if settings.captureSource.includesMic, MicRecorder.permission == .denied || MicRecorder.permission == .restricted {
            return .micPermissionDenied
        }
        if settings.captureSource.includesApp, AudioProcessList.runningApps(settings.captureApps).isEmpty {
            return .appNotRunning
        }
        return .ok
    }

    func startRecording(_ req: StartRequest) {
        guard session == nil else { return }
        if meetingPrompt.isShown { meetingPrompt.dismiss() }
        lastError = nil
        var includeMic = settings.captureSource.includesMic
        var includeApp = settings.captureSource.includesApp
        if req.micOnlyConfirmed {
            includeMic = true
            includeApp = false
        }
        let opts = RecordingSession.Options(
            title: req.title.trimmingCharacters(in: .whitespacesAndNewlines),
            expectedSpeakers: req.expectedSpeakers ?? settings.recognition.defaultSpeakerCount,
            includeMic: includeMic,
            includeApp: includeApp,
            apps: settings.captureApps,
            micDeviceUID: settings.micDeviceUID,
            voiceProcessing: settings.micVoiceProcessing
        )
        Task {
            if includeMic, MicRecorder.permission == .notDetermined {
                _ = await MicRecorder.requestPermission()
            }
            do {
                let s = try RecordingSession(options: opts, layout: layout)
                s.onTapStatus = { [weak self] attached, ids in
                    self?.tapStatus = attached ? "正在采集：\(ids.joined(separator: ", "))" : "会议软件未在运行，等待中…"
                }
                s.onMicDeviceChange = { [weak self] name in self?.micDevice = name }
                let kinds: [TrackKind] = [includeMic ? TrackKind.mic : nil, includeApp ? TrackKind.system : nil].compactMap { $0 }
                let live: LiveRecognitionRunner? = settings.liveDiarization
                    ? LiveRecognitionRunner(meeting: s.meeting, tracks: kinds, recognition: settings.recognition)
                    : nil
                s.onTrackSamples = { kind, samples, sessionStart in
                    live?.accept(track: kind, samples, sessionStart: sessionStart)
                }
                try s.start()
                session = s
                micDevice = s.micDeviceName
                if includeApp, !s.isTapAttached { tapStatus = "会议软件未在运行，等待中…" }
                recorderState = .recording
                meetingSeenDuringRecording = meetingWatcher.inMeeting
                liveRecognition = live
                sleepGuard.preventIdleSleep(true)
                startTicker()
                warnIfSpeakerOutput(includeMic: includeMic, includeApp: includeApp)
                refreshRecent()
            } catch {
                lastError = "无法开始录音：\(error)"
                log.error("start failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func pause(reason: String = "user") {
        guard let session, recorderState == .recording else { return }
        session.pause(reason: reason)
        liveRecognition?.pause()
        recorderState = .paused
        elapsed = session.elapsed
    }

    func resume() {
        guard let session, recorderState == .paused else { return }
        session.resume()
        liveRecognition?.resume()
        recorderState = .recording
        pausedBySleep = false
    }

    /// 停止后自动进入识别流程（FR-R4）。
    func stop() {
        guard let session else { return }
        let m = session.stop()
        self.session = nil
        meetingSeenDuringRecording = false
        recorderState = .idle
        elapsed = 0
        tapStatus = nil
        micDevice = nil
        stopTicker()
        sleepGuard.preventIdleSleep(false)
        let live = liveRecognition
        liveRecognition = nil
        if (try? store.loadMeta(m))?.status == .pending {
            if let live {
                // 等已经闭合的段写完日志，会后处理会复用它们，只补尾段。
                if !queued.contains(m.name) { queued.append(m.name) }
                live.finish { [weak self] in self?.queue.enqueue(m) }
            } else {
                queue.enqueue(m)
            }
        } else {
            live?.finish {}
            lastError = "没有录到音频"
        }
        refreshRecent()
    }

    func toggleStartStop() {
        if session == nil, meetingPrompt.isShown {
            // 会议提示显示中：快捷键即确认开始
            meetingPrompt.confirm()
            return
        }
        if session == nil {
            switch preflight() {
            case .ok: startRecording(StartRequest())
            case .appNotRunning: startRecording(StartRequest(micOnlyConfirmed: settings.captureSource.includesMic))
            case .micPermissionDenied: lastError = "麦克风权限被拒绝，请在 系统设置 › 隐私与安全性 中允许"
            }
        } else {
            stop()
        }
    }

    func togglePause() {
        switch recorderState {
        case .recording: pause()
        case .paused: resume()
        case .idle: break
        }
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let s = self.session else { return }
                self.elapsed = s.elapsed
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    /// 外放时提示使用耳机（4.3 回声对策 3）。
    private func warnIfSpeakerOutput(includeMic: Bool, includeApp: Bool) {
        guard includeMic, includeApp, !settings.micVoiceProcessing,
              let out = AudioDevices.defaultSystemOutput, AudioDevices.isBuiltInSpeaker(out) else { return }
        Notifier.shared.post(title: "建议使用耳机", body: "检测到正在使用扬声器外放，远端声音可能串入麦克风。可在设置中开启回声消除。")
    }

    // MARK: - 睡眠

    private func handleSleep() {
        if recorderState == .recording {
            pause(reason: "sleep")
            pausedBySleep = true
        }
    }

    private func handleWake() {
        guard pausedBySleep, recorderState == .paused else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "系统已从睡眠中唤醒"
        alert.informativeText = "录音在睡眠前已自动暂停，是否继续录音？"
        alert.addButton(withTitle: "继续录音")
        alert.addButton(withTitle: "停止并识别")
        alert.addButton(withTitle: "保持暂停")
        switch alert.runModal() {
        case .alertFirstButtonReturn: resume()
        case .alertSecondButtonReturn: stop()
        default: break
        }
        pausedBySleep = false
    }

    // MARK: - 识别

    /// 识别音频文件（FR-F1/F3）。
    func recognizeFile(_ url: URL, range: ClosedRange<Double>?, speakers: Int?) {
        do {
            let m = try MeetingFactory.createFileMeeting(source: url, range: range, expectedSpeakers: speakers ?? settings.recognition.defaultSpeakerCount, layout: layout)
            queue.enqueue(m)
            refreshRecent()
        } catch {
            lastError = "无法识别该文件：\(error)"
        }
    }

    func cancelProcessing(_ name: String) {
        queue.cancel(layout.meeting(named: name))
    }

    func retry(_ name: String) {
        let m = layout.meeting(named: name)
        _ = try? store.recoverInterruptedRecording(m)
        queue.enqueue(m)
        refreshRecent()
    }

    /// 启动时检测异常退出遗留的录音（FR-R9）。
    func checkUnfinished() -> [MeetingSummary] {
        let busy = Set(queue.queuedMeetings.map(\.name) + [session?.meeting.name].compactMap { $0 })
        for s in store.allMeetings() where !busy.contains(s.paths.name) && s.status == .recording {
            _ = try? store.recoverInterruptedRecording(s.paths)
        }
        // 识别过程中退出的也算未完成
        for s in store.allMeetings() where !busy.contains(s.paths.name) && s.status == .processing {
            _ = try? store.updateMeta(s.paths) { $0.status = .pending }
        }
        unfinished = store.unfinishedMeetings(excluding: busy)
        return unfinished
    }

    private func handle(_ event: ProcessingEvent) {
        switch event {
        case .queued(let m, _):
            if !queued.contains(m.name) { queued.append(m.name) }
        case .started(let m):
            queued.removeAll { $0 == m.name }
            processing[m.name] = .at(.preprocess, 0)
        case .progress(let m, let p):
            processing[m.name] = p
        case .finished(let m, let t):
            processing[m.name] = nil
            let named = t.speakers.filter { $0.source == .auto }.count
            Notifier.shared.post(
                title: "识别完成：\(t.title)",
                body: "\(t.speakers.count) 位说话人，\(t.segments.count) 段" + (named > 0 ? "，自动识别 \(named) 人" : "") + "。点击查看结果。",
                meeting: m.name)
        case .failed(let m, let msg):
            processing[m.name] = nil
            queued.removeAll { $0 == m.name }
            Notifier.shared.post(title: "识别失败", body: msg, meeting: m.name)
            lastError = "识别失败：\(msg)"
        case .cancelled(let m):
            processing[m.name] = nil
            queued.removeAll { $0 == m.name }
        }
        refreshRecent()
    }

    // MARK: - 会议管理

    /// 正在录音、排队或识别中的会议不能改名或删除（写入的 meta / 结果会覆盖改动）。
    func isBusy(_ name: String) -> Bool {
        session?.meeting.name == name || processing[name] != nil || queued.contains(name)
    }

    /// 会议被删除后通知界面关闭对应的预览
    var onMeetingDeleted: ((String) -> Void)?
    /// 打开声纹库窗口（由菜单栏控制器提供）
    var openPeopleLibrary: (() -> Void)?
    /// 会议改名后通知界面更新窗口标题（目录名、新标题）
    var onMeetingRenamed: ((String, String) -> Void)?

    func renameMeeting(_ name: String, to title: String) {
        guard !isBusy(name) else {
            lastError = "会议正在录音或识别中，完成后再改名"
            return
        }
        do {
            let newTitle = try store.rename(layout.meeting(named: name), title: title)
            onMeetingRenamed?(name, newTitle)
        } catch {
            lastError = "改名失败：\(error)"
        }
        refreshRecent()
    }

    func deleteMeeting(_ name: String) {
        guard !isBusy(name) else {
            lastError = "会议正在录音或识别中，无法删除"
            return
        }
        do {
            try store.delete(layout.meeting(named: name))
        } catch {
            lastError = "删除失败：\(error)"
        }
        unfinished.removeAll { $0.paths.name == name }
        onMeetingDeleted?(name)
        refreshRecent()
    }

    func refreshRecent() {
        recent = store.recentMeetings(limit: 10)
    }

    var latestCompleted: MeetingSummary? { store.latestCompleted() }
}

import AVFoundation
import AppKit
import Foundation
import MeetingASRCore
import SwiftUI

/// 结果预览的数据模型（3.4 / 3.5）。
@MainActor
final class PreviewModel: ObservableObject {
    let meeting: MeetingPaths
    private let state: AppState
    private var naming: SpeakerNaming { SpeakerNaming(store: state.store, people: state.people) }

    @Published private(set) var transcript: Transcript?
    @Published private(set) var speakers: SpeakersFile?
    @Published private(set) var meta: MeetingMeta?
    @Published var searchText = ""
    @Published var error: String?
    @Published private(set) var playingClip: String?
    private var player: AVAudioPlayer?
    private var playerDelegate: PlayerDelegate?

    private var peopleObserver: NSObjectProtocol?

    init(meeting: MeetingPaths, state: AppState) {
        self.meeting = meeting
        self.state = state
        reload()
        // 声纹库中改了颜色等：刷新卡片与逐字稿颜色
        peopleObserver = NotificationCenter.default.addObserver(forName: .peopleLibraryChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }

    func reload() {
        meta = try? state.store.loadMeta(meeting)
        transcript = try? state.store.loadTranscript(meeting)
        speakers = try? state.store.loadSpeakers(meeting)
    }

    var title: String { transcript?.title ?? meta?.title ?? meeting.name }

    // MARK: - 说话人卡片

    struct Card: Identifiable {
        let id: String
        let speaker: TranscriptSpeaker
        let duration: Double
        let clips: [FeatureClip]
        let bestMatch: SpeakerMatch?
        let colorIndex: Int
    }

    var cards: [Card] {
        guard let t = transcript else { return [] }
        return t.speakers.enumerated().map { i, s in
            let rec = speakers?.record(s.id)
            return Card(id: s.id, speaker: s, duration: t.speakingDuration(of: s.id), clips: rec?.clips ?? [], bestMatch: rec?.bestMatch, colorIndex: colorIndex(for: s.id, fallback: i))
        }
    }

    /// 同一人物（合并后）使用同一颜色。
    func colorIndex(for speakerId: String, fallback: Int = 0) -> Int {
        guard let t = transcript, let s = t.speaker(speakerId) else { return fallback }
        let key = s.personId ?? s.id
        let keys = t.speakers.map { $0.personId ?? $0.id }
        var unique: [String] = []
        for k in keys where !unique.contains(k) { unique.append(k) }
        return unique.firstIndex(of: key) ?? fallback
    }

    /// 说话人颜色：已关联人物且在声纹库中设置了颜色时用该颜色（跨会议一致），否则按会议内顺序取默认色。
    func color(for speakerId: String, fallback: Int = 0) -> Color {
        if let pid = transcript?.speaker(speakerId)?.personId, let c = Palette.color(hex: state.people.person(id: pid)?.color) {
            return c
        }
        return Palette.color(colorIndex(for: speakerId, fallback: fallback))
    }

    func suggestions(for text: String) -> [Person] {
        state.people.suggestions(for: text)
    }

    func personName(_ id: String) -> String? { state.people.person(id: id)?.name }

    // MARK: - 命名（FR-N6 ~ N10）

    func assign(name: String, to speakerId: String) {
        perform { try naming.assign(name: name, to: speakerId, in: meeting) }
    }

    func assign(person: Person, to speakerId: String) {
        perform { try naming.assign(personId: person.id, to: speakerId, in: meeting) }
    }

    func confirm(_ speakerId: String) {
        perform { try naming.confirm(speakerId, in: meeting) }
    }

    func clear(_ speakerId: String) {
        perform { try naming.clear(speakerId, in: meeting) }
    }

    func markMultiple(_ speakerId: String) {
        perform { try naming.markMultiple(speakerId, in: meeting) }
    }

    private func perform(_ body: () throws -> Transcript) {
        do {
            transcript = try body()
            speakers = try? state.store.loadSpeakers(meeting)
            error = nil
            // 命名会新建人物 / 增删样本：声纹库窗口与其他预览同步刷新
            NotificationCenter.default.post(name: .peopleLibraryChanged, object: nil)
        } catch {
            self.error = "\(error)"
        }
    }

    // MARK: - 特征片段试听

    func play(_ clip: FeatureClip) {
        if playingClip == clip.file {
            stopPlayback()
            return
        }
        stopPlayback()
        do {
            let p = try AVAudioPlayer(contentsOf: meeting.clip(clip.file))
            let d = PlayerDelegate { [weak self] in
                Task { @MainActor in self?.playingClip = nil }
            }
            p.delegate = d
            playerDelegate = d
            p.play()
            player = p
            playingClip = clip.file
        } catch {
            self.error = "无法播放片段：\(error.localizedDescription)"
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playingClip = nil
    }

    // MARK: - 文本

    /// 按说话人分段展示：相邻同一说话人的段合为一组。
    struct Block: Identifiable {
        let id: Int
        let speaker: String
        let start: Double
        let end: Double
        let text: String
        let pauseBefore: Bool
    }

    var blocks: [Block] {
        guard let t = transcript else { return [] }
        let pauses = (t.pauses ?? []).map(\.at).sorted()
        var pi = 0
        var out: [Block] = []
        var cur: (speaker: String, start: Double, end: Double, texts: [String], pause: Bool)?
        var pendingPause = false
        func flush() {
            if let c = cur {
                out.append(Block(id: out.count, speaker: c.speaker, start: c.start, end: c.end, text: c.texts.joined(), pauseBefore: c.pause))
            }
            cur = nil
        }
        for s in t.segments where !s.text.isEmpty {
            while pi < pauses.count, pauses[pi] <= s.start {
                pi += 1
                pendingPause = true
            }
            if pendingPause || cur?.speaker != s.speaker {
                flush()
                cur = (s.speaker, s.start, s.end, [s.text], pendingPause)
                pendingPause = false
            } else if var c = cur {
                c.end = max(c.end, s.end)
                c.texts.append(s.text)
                cur = c
            }
        }
        flush()
        return out
    }

    /// 搜索命中数（FR-V5）
    var matchCount: Int {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        return blocks.reduce(0) { $0 + $1.text.components(separatedBy: q).count - 1 }
    }

    func copyAll() {
        guard let t = transcript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TranscriptWriter.plainText(t), forType: .string)
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([meeting.transcriptMarkdown])
    }
}

private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    let done: () -> Void
    init(_ done: @escaping () -> Void) { self.done = done }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { done() }
}

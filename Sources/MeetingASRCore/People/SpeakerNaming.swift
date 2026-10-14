import Foundation

public enum NamingError: Error, CustomStringConvertible {
    case speakerNotFound(String)

    public var description: String {
        switch self {
        case .speakerNotFound(let id): return "说话人不存在：\(id)"
        }
    }
}

/// 会后人物标注（3.5）：命名、从人物库选择、改正自动识别、合并、清除。
/// 每次操作同步更新 transcript.json/md/srt、speakers.json 和人物库。
public struct SpeakerNaming: Sendable {
    public static let multiplePeopleName = "多人"

    public let store: MeetingStore
    public let people: PeopleStore

    public init(store: MeetingStore, people: PeopleStore) {
        self.store = store
        self.people = people
    }

    /// 为说话人填写姓名（FR-N6）：已有同名人物则关联，否则新建人物。
    /// 同一会议中已有其他说话人使用该姓名时即为合并（FR-N10）。
    @discardableResult
    public func assign(name: String, to speakerId: String, in meeting: MeetingPaths) throws -> Transcript {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return try clear(speakerId, in: meeting) }
        if trimmed == Self.multiplePeopleName { return try markMultiple(speakerId, in: meeting) }
        let person = try people.findOrCreate(name: trimmed)
        return try assign(personId: person.id, to: speakerId, in: meeting)
    }

    /// 从人物库选择已有人物（FR-N6）或确认/改正自动识别（FR-N8、FR-N9）。
    @discardableResult
    public func assign(personId: String, to speakerId: String, in meeting: MeetingPaths) throws -> Transcript {
        guard let person = people.person(id: personId) else { throw PeopleStoreError.personNotFound(personId) }
        var t = try store.loadTranscript(meeting)
        var sp = try store.loadSpeakers(meeting)
        guard let ti = t.speakers.firstIndex(where: { $0.id == speakerId }) else { throw NamingError.speakerNotFound(speakerId) }

        // 撤销该说话人此前对人物库的贡献（可能是错误的自动识别），再加入正确人物
        try people.removeSample(meeting: meeting.name, speaker: speakerId)
        if let ri = sp.speakers.firstIndex(where: { $0.id == speakerId }) {
            let rec = sp.speakers[ri]
            if !rec.embedding.isEmpty {
                try people.addSample(
                    personId: person.id, meeting: meeting.name, speaker: speakerId,
                    embedding: rec.embedding, clipURLs: rec.clips.map { meeting.clip($0.file) }, source: .user
                )
                sp.speakers[ri].contributedTo = person.id
            }
        }
        t.speakers[ti].personId = person.id
        t.speakers[ti].name = person.name
        t.speakers[ti].source = .user
        try save(t, sp, meeting)
        return t
    }

    /// 确认自动识别结果（不改人物，只把来源改为用户确认）。
    @discardableResult
    public func confirm(_ speakerId: String, in meeting: MeetingPaths) throws -> Transcript {
        let t = try store.loadTranscript(meeting)
        guard let s = t.speaker(speakerId) else { throw NamingError.speakerNotFound(speakerId) }
        guard let pid = s.personId else { return t }
        return try assign(personId: pid, to: speakerId, in: meeting)
    }

    /// 清除命名，恢复 S1/S2 标签，并撤销对人物库的贡献。
    @discardableResult
    public func clear(_ speakerId: String, in meeting: MeetingPaths) throws -> Transcript {
        try relabel(speakerId, in: meeting, name: speakerId, source: .none)
    }

    /// 标为"多人"（分离把多人合成了一个说话人时）；不进入人物库。
    @discardableResult
    public func markMultiple(_ speakerId: String, in meeting: MeetingPaths) throws -> Transcript {
        try relabel(speakerId, in: meeting, name: Self.multiplePeopleName, source: .user)
    }

    private func relabel(_ speakerId: String, in meeting: MeetingPaths, name: String, source: NameSource) throws -> Transcript {
        var t = try store.loadTranscript(meeting)
        var sp = try store.loadSpeakers(meeting)
        guard let ti = t.speakers.firstIndex(where: { $0.id == speakerId }) else { throw NamingError.speakerNotFound(speakerId) }
        try people.removeSample(meeting: meeting.name, speaker: speakerId)
        if let ri = sp.speakers.firstIndex(where: { $0.id == speakerId }) { sp.speakers[ri].contributedTo = nil }
        t.speakers[ti].personId = nil
        t.speakers[ti].name = name
        t.speakers[ti].source = source
        try save(t, sp, meeting)
        return t
    }

    /// 同步写出三种格式与 speakers.json（FR-N7）。
    private func save(_ t: Transcript, _ sp: SpeakersFile, _ meeting: MeetingPaths) throws {
        try JSONIO.write(sp, to: meeting.speakersJSON)
        try TranscriptWriter.writeAll(t, to: meeting)
    }

    /// 人物库中人物改名后，用于刷新一场会议中引用该人物的显示名（默认不回溯，需显式调用）。
    @discardableResult
    public func refreshNames(in meeting: MeetingPaths) throws -> Transcript {
        var t = try store.loadTranscript(meeting)
        var changed = false
        for i in t.speakers.indices {
            if let pid = t.speakers[i].personId, let p = people.person(id: pid), p.name != t.speakers[i].name {
                t.speakers[i].name = p.name
                changed = true
            }
        }
        if changed { try TranscriptWriter.writeAll(t, to: meeting) }
        return t
    }
}

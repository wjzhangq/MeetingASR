import Foundation

public enum PeopleStoreError: Error, CustomStringConvertible {
    case personNotFound(String)
    case emptyName
    case invalidColor(String)

    public var description: String {
        switch self {
        case .personNotFound(let id): return "人物不存在：\(id)"
        case .emptyName: return "姓名不能为空"
        case .invalidColor(let s): return "颜色格式不正确：\(s)（应为 #RRGGBB）"
        }
    }
}

/// 人物声纹库（people/people.json + people/<person-id>/*.wav）。
/// 线程安全，所有修改立即落盘。
public final class PeopleStore: @unchecked Sendable {
    public let layout: StorageLayout
    public var maxSamplesPerPerson: Int
    private var db: PeopleDatabase
    private let lock = NSLock()

    public init(layout: StorageLayout, maxSamplesPerPerson: Int = 20) {
        self.layout = layout
        self.maxSamplesPerPerson = maxSamplesPerPerson
        db = (try? JSONIO.read(PeopleDatabase.self, from: layout.peopleFile)) ?? PeopleDatabase()
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func save() throws {
        try JSONIO.write(db, to: layout.peopleFile)
    }

    // MARK: 查询

    public func snapshot() -> PeopleDatabase { withLock { db } }

    public var people: [Person] { withLock { db.people } }

    public func person(id: String) -> Person? {
        withLock { db.people.first { $0.id == id } }
    }

    public func person(named name: String) -> Person? {
        let key = Self.normalizeName(name)
        return withLock { db.people.first { Self.normalizeName($0.name) == key } }
    }

    /// 输入联想（FR-N6）：前缀匹配优先，其次包含匹配。
    public func suggestions(for text: String, limit: Int = 8) -> [Person] {
        let key = Self.normalizeName(text)
        let all = people.sorted { $0.name < $1.name }
        guard !key.isEmpty else { return Array(all.prefix(limit)) }
        let prefix = all.filter { Self.normalizeName($0.name).hasPrefix(key) }
        let contains = all.filter { !Self.normalizeName($0.name).hasPrefix(key) && Self.normalizeName($0.name).contains(key) }
        return Array((prefix + contains).prefix(limit))
    }

    /// 人物库中所有姓名（自动加入热词）。
    public var allNames: [String] { people.map(\.name) }

    static func normalizeName(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: 人物

    /// 按姓名查找，不存在则新建。
    @discardableResult
    public func findOrCreate(name: String) throws -> Person {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PeopleStoreError.emptyName }
        if let p = person(named: trimmed) { return p }
        return try withLock {
            var id: String
            repeat { id = "p_" + String(format: "%04x", Int.random(in: 0..<0x10000)) } while db.people.contains { $0.id == id }
            // 新人物按色板依次取一个较少使用的颜色，之后的会议中保持不变
            let used = db.people.compactMap(\.color)
            let color = PersonColor.palette.min { a, b in
                used.filter { $0 == a }.count < used.filter { $0 == b }.count
            }
            let p = Person(id: id, name: trimmed, color: color)
            db.people.append(p)
            try save()
            return p
        }
    }

    public func rename(personId: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PeopleStoreError.emptyName }
        try withLock {
            guard let i = db.people.firstIndex(where: { $0.id == personId }) else { throw PeopleStoreError.personNotFound(personId) }
            db.people[i].name = trimmed
            try save()
        }
    }

    /// 设置人物颜色（"#RRGGBB"），nil 恢复为默认（按会议内顺序取色）。
    public func setColor(personId: String, to color: String?) throws {
        var value: String?
        if let color {
            guard let c = PersonColor.normalize(color) else { throw PeopleStoreError.invalidColor(color) }
            value = c
        }
        try withLock {
            guard let i = db.people.firstIndex(where: { $0.id == personId }) else { throw PeopleStoreError.personNotFound(personId) }
            db.people[i].color = value
            try save()
        }
    }

    public func delete(personId: String) throws {
        try withLock {
            db.people.removeAll { $0.id == personId }
            try? FileManager.default.removeItem(at: layout.personDir(personId))
            try save()
        }
    }

    /// 合并两个人物：from 的样本并入 into，删除 from。
    public func merge(_ fromId: String, into intoId: String) throws {
        guard fromId != intoId else { return }
        try withLock {
            guard let fi = db.people.firstIndex(where: { $0.id == fromId }) else { throw PeopleStoreError.personNotFound(fromId) }
            guard db.people.contains(where: { $0.id == intoId }) else { throw PeopleStoreError.personNotFound(intoId) }
            let from = db.people[fi]
            for s in from.samples {
                let clips = try copyClips(s.clips.map { layout.personDir(fromId).appendingPathComponent($0) }, to: intoId)
                var moved = s
                moved.clips = clips
                appendSample(moved, to: intoId)
            }
            db.people.remove(at: fi)
            try? FileManager.default.removeItem(at: layout.personDir(fromId))
            try save()
        }
    }

    // MARK: 样本

    /// 为人物加入一条样本（FR-N8），复制特征片段到 people/<person-id>/。
    /// 同一会议同一说话人的旧样本（无论属于谁）会先被撤销，保证幂等。
    public func addSample(personId: String, meeting: String, speaker: String, embedding: [Float], clipURLs: [URL], source: NameSource, at date: Date = Date()) throws {
        try withLock {
            guard db.people.contains(where: { $0.id == personId }) else { throw PeopleStoreError.personNotFound(personId) }
            removeSampleLocked(meeting: meeting, speaker: speaker)
            let clips = try copyClips(clipURLs, to: personId)
            appendSample(PersonSample(meeting: meeting, speaker: speaker, embedding: embedding, clips: clips, addedAt: date, source: source), to: personId)
            try save()
        }
    }

    /// 撤销某会议某说话人贡献的样本（FR-N9）。返回原所属人物 ID。
    @discardableResult
    public func removeSample(meeting: String, speaker: String) throws -> String? {
        try withLock {
            let owner = removeSampleLocked(meeting: meeting, speaker: speaker)
            if owner != nil { try save() }
            return owner
        }
    }

    /// 某会议某说话人贡献的样本当前属于哪个人物。
    public func sampleOwner(meeting: String, speaker: String) -> String? {
        withLock {
            db.people.first { $0.samples.contains { $0.meeting == meeting && $0.speaker == speaker } }?.id
        }
    }

    @discardableResult
    private func removeSampleLocked(meeting: String, speaker: String) -> String? {
        var owner: String?
        for i in db.people.indices {
            let removed = db.people[i].samples.filter { $0.meeting == meeting && $0.speaker == speaker }
            guard !removed.isEmpty else { continue }
            owner = db.people[i].id
            db.people[i].samples.removeAll { $0.meeting == meeting && $0.speaker == speaker }
            deleteClips(removed.flatMap(\.clips), personId: db.people[i].id)
        }
        return owner
    }

    private func appendSample(_ sample: PersonSample, to personId: String) {
        guard let i = db.people.firstIndex(where: { $0.id == personId }) else { return }
        db.people[i].samples.append(sample)
        db.people[i].samples.sort { $0.addedAt < $1.addedAt }
        // 超过上限时淘汰最旧样本
        while db.people[i].samples.count > maxSamplesPerPerson {
            let old = db.people[i].samples.removeFirst()
            deleteClips(old.clips, personId: personId)
        }
    }

    private func copyClips(_ urls: [URL], to personId: String) throws -> [String] {
        let dir = layout.personDir(personId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var existing = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        var next = 1
        var names: [String] = []
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            var name: String
            repeat {
                name = String(format: "%02d.wav", next)
                next += 1
            } while existing.contains(name)
            try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(name))
            existing.insert(name)
            names.append(name)
        }
        return names
    }

    private func deleteClips(_ names: [String], personId: String) {
        for n in names {
            try? FileManager.default.removeItem(at: layout.personDir(personId).appendingPathComponent(n))
        }
    }

    // MARK: 模型升级

    /// 声纹模型更换后，用保留的片段重新提取全部样本的声纹。
    /// - Parameter embed: 由片段文件计算声纹，失败返回 nil
    public func reembedAll(modelName: String, embed: (URL) -> [Float]?) throws {
        try withLock {
            for i in db.people.indices {
                for j in db.people[i].samples.indices {
                    let s = db.people[i].samples[j]
                    let vs = s.clips.compactMap { embed(layout.personDir(db.people[i].id).appendingPathComponent($0)) }
                    if !vs.isEmpty { db.people[i].samples[j].embedding = VectorMath.meanNormalized(vs) }
                }
            }
            db.embeddingModel = modelName
            try save()
        }
    }

    /// 从磁盘重新加载（外部修改后）。
    public func reload() {
        withLock {
            db = (try? JSONIO.read(PeopleDatabase.self, from: layout.peopleFile)) ?? PeopleDatabase()
        }
    }
}

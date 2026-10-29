import Foundation

// 脚本片段（TODO 23）：每台主机一份专属脚本库，数据目录 snippets.json 持久化
// （存储口径同 HostStore/CommandHistory：JSON 落数据目录；UI 形态参考 Berth Snippets）

struct HostSnippet: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var script: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, script: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.script = script
        self.createdAt = createdAt
    }
}

final class SnippetStore {
    static let shared = SnippetStore()

    private struct HostBucket: Codable {
        var hostId: UUID
        var snippets: [HostSnippet]
    }

    /// hostEntryId → 片段列表
    private var buckets: [UUID: [HostSnippet]] = [:]
    private var fileURL: URL {
        AppSettings.shared.dataDir.appendingPathComponent("snippets.json")
    }

    /// 变更通知（UI 刷新）
    var onChanged: (() -> Void)?

    private init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([HostBucket].self, from: data) else { return }
        buckets = Dictionary(uniqueKeysWithValues: list.map { ($0.hostId, $0.snippets) })
    }

    private func save() {
        let list = buckets.map { HostBucket(hostId: $0.key, snippets: $0.value) }
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: 查询

    func snippets(for hostId: UUID) -> [HostSnippet] {
        buckets[hostId] ?? []
    }

    // MARK: 增删改

    @discardableResult
    func add(hostId: UUID, name: String, script: String) -> HostSnippet {
        let snippet = HostSnippet(name: name, script: script)
        buckets[hostId, default: []].append(snippet)
        save()
        onChanged?()
        return snippet
    }

    /// 编辑（name/script 传 nil 表示不改）
    func update(hostId: UUID, snippetId: UUID, name: String? = nil, script: String? = nil) {
        guard var list = buckets[hostId],
              let index = list.firstIndex(where: { $0.id == snippetId }) else { return }
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            list[index].name = name.trimmingCharacters(in: .whitespaces)
        }
        if let script {
            list[index].script = script
        }
        buckets[hostId] = list
        save()
        onChanged?()
    }

    func remove(hostId: UUID, snippetId: UUID) {
        guard var list = buckets[hostId] else { return }
        list.removeAll { $0.id == snippetId }
        buckets[hostId] = list
        save()
        onChanged?()
    }
}

import Foundation

/// 文件管理器目录收藏（2026-10-26 用户指定）：按主机（连接标识 user@host:port）分别保存——
/// 不同服务器的目录互不通用。数据目录 bookmarks.json，`[identity: [路径]]`，路径不带尾斜杠（根目录除外），
/// 顺序 = 收藏顺序。多播观察者口径同 HostStore。
final class BookmarkStore {
    static let shared = BookmarkStore()

    private var map: [String: [String]] = [:]
    private var observers: [UUID: () -> Void] = [:]
    private var loaded = false

    private var fileURL: URL {
        AppSettings.shared.dataDir.appendingPathComponent("bookmarks.json")
    }

    @discardableResult
    func observe(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    /// 去掉尾斜杠（根目录保留），收藏与比对都用这个形态
    static func normalize(_ path: String) -> String {
        var value = path
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value.isEmpty ? "/" : value
    }

    func bookmarks(for identity: String) -> [String] {
        loadIfNeeded()
        return map[identity] ?? []
    }

    func isBookmarked(_ path: String, for identity: String) -> Bool {
        bookmarks(for: identity).contains(Self.normalize(path))
    }

    func add(_ path: String, for identity: String) {
        loadIfNeeded()
        let value = Self.normalize(path)
        var list = map[identity] ?? []
        guard !list.contains(value) else { return }
        list.append(value)
        map[identity] = list
        save()
    }

    func remove(_ path: String, for identity: String) {
        loadIfNeeded()
        let value = Self.normalize(path)
        guard var list = map[identity], let index = list.firstIndex(of: value) else { return }
        list.remove(at: index)
        if list.isEmpty { map.removeValue(forKey: identity) } else { map[identity] = list }
        save()
    }

    func toggle(_ path: String, for identity: String) {
        if isBookmarked(path, for: identity) {
            remove(path, for: identity)
        } else {
            add(path, for: identity)
        }
    }

    // MARK: 持久化

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else { return }
        map = decoded
    }

    private func save() {
        let dir = AppSettings.shared.dataDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(map) {
            try? data.write(to: fileURL, options: [.atomic])
        }
        observers.values.forEach { $0() }
    }
}

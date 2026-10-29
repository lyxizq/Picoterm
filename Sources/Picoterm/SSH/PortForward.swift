import Foundation

// 端口转发规则与存储（Ported from Termind (GPL-3) PortForwardingRule 的字段口径
// — github.com/AkinoKaede/Termind；本地 -L 转发 + 多连接并行）。
// remote（-R）/dynamic（SOCKS5）为后续批次，字段已预留 kind。

struct PortForwardRule: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case local   // -L：本地监听 → 经 SSH → 远端目标
        // case remote, dynamic —— 后续批次
    }

    var id = UUID()
    /// 绑定的主机条目（SSH 连接走它的凭据/跳板配置）
    var hostEntryId: UUID
    var label: String = ""
    /// 本地监听地址（默认仅回环；0.0.0.0 对外开放由用户自担）
    var bindHost: String = "127.0.0.1"
    var bindPort: Int = 8080
    /// 远端目标（从 SSH 服务器视角访问）
    var targetHost: String = "127.0.0.1"
    var targetPort: Int = 80
    /// 并行 SSH 连接数（Termind 多连接口径：吞吐近线性提升，默认 1、上限 12）
    var parallelConnections: Int = 1
    var enabled: Bool = true

    var summary: String { "\(bindHost):\(bindPort) → \(targetHost):\(targetPort)（×\(max(1, min(12, parallelConnections)))）" }

    var isValid: Bool {
        (1...65_535).contains(bindPort) && (1...65_535).contains(targetPort)
            && !targetHost.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// 规则存储：数据目录 forwards.json（HostStore 同款观察者模式）

final class PortForwardStore {
    static let shared = PortForwardStore()

    private(set) var rules: [PortForwardRule] = []
    private var observers: [UUID: () -> Void] = [:]

    @discardableResult
    func observe(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    private func notifyChanged() {
        observers.values.forEach { $0() }
    }

    private var fileURL: URL {
        AppSettings.shared.dataDir.appendingPathComponent("forwards.json")
    }

    func load() {
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([PortForwardRule].self, from: data) {
            rules = list
        }
        notifyChanged()
    }

    func save() {
        if let data = try? JSONEncoder().encode(rules) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func upsert(_ rule: PortForwardRule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        save()
        notifyChanged()
    }

    func delete(id: UUID) {
        rules.removeAll { $0.id == id }
        save()
        notifyChanged()
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].enabled = enabled
        save()
        notifyChanged()
    }
}

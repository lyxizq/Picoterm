import Foundation
import CryptoKit
import PicotermCore

// MARK: - 主机配置模型（分组 + 连接；密码/口令 AES-GCM 加密存 secrets.json，2026-10-21 起弃用 Keychain）

struct HostGroup: Codable, Equatable {
    var id: UUID = UUID()
    var name: String

    enum CodingKeys: String, CodingKey { case id, name }
}

struct HostEntry: Codable, Equatable {
    var id: UUID = UUID()
    var groupId: UUID
    var label: String        // 标签（树里显示的名字）
    var host: String
    var port: UInt16 = 22
    var user: String
    var authKind: String = "password"   // password | key | agent
    var keyPath: String = ""
    var terminal: String = "xterm-256color"
    /// RemoteCharset 展示名（"UTF-8"/"GB18030"…）；历史上是自由文本，读取经 RemoteCharset(hostValue:) 归一
    var charset: String = "UTF-8"
    var notes: String = ""
    /// 连接协议（Termind 同款三协议）：ssh | telnet | serial
    var proto: String = "ssh"
    /// 串口设备路径（/dev/tty.usbserial-*；proto=serial 用）
    var serialDevice: String = ""
    /// 串口波特率（proto=serial 用）
    var serialBaud: Int = 115200
    /// Wake-on-LAN：网卡 MAC（"AA:BB:CC:DD:EE:FF"）；空 = 不启用
    var wolMac: String = ""
    /// 连接前先发 WoL 魔术包
    var wakeBeforeConnect: Bool = false
    /// 颜色标记（TabColors 预设 tag：blue/green/orange/purple/red/yellow；空 = 无）——标签底部色条 + 树图标染色
    var colorTag: String = ""

    init(groupId: UUID) {
        id = UUID()
        self.groupId = groupId
        label = ""
        host = ""
        port = 22
        user = "root"
        authKind = "password"
        keyPath = ""
        terminal = "xterm-256color"
        charset = "UTF-8"
        notes = ""
        proto = "ssh"
        serialDevice = ""
        serialBaud = 115200
        wolMac = ""
        wakeBeforeConnect = false
        colorTag = ""
    }

    enum CodingKeys: String, CodingKey {
        case id, groupId, label, host, port, user, authKind, keyPath, terminal, charset, notes
        case proto, serialDevice, serialBaud
        case wolMac, wakeBeforeConnect
        case colorTag
    }

    // 全字段 decodeIfPresent：新增字段在旧 hosts.json 里缺失时兜底默认值
    // （合成 Codable 遇缺键直接抛错，load() 会整库回退成空列表——数据事故）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        groupId = try c.decode(UUID.self, forKey: .groupId)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 22
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? "root"
        authKind = try c.decodeIfPresent(String.self, forKey: .authKind) ?? "password"
        keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath) ?? ""
        terminal = try c.decodeIfPresent(String.self, forKey: .terminal) ?? "xterm-256color"
        charset = try c.decodeIfPresent(String.self, forKey: .charset) ?? "UTF-8"
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        proto = try c.decodeIfPresent(String.self, forKey: .proto) ?? "ssh"
        serialDevice = try c.decodeIfPresent(String.self, forKey: .serialDevice) ?? ""
        serialBaud = try c.decodeIfPresent(Int.self, forKey: .serialBaud) ?? 115200
        wolMac = try c.decodeIfPresent(String.self, forKey: .wolMac) ?? ""
        wakeBeforeConnect = try c.decodeIfPresent(Bool.self, forKey: .wakeBeforeConnect) ?? false
        colorTag = try c.decodeIfPresent(String.self, forKey: .colorTag) ?? ""
    }
}

// MARK: - 凭据加密仓库（AES-GCM；密钥为本机数据目录内随机 256 位密钥文件，0600）

enum SecretVault {
    private static var keyURL: URL {
        AppSettings.shared.dataDir.appendingPathComponent(".secret.key")
    }

    static var vaultURL: URL {
        AppSettings.shared.dataDir.appendingPathComponent("secrets.json")
    }

    private static func key() throws -> SymmetricKey {
        if let data = try? Data(contentsOf: keyURL), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try data.write(to: keyURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return key
    }

    static func load() -> [String: String] {
        guard let blob = try? Data(contentsOf: vaultURL),
              let sealed = try? AES.GCM.SealedBox(combined: blob),
              let opened = try? AES.GCM.open(sealed, using: key()),
              let map = try? JSONDecoder().decode([String: String].self, from: opened) else { return [:] }
        return map
    }

    static func store(_ map: [String: String]) {
        guard let key = try? key(),
              let data = try? JSONEncoder().encode(map),
              let sealed = try? AES.GCM.seal(data, using: key).combined else { return }
        try? sealed.write(to: vaultURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vaultURL.path)
    }
}

// MARK: - 主机存储：数据目录下 hosts.json

final class HostStore {
    static let shared = HostStore()

    private(set) var groups: [HostGroup] = []
    private(set) var hosts: [HostEntry] = []
    /// 树结构变化（增删改/重载）——多播观察者（单播闭包会被多方注册互相覆盖）
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

    private var fileURL: URL { AppSettings.shared.dataDir.appendingPathComponent("hosts.json") }

    func load() {
        let dir = AppSettings.shared.dataDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let store = try? JSONDecoder().decode(StoreFile.self, from: data) {
            groups = store.groups
            hosts = store.connections
        } else {
            groups = [HostGroup(name: "Home")]
            hosts = []
            save()
        }
        notifyChanged()
    }

    func reload() { load() }

    func save() {
        let store = StoreFile(groups: groups, connections: hosts)
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private struct StoreFile: Codable {
        var groups: [HostGroup]
        var connections: [HostEntry]
    }

    // MARK: 分组

    @discardableResult
    func addGroup(named name: String) -> HostGroup {
        let group = HostGroup(name: name)
        groups.append(group)
        save()
        notifyChanged()
        return group
    }

    func renameGroup(id: UUID, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = name
        save()
        notifyChanged()
    }

    /// 删除分组连同其下所有连接（UI 层负责确认）
    func deleteGroup(id: UUID) {
        hosts.filter { $0.groupId == id }.forEach { deleteHost(id: $0.id, notify: false) }
        groups.removeAll { $0.id == id }
        save()
        notifyChanged()
    }

    func groupName(for id: UUID) -> String {
        groups.first { $0.id == id }?.name ?? L("未分组")
    }

    func hosts(in group: HostGroup) -> [HostEntry] {
        hosts.filter { $0.groupId == group.id }
    }

    // MARK: 连接

    func addHost(_ entry: HostEntry) {
        hosts.append(entry)
        save()
        notifyChanged()
    }

    func updateHost(_ entry: HostEntry) {
        guard let index = hosts.firstIndex(where: { $0.id == entry.id }) else { return }
        hosts[index] = entry
        save()
        notifyChanged()
    }

    func deleteHost(id: UUID, notify: Bool = true) {
        hosts.removeAll { $0.id == id }
        setSecret(nil, for: id)
        save()
        if notify { notifyChanged() }
    }

    /// 拖拽移动主机到分组；index = 目标分组内插入位置（nil = 追加组尾，越界夹到组尾）
    func moveHost(id: UUID, toGroup groupId: UUID, index: Int? = nil) {
        guard let source = hosts.firstIndex(where: { $0.id == id }),
              groups.contains(where: { $0.id == groupId }) else { return }
        var entry = hosts.remove(at: source)
        entry.groupId = groupId
        // 扁平数组里定位该分组的成员位置：插到第 index 个成员前，没插进头部就贴组尾
        let positions = hosts.indices.filter { hosts[$0].groupId == groupId }
        if let index, index < positions.count {
            hosts.insert(entry, at: positions[max(0, index)])
        } else if let last = positions.last {
            hosts.insert(entry, at: hosts.index(after: last))
        } else {
            hosts.append(entry)
        }
        save()
        notifyChanged()
    }

    // MARK: 凭据（secrets.json，AES-GCM 加密；密钥文件 .secret.key 0600）

    func secret(for id: UUID) -> String? {
        var map = SecretVault.load()
        if map.isEmpty, let data = try? Data(contentsOf: SecretVault.vaultURL),
           let plain = try? JSONDecoder().decode([String: String].self, from: data) {
            // 旧版明文文件：自动迁移为加密存储
            map = plain
            try? FileManager.default.removeItem(at: SecretVault.vaultURL)
            SecretVault.store(map)
        }
        return map[id.uuidString]
    }

    func setSecret(_ secret: String?, for id: UUID) {
        var map = SecretVault.load()
        if let secret, !secret.isEmpty {
            map[id.uuidString] = secret
        } else {
            map.removeValue(forKey: id.uuidString)
        }
        SecretVault.store(map)
    }

    /// 组装 SSH 连接配置；密码/口令缺失时返回 nil 由 UI 层提示补录
    func sshConfig(for entry: HostEntry) -> (config: SSHConfig, needsSecret: Bool) {
        let auth: SSHConfig.Auth
        var needsSecret = false
        switch entry.authKind {
        case "key":
            auth = .key(path: entry.keyPath, passphrase: secret(for: entry.id) ?? "")
        case "agent":
            auth = .agent
        default:
            let password = secret(for: entry.id)
            if password == nil { needsSecret = true }
            auth = .password(password ?? "")
        }
        return (SSHConfig(host: entry.host, port: entry.port, user: entry.user, auth: auth,
                          charset: RemoteCharset(hostValue: entry.charset) ?? .utf8,
                          terminalType: entry.terminal,
                          wolMac: entry.wolMac, wakeBeforeConnect: entry.wakeBeforeConnect),
                needsSecret)
    }

    // MARK: 会话恢复状态（state.json：本地 Shell 数量 + 打开中的 SSH 主机 id）

    func saveRestoreState(locals: Int, sshIds: [UUID]) {
        let obj: [String: Any] = ["locals": locals, "ssh": sshIds.map(\.uuidString)]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? data.write(to: AppSettings.shared.dataDir.appendingPathComponent("state.json"),
                            options: .atomic)
        }
    }

    func readRestoreState() -> (locals: Int, sshIds: [UUID]) {
        guard let data = try? Data(contentsOf: AppSettings.shared.dataDir.appendingPathComponent("state.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (0, [])
        }
        let locals = obj["locals"] as? Int ?? 0
        let ids = (obj["ssh"] as? [String] ?? []).compactMap { UUID(uuidString: $0) }
        return (locals, ids)
    }
}

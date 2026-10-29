import AppKit
import SwiftTerm
import PicotermCore

// MARK: - 会话抽象（TODO 2 起步：本地 Shell；TODO 3 扩展 SSH 会话）

enum SessionState {
    case running
    case exited
}

extension Notification.Name {
    /// 终端尺寸变化（object = 会话）；状态栏窗口尺寸 chip 实时刷新用
    static let terminalSizeChanged = Notification.Name("picoterm.terminalSizeChanged")
}

@MainActor
protocol TerminalSession: AnyObject {
    var id: UUID { get }
    var title: String { get }
    var symbol: String { get }
    var state: SessionState { get }
    /// 当前终端网格尺寸（sizeChanged 时更新；状态栏展示用）
    var terminalSize: (cols: Int, rows: Int)? { get }
    /// 该会话的终端视图（保持存活以保留回滚缓冲，切换时在容器间搬移）
    var terminalView: NSView { get }
    var onStateChanged: (() -> Void)? { get set }
    func terminate()
    /// 同步输入：把键盘字节注入该会话（广播模式用）
    func injectInput(_ bytes: [UInt8])
}

// MARK: - 本地 Shell 会话（PTY 由 SwiftTerm 的 LocalProcessTerminalView 托管）

/// 本地 Shell 终端视图：接管链接点击（SwiftTerm 自带的 openLink 会把任意 scheme 交给系统），
/// 走统一的 LinkOpenPolicy——网页交系统，本机路径在 Finder 中显示（不直接用默认应用打开，防误执行脚本）
final class LocalShellTerminalView: LocalProcessTerminalView {
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        switch LinkOpenPolicy.classify(link, isRemote: false, currentDirectory: shellCurrentDirectory(), home: home) {
        case .web(let url):
            NSWorkspace.shared.open(url)
        case .localFile(let url):
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .remotePath, .rejected:
            break
        }
    }

    /// shell 进程的 cwd（proc_pidinfo 只读，不向 shell 键入任何内容）；前台命令另有 cwd 时以 shell 为准
    private func shellCurrentDirectory() -> String? {
        guard let pid = process?.shellPid, pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}

@MainActor
final class LocalShellSession: NSObject, TerminalSession, LocalProcessTerminalViewDelegate {
    let id = UUID()
    var onStateChanged: (() -> Void)?
    private(set) var state: SessionState = .running
    private(set) var terminalSize: (cols: Int, rows: Int)?
    private let tv: LocalShellTerminalView

    override init() {
        tv = LocalShellTerminalView(frame: .zero)
        super.init()
        AppTheme.apply(to: tv)
        tv.processDelegate = self
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        tv.startProcess(executable: shell, args: ["-l"])
    }

    var title: String { state == .exited ? L("本地 Shell（已退出）") : L("本地 Shell") }
    var symbol: String { "terminal.fill" }
    var terminalView: NSView { tv }

    func terminate() {
        guard state == .running else { return }
        tv.process?.terminate()
    }

    func injectInput(_ bytes: [UInt8]) {
        guard state == .running else { return }
        tv.process?.send(data: bytes[...])
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        tv.applyScrollbackSetting() // Terminal 已创建（首次 sizeChanged 兜底），TODO 74
        terminalSize = (newCols, newRows)
        NotificationCenter.default.post(name: .terminalSizeChanged, object: self)
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard state == .running else { return }
        state = .exited
        onStateChanged?()
    }
}

// MARK: - 会话管理器（单例；标签栏/终端容器/状态栏都从它取真值）

@MainActor
final class SessionManager {
    static let shared = SessionManager()

    private init() {
        // 主机条目改了颜色/标签后，已开标签的色条与标题要跟着刷（标签栏只监听会话变化）
        HostStore.shared.observe { [weak self] in self?.notifySessions() }
    }

    private(set) var sessions: [TerminalSession] = []
    private(set) var selected: TerminalSession?
    /// 多播观察者：会话列表/状态变化、选中变化
    private var sessionsObservers: [UUID: () -> Void] = [:]
    private var selectedObservers: [UUID: () -> Void] = [:]

    @discardableResult
    func observeSessions(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        sessionsObservers[token] = observer
        return token
    }

    @discardableResult
    func observeSelected(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        selectedObservers[token] = observer
        return token
    }

    func removeObserver(_ token: UUID) {
        sessionsObservers.removeValue(forKey: token)
        selectedObservers.removeValue(forKey: token)
    }

    // MARK: 同步输入（TODO 13）：开启后把 SSH 会话的键盘输入广播到其余会话

    var broadcastInputEnabled = false

    func broadcastInput(from source: TerminalSession, bytes: [UInt8]) {
        guard broadcastInputEnabled, sessions.count > 1 else { return }
        for session in sessions where session.id != source.id {
            session.injectInput(bytes)
        }
    }

    /// 外观变化后套到所有打开的终端
    func applyAppearanceToAll() {
        for session in sessions {
            if let tv = session.terminalView as? TerminalView {
                AppTheme.apply(to: tv)
            }
        }
    }

    private func notifySessions() { sessionsObservers.values.forEach { $0() } }
    private func notifySelected() { selectedObservers.values.forEach { $0() } }

    func createLocalShell() {
        register(LocalShellSession())
    }

    func createSSHSession(config: SSHConfig, hostEntryId: UUID? = nil) {
        register(SSHSession(config: config, hostEntryId: hostEntryId))
    }

    /// 统一连接入口（Termind 三协议口径）：按主机条目的 proto 分发到 SSH/Telnet/串口会话
    func createSession(for entry: HostEntry) {
        let session: TerminalSession
        switch entry.proto {
        case "telnet":
            session = TelnetSession(endpoint: .init(
                host: entry.host,
                port: entry.port == 22 ? 23 : entry.port,
                charset: RemoteCharset(hostValue: entry.charset) ?? .utf8))
        case "serial":
            session = SerialSession(devicePath: entry.serialDevice,
                                    baudRate: entry.serialBaud,
                                    charset: RemoteCharset(hostValue: entry.charset) ?? .utf8)
        default:
            let (config, needsSecret) = HostStore.shared.sshConfig(for: entry)
            guard !needsSecret else { return }
            session = SSHSession(config: config, hostEntryId: entry.id)
        }
        hostIdBySession[session.id] = entry.id
        register(session)
    }

    private func register(_ session: TerminalSession) {
        sessions.append(session)
        if hostIdBySession[session.id] == nil, let ssh = session as? SSHSession, let hostId = ssh.hostEntryId {
            hostIdBySession[session.id] = hostId
        }
        session.onStateChanged = { [weak self] in
            self?.notifySessions()
            self?.persistRestoreState()
        }
        select(session)
        notifySessions()
        persistRestoreState()
    }

    // MARK: 标签颜色 / 自定义标题（2026-10-26 用户指定；内存态，随会话消亡）

    /// 会话 → 主机条目（SSH/Telnet/串口经 createSession(for:) 建立的都记录；本地 Shell 无）
    private var hostIdBySession: [UUID: UUID] = [:]
    /// 标签右键手动设置的颜色（优先于主机条目颜色；本地 Shell 只能存这里）
    private var colorTagBySession: [UUID: String] = [:]
    private var customTitleBySession: [UUID: String] = [:]

    func hostEntryId(for session: TerminalSession) -> UUID? { hostIdBySession[session.id] }

    func hostEntry(for session: TerminalSession) -> HostEntry? {
        guard let id = hostIdBySession[session.id] else { return nil }
        return HostStore.shared.hosts.first { $0.id == id }
    }

    /// 标签显示色：手动设置 > 主机条目 colorTag > 无
    func colorTag(for session: TerminalSession) -> String {
        if let tag = colorTagBySession[session.id] { return tag }
        return hostEntry(for: session)?.colorTag ?? ""
    }

    /// 设色：有主机条目的会话写回条目持久化（树与同主机其他标签一起变色），本地 Shell 只留内存
    func setColorTag(_ tag: String, for session: TerminalSession) {
        if var entry = hostEntry(for: session) {
            entry.colorTag = tag
            HostStore.shared.updateHost(entry)
            colorTagBySession.removeValue(forKey: session.id)
        } else {
            colorTagBySession[session.id] = tag
        }
        notifySessions()
    }

    /// 标签显示标题：自定义标题保留「（已断开）」后缀语义
    func displayTitle(for session: TerminalSession) -> String {
        guard let custom = customTitleBySession[session.id] else { return session.title }
        return session.state == .running ? custom : custom + L("（已断开）")
    }

    func customTitle(for session: TerminalSession) -> String? { customTitleBySession[session.id] }

    /// 空串 = 恢复默认标题
    func setCustomTitle(_ title: String?, for session: TerminalSession) {
        let trimmed = title?.trimmingCharacters(in: .whitespaces) ?? ""
        if trimmed.isEmpty {
            customTitleBySession.removeValue(forKey: session.id)
        } else {
            customTitleBySession[session.id] = trimmed
        }
        notifySessions()
    }

    // MARK: 会话恢复（TODO 9）：会话集合变化时把当前状态交给持久层

    /// 由 UI 层注入：写 state 文件
    var restoreStatePersister: ((_ locals: Int, _ sshIds: [UUID]) -> Void)?

    private func persistRestoreState() {
        let locals = sessions.filter { $0 is LocalShellSession }.count
        let sshIds = sessions.compactMap { ($0 as? SSHSession)?.hostEntryId }
        restoreStatePersister?(locals, sshIds)
    }

    func select(_ session: TerminalSession) {
        guard selected !== session else { return }
        selected = session
        notifySelected()
        notifySessions()
    }

    /// 拖拽标签重排：按给定 id 顺序重排 sessions（id 集合必须与现有完全一致才生效）
    func reorderSessions(byIds ids: [UUID]) {
        guard ids.count == sessions.count, Set(ids) == Set(sessions.map(\.id)) else { return }
        let byId = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        sessions = ids.compactMap { byId[$0] }
        notifySessions()
    }

    func close(_ session: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions.remove(at: index)
        session.terminate()
        hostIdBySession.removeValue(forKey: session.id)
        colorTagBySession.removeValue(forKey: session.id)
        customTitleBySession.removeValue(forKey: session.id)
        // SSH 会话关闭后同步断开对应文件管理器（TODO 69）：同主机仍有其他存活会话则保持
        if let ssh = session as? SSHSession {
            let remaining = Set(sessions.compactMap { ($0 as? SSHSession)?.config.connectionIdentity })
            SFTPService.shared.disconnectForClosedSession(config: ssh.config, remainingIdentities: remaining)
        }
        if selected?.id == session.id {
            selected = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)]
            notifySelected()
        }
        notifySessions()
        persistRestoreState()
    }
}

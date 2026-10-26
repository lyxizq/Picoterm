import Foundation
import AppKit
import UniformTypeIdentifiers
import PicotermCore

// SFTP 服务：每台主机一条独立 SSH 连接专跑 SFTP（不与终端会话抢占 libssh2 会话）
// 所有 C 调用串行在内部队列上执行
final class SFTPService {
    static let shared = SFTPService()

    struct Entry {
        let name: String
        let isDir: Bool
        let size: UInt64
        let mtime: UInt64
        let permText: String  // 八进制权限，如 755
        let owner: String     // 属主名（解析不到时为 uid 数字）
    }

    private let queue = DispatchQueue(label: "picoterm.sftp.service", qos: .userInitiated)
    private var client: SSHClient?
    private var sftp: OpaquePointer?
    private var lastConfig: SSHConfig?
    private var keepaliveTimer: DispatchSourceTimer?
    private(set) var path = "/"
    private(set) var entries: [Entry] = []
    private(set) var connectedTo: String?
    /// 远端 home（realpath "."），终端标题里的 "~" 展开用（TODO 71）
    private(set) var homePath: String?
    /// uid → 用户名（连接时解析一次 /etc/passwd；列表权限列显示用）
    private var ownerNames: [UInt32: String] = [:]
    private(set) var statusText = L("未连接（连接 SSH 主机后自动打开）")
    // 目录历史（Finder 式前进/后退）
    private var history: [String] = []
    private var historyIndex = -1
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// 列表/路径变化
    var onChanged: (() -> Void)?
    /// 状态提示（footer 展示）
    var onStatus: ((String) -> Void)?

    private func notify() { MainThread.perform { [weak self] in self?.onChanged?() } }
    private func note(_ text: String) {
        MainThread.perform { [weak self] in
            self?.statusText = text
            self?.onStatus?(text)
        }
    }

    /// 选中 SSH 会话时调用；同主机已连接则跳过
    func connectIfNeeded(config: SSHConfig) {
        queue.async { [self] in
            let identity = config.connectionIdentity
            guard connectedTo != identity || sftp == nil else { return }
            lastConfig = config
            disconnectInternal()
            do {
                let c = try Self.makeConnectedClient(config: config)
                let s = try c.sftpInit()
                client = c
                sftp = s
                connectedTo = identity
                startKeepalive()
                let home = c.sftpRealpath(s, path: ".")
                homePath = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
                ownerNames = Self.loadOwnerNames(client: c)
                try listInternal(sftp: s, path: home.hasSuffix("/") ? home : home + "/")
                note(L("%@ 已连接", identity))
            } catch {
                client?.close()
                client?.teardown()
                client = nil
                sftp = nil
                connectedTo = nil
                note(L("SFTP 连接失败：%@", (error as? SSHClientError)?.description ?? "\(error)"))
            }
        }
    }

    /// 解析远端 uid→用户名（getent 优先，无 NSS 的系统退回 /etc/passwd）
    private static func loadOwnerNames(client: SSHClient) -> [UInt32: String] {
        let cmd = "getent passwd 2>/dev/null || cat /etc/passwd 2>/dev/null"
        guard let output = (try? client.exec(cmd))?.output else { return [:] }
        var map: [UInt32: String] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count >= 3, let uid = UInt32(fields[2]) else { continue }
            map[uid] = String(fields[0])
        }
        return map
    }

    /// 读取条目属性（含权限/属主；属主名经远端 id 命令解析，失败回退空串）
    func stat(fullPath: String, completion: @escaping (SSHClient.SFTPStat?, String, String) -> Void) {
        queue.async { [self] in
            guard let client, let sftp else {
                MainThread.perform { completion(nil, "", "") }
                return
            }
            let stat = try? client.sftpStat(sftp, path: fullPath)
            var owner = "", group = ""
            if let stat {
                let cmd = "id -nu \(stat.uid) 2>/dev/null; id -ng \(stat.gid) 2>/dev/null"
                let lines = (try? client.exec(cmd))?.output.split(separator: "\n").map(String.init) ?? []
                owner = lines.first ?? ""
                group = lines.count > 1 ? lines[1] : ""
            }
            MainThread.perform { completion(stat, owner, group) }
        }
    }

    /// 文件预览（Termind「预览」口径）：读文件头部到内存回调主线程。
    /// 文本取前 256KB、图片完整读但上限 8MB（防内存爆）；目录/超大文件由调用方拦截
    enum PreviewPayload {
        case text(TextPreviewAssembler.Result)
        case image(Data)
        case tooLarge
    }

    /// 文本：≤ 512KB 整读；更大读前 256KB + 后 256KB（TextPreviewAssembler 拼接，不限文件大小）；图片：≤ 8MB 整读
    private static let imagePreviewLimit = 8 * 1024 * 1024

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "heic", "svg"]

    static func isPreviewableImage(name: String) -> Bool {
        imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    func preview(entry: Entry, completion: @escaping (PreviewPayload?) -> Void) {
        queue.async { [self] in
            guard let client, let sftp else {
                MainThread.perform { completion(nil) }
                return
            }
            let remote = path + entry.name
            do {
                let payload: PreviewPayload?
                if Self.isPreviewableImage(name: entry.name) {
                    guard entry.size <= UInt64(Self.imagePreviewLimit) else {
                        MainThread.perform { completion(.tooLarge) }
                        return
                    }
                    let (data, _) = try client.sftpReadPrefix(sftp, path: remote, maxBytes: Self.imagePreviewLimit)
                    payload = .image(data)
                } else {
                    // 追加中的日志列表里的 size 可能已过时：读尾部前重新 stat
                    let size = (try? client.sftpStat(sftp, path: remote))?.size ?? entry.size
                    let segment = TextPreviewAssembler.segmentBytes
                    if size <= UInt64(2 * segment) {
                        let (data, _) = try client.sftpReadPrefix(sftp, path: remote, maxBytes: 2 * segment)
                        payload = TextPreviewAssembler.assemble(head: data, tail: nil, totalSize: UInt64(data.count)).map { .text($0) }
                    } else {
                        let (head, _) = try client.sftpReadPrefix(sftp, path: remote, maxBytes: segment)
                        var tail = Data(capacity: segment)
                        try client.sftpReadRange(sftp, path: remote, offset: size - UInt64(segment), length: UInt64(segment)) { buffer, count in
                            if let base = buffer.baseAddress { tail.append(base, count: count) }
                        }
                        payload = TextPreviewAssembler.assemble(head: head, tail: tail, totalSize: size).map { .text($0) }
                    }
                }
                MainThread.perform { completion(payload) }
            } catch {
                MainThread.perform { completion(nil) }
            }
        }
    }

    /// 修改权限（chmod 八进制；成功后刷新列表）
    func chmod(fullPath: String, octal: String, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            guard let client else {
                MainThread.perform { completion(false) }
                return
            }
            let quoted = "'" + fullPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let result = try? client.exec("chmod \(octal) -- \(quoted)")
            let ok = (result?.code ?? 1) == 0
            if ok { MainThread.perform { self.refresh() } }
            MainThread.perform { completion(ok) }
        }
    }

    /// 移动条目到目标目录（mv -n：不覆盖已存在同名；成功后刷新列表）
    func move(entry: Entry, toDirectory dir: String, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            guard let client else {
                MainThread.perform { completion(false) }
                return
            }
            func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let source = q(path + entry.name)
            let target = q(dir.hasSuffix("/") ? dir : dir + "/")
            let result = try? client.exec("mv -n -- \(source) \(target)")
            var ok = (result?.code ?? 1) == 0
            if ok { // mv -n 跳过同名时退出码也是 0：确认源已不在才算成功
                let check = try? client.exec("test -e \(source) && echo EXISTS")
                ok = !(check?.output.contains("EXISTS") ?? true)
            }
            if ok { MainThread.perform { self.refresh() } }
            MainThread.perform { completion(ok) }
        }
    }

    /// SSH 会话关闭后同步断开对应文件管理器连接（TODO 69）：
    /// 仅当 SFTP 正连着该主机、且没有其余存活的 SSH 会话还指向同一主机时才断开
    func disconnectForClosedSession(config: SSHConfig, remainingIdentities: Set<String>) {
        queue.async { [self] in
            let identity = config.connectionIdentity
            guard connectedTo == identity, !remainingIdentities.contains(identity) else { return }
            disconnectInternal()
            note(L("未连接（SSH 会话已关闭）"))
            notify()
        }
    }

    /// 连接 + 认证（SFTP 专用连接：不开闲置 session 通道；密码直连被拒时同款交互式回退）。
    /// 静态以便 TransferRunner 复用同一套认证口径
    static func makeConnectedClient(config: SSHConfig) throws -> SSHClient {
        let c = SSHClient()
        do {
            try c.connect(config: config, withSessionChannel: false)
        } catch SSHClientError.authFailed {
            guard case .password(let stored) = config.auth, !stored.isEmpty else {
                throw SSHClientError.authFailed(message: L("认证失败"))
            }
            var patched = config
            patched.auth = .keyboardInteractive(password: stored) { _ in nil }
            try c.connect(config: patched, withSessionChannel: false)
        }
        return c
    }

    /// SFTP 连接无事件循环：独立定时器在同一条串行队列上发 keepalive（防服务端回收闲置通道）
    private func startKeepalive() {
        guard keepaliveTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self, let client = self.client else { return }
            client.sendKeepalive()
        }
        timer.resume()
        keepaliveTimer = timer
    }

    func list(_ newPath: String) {
        queue.async { [self] in
            guard let sftp else { return }
            do {
                try listInternal(sftp: sftp, path: newPath)
            } catch {
                note(L("读取目录失败：%@", (error as? SSHClientError)?.description ?? "\(error)"))
            }
        }
    }

    func goBack() {
        queue.async { [self] in
            guard canGoBack, let sftp else { return }
            historyIndex -= 1
            do {
                try listInternal(sftp: sftp, path: history[historyIndex], push: false)
            } catch {
                historyIndex += 1
                note(L("读取目录失败：%@", (error as? SSHClientError)?.description ?? "\(error)"))
            }
        }
    }

    func goForward() {
        queue.async { [self] in
            guard canGoForward, let sftp else { return }
            historyIndex += 1
            do {
                try listInternal(sftp: sftp, path: history[historyIndex], push: false)
            } catch {
                historyIndex -= 1
                note(L("读取目录失败：%@", (error as? SSHClientError)?.description ?? "\(error)"))
            }
        }
    }

    func refresh() { list(path) }

    // MARK: 终端链接点击的路径跳转（2026-10-26 用户指定）

    /// 跳转后待高亮的文件名（文件路径 → 进其父目录并选中该文件）；面板 reload 时取走
    private var pendingRevealName: String?

    func takePendingRevealName() -> String? {
        defer { pendingRevealName = nil }
        return pendingRevealName
    }

    /// ⌘点击终端里的远端路径：目录直接进入，文件进父目录并高亮；不存在的路径只在状态栏提示
    func reveal(path: String) {
        queue.async { [self] in
            guard let client, let sftp, connectedTo != nil else { return }
            guard let stat = try? client.sftpStat(sftp, path: path) else {
                note(L("路径不存在：%@", path))
                return
            }
            let isDir = (stat.permissions & 0o170000) == 0o040000
            let target = isDir ? path : (path as NSString).deletingLastPathComponent
            pendingRevealName = isDir ? nil : (path as NSString).lastPathComponent
            do {
                try listInternal(sftp: sftp, path: target.isEmpty ? "/" : target)
            } catch {
                pendingRevealName = nil
                note(L("读取目录失败：%@", (error as? SSHClientError)?.description ?? "\(error)"))
            }
        }
    }

    private var lastFollowedPath: String?

    /// 终端目录同步（OSC 7）：跟随选中会话的当前目录；未连接或路径未变时忽略
    func followTerminal(_ newPath: String) {
        guard connectedTo != nil, newPath.hasPrefix("/"),
              newPath != path, newPath != lastFollowedPath else { return }
        DebugLog.write("followTerminal \(newPath)")
        lastFollowedPath = newPath
        list(newPath)
    }

    /// 终端 cwd 只读探测（TODO 71；设计 Ported from Berth (GPL-3) TerminalSession.probeRemoteWorkingDirectories
    /// — github.com/xinghelee/Berth）：服务器既不发 OSC 7 也不写标题时的兜底。
    /// Berth 在同一条连接上另开 exec 通道、从 $$ 向上找 sshd；本工程终端连接被事件循环独占，
    /// 改在 SFTP 独立连接上执行，并按**客户端源端口**（ss -tnp 的 Peer 列）定位终端会话的
    /// sshd 子进程，再枚举其带 TTY 的子进程（即该 PTY 的 shell）readlink /proc/<pid>/cwd。
    /// 只读、不向用户终端键入任何内容；无 ss / /proc 的远端静默返回 nil。
    func probeTerminalDirectory(clientPort: UInt16, completion: @escaping (String?) -> Void) {
        guard clientPort > 0 else { completion(nil); return }
        queue.async { [self] in
            guard let client, connectedTo != nil else {
                MainThread.perform { completion(nil) }
                return
            }
            let script = """
            pid=$(ss -Htnp 2>/dev/null | awk -v p=":\(clientPort)" '$1=="ESTAB" && substr($5, length($5)-length(p)+1)==p && $6 ~ /sshd/ { if (match($6, /pid=[0-9]+/)) { print substr($6, RSTART+4, RLENGTH-4); exit } }')
            [ -n "$pid" ] || exit 0
            ps -A -o pid= -o ppid= -o tty= 2>/dev/null | while read cpid cppid ctty; do
              [ "$cppid" = "$pid" ] || continue
              case "$ctty" in ""|"?"|"??") continue ;; esac
              readlink "/proc/$cpid/cwd" 2>/dev/null && exit 0
            done
            exit 0
            """
            let quoted = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let result = try? client.exec("sh -c \(quoted)")
            let cwd = result?.output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("/") }
            MainThread.perform { completion(cwd) }
        }
    }

    private func listInternal(sftp: OpaquePointer, path newPath: String, push: Bool = true) throws {
        do {
            try performList(sftp: sftp, path: newPath, push: push)
        } catch let error as SSHClientError {
            switch error {
            case .channelFailed, .sftpProtocol:
                // 通道失效或服务器 SFTP 层拒绝（UDM 等嵌入式设备偶发）：恢复通道后重试一次
                try recoverSftp()
                guard let fresh = self.sftp else { throw SSHClientError.disconnectedForSftp }
                do {
                    try performList(sftp: fresh, path: newPath, push: push)
                } catch SSHClientError.sftpProtocol(let status) where status == 2 {
                    // 直拼路径打不开但目录实际可达（符号链接/别名/尾斜杠兼容，如 /boot）：
                    // realpath 解析真实路径后重试
                    let resolved = client?.sftpRealpath(fresh, path: newPath) ?? ""
                    if resolved.hasPrefix("/"), resolved != newPath {
                        try performList(sftp: fresh, path: resolved, push: push)
                    } else {
                        note(L("读取目录失败（%@）：文件或目录不存在", newPath))
                    }
                }
            default:
                throw error
            }
        }
    }

    private func performList(sftp: OpaquePointer, path newPath: String, push: Bool) throws {
        let listed = try client?.sftpList(sftp, path: newPath) ?? []
        // 存储路径统一带尾斜杠，后续拼子路径/面包屑都依赖它
        let canonical = newPath.hasSuffix("/") ? newPath : newPath + "/"
        path = canonical
        // 点开头为隐藏文件，列表不展示（TODO 75）；地址栏直接输入隐藏目录仍可进入
        entries = listed
            .filter { !$0.name.hasPrefix(".") }
            .map { entry in
                Entry(name: entry.name, isDir: entry.isDir, size: entry.size, mtime: entry.mtime,
                      permText: String(format: "%o", entry.permissions & 0o7777),
                      owner: ownerNames[entry.uid] ?? String(entry.uid))
            }
        if push, history.last != canonical {
            while historyIndex < history.count - 1 { history.removeLast() }
            history.append(canonical)
            historyIndex = history.count - 1
        }
        canGoBack = historyIndex > 0
        canGoForward = historyIndex < history.count - 1
        notify()
    }

    /// SFTP 通道失效恢复：先同连接重开子系统，不行则整条重连（认证沿用存储凭据）
    private func recoverSftp() throws {
        if let sftp { client?.sftpShutdown(sftp) }
        self.sftp = nil
        if let client, let fresh = try? client.sftpInit() {
            self.sftp = fresh
            return
        }
        guard let config = lastConfig else { throw SSHClientError.disconnectedForSftp }
        disconnectInternal()
        let c = try Self.makeConnectedClient(config: config)
        let fresh = try c.sftpInit()
        client = c
        sftp = fresh
        connectedTo = config.connectionIdentity
        startKeepalive()
        note(L("SFTP 连接已自动恢复"))
    }

    /// 面板下载：走 TransferRunner 独立连接（切会话不断传），断点续传 + 底部进度栏展示
    func download(entry: Entry, to local: URL) {
        let remote = path + entry.name
        let host = connectedTo ?? ""
        let listPath = path
        guard let config = lastConfig else {
            note(L("SFTP 未连接，无法下载"))
            return
        }
        note(L("下载 %@ …", entry.name))
        TransferRunner.download(config: config, host: host, remote: remote, name: entry.name,
                                total: entry.size, to: local) { [weak self] ok, message in
            self?.note(message)
            if ok, self?.connectedTo == host { self?.list(listPath) }
        }
    }


    /// 面板上传：走 TransferRunner 独立连接（切会话不断传），断点续传 + 底部进度栏展示。
    /// resume=false 用于本地编辑回传（内容已变，续传会写坏远端文件）
    func upload(local: URL, name: String, resume: Bool = true, completion: ((Bool) -> Void)? = nil) {
        let remote = path + name
        let host = connectedTo ?? ""
        let listPath = path
        guard let config = lastConfig else {
            note(L("SFTP 未连接，无法上传"))
            return
        }
        note(L("上传 %@ …", name))
        TransferRunner.upload(config: config, host: host, local: local, remote: remote, name: name,
                              allowResume: resume) { [weak self] ok, message in
            self?.note(message)
            if ok, self?.connectedTo == host { self?.list(listPath) }
            if let completion { MainThread.perform { completion(ok) } }
        }
    }

    func makeDirectory(named name: String) {
        queue.async { [self] in
            guard let sftp, let client else { return }
            do {
                try client.sftpMkdir(sftp, path: path + name)
                try listInternal(sftp: sftp, path: path)
                note(L("已创建目录 %@", name))
            } catch {
                note(L("创建目录失败：%@", (error as? SSHClientError)?.description ?? "\(error)"))
            }
        }
    }

    func createFile(named name: String) {
        queue.async { [self] in
            guard let sftp, let client else { return }
            do {
                try client.sftpCreateFile(sftp, path: path + name)
                try listInternal(sftp: sftp, path: path)
                note(L("已创建文件 %@", name))
            } catch {
                note(L("创建文件失败：%@", (error as? SSHClientError)?.description ?? "\(error)"))
            }
        }
    }

    func remove(entry: Entry) {
        let remote = path + entry.name
        note(L("删除 %@ …", entry.name))
        queue.async { [self] in
            guard let sftp, let client else { return }
            do {
                if entry.isDir {
                    // 非空目录递归删除走远端 rm（UI 层已确认）
                    _ = try client.exec("rm -rf '\(remote.replacingOccurrences(of: "'", with: "'\\''"))'")
                } else {
                    try client.sftpUnlink(sftp, path: remote)
                }
                try listInternal(sftp: sftp, path: path)
                note(L("已删除 %@", entry.name))
            } catch {
                note(L("删除失败：%@", (error as? SSHClientError)?.description ?? "\(error)"))
            }
        }
    }

    func rename(entry: Entry, to newName: String) {
        queue.async { [self] in
            guard let sftp, let client else { return }
            do {
                try client.sftpRename(sftp, from: path + entry.name, to: path + newName)
                try listInternal(sftp: sftp, path: path)
                note(L("已重命名为 %@", newName))
            } catch {
                note(L("重命名失败：%@", (error as? SSHClientError)?.description ?? "\(error)"))
            }
        }
    }

    /// 远端 tar.gz 压缩（走 exec，压缩包出现在当前目录）
    func compress(entries: [Entry], archiveName: String) {
        let names = entries.map { entry in
            "'\(entry.name.replacingOccurrences(of: "'", with: "'\\''"))'"
        }.joined(separator: " ")
        let dir = path
        note(L("压缩 %ld 项 …", entries.count))
        queue.async { [self] in
            guard let sftp, let client else { return }
            do {
                let (code, output) = try client.exec("cd '\(dir.replacingOccurrences(of: "'", with: "'\\''"))' && tar czf '\(archiveName.replacingOccurrences(of: "'", with: "'\\''"))' \(names)")
                try listInternal(sftp: sftp, path: path)
                note(code == 0 ? L("已压缩为 %@", archiveName) : L("压缩失败：%@", output))
            } catch {
                note(L("压缩失败：%@", (error as? SSHClientError)?.description ?? "\(error)"))
            }
        }
    }

    // MARK: 本地编辑器打开 + 改动回传

    private struct WatchedFile {
        let remote: String
        let local: URL
        let name: String
        var size: Int
        var mtime: Date
    }

    private var watched: [WatchedFile] = []
    private var watchTimer: Timer?

    func openInLocalEditor(entry: Entry) {
        let remote = path + entry.name
        // 远端文件名只取最后一段落到临时目录（防御恶意文件名携带 ../ 逃出临时目录）
        let safeName = (entry.name as NSString).lastPathComponent
        guard !safeName.isEmpty, safeName != "." , safeName != ".." else {
            note(L("文件名无效，无法打开"))
            return
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Picoterm", isDirectory: true)
            .appendingPathComponent(safeName)
        note(L("打开 %@ …", entry.name))
        queue.async { [self] in
            guard let sftp, let client else { return }
            do {
                try? FileManager.default.removeItem(at: tmp)
                try client.sftpDownload(sftp, remote: remote, to: tmp)
                let attrs = (try? FileManager.default.attributesOfItem(atPath: tmp.path)) ?? [:]
                let info = WatchedFile(remote: remote, local: tmp, name: entry.name,
                                       size: (attrs[.size] as? Int) ?? 0,
                                       mtime: (attrs[.modificationDate] as? Date) ?? Date())
                MainThread.perform {
                    self.watched.append(info)
                    self.startWatching()
                    if let fallbackNote = FileOpener.open(tmp) {
                        self.note(fallbackNote)
                    }
                }
                note(L("已在本地编辑器打开 %@（修改后可回传）", entry.name))
            } catch {
                note(L("打开失败：%@", (error as? SSHClientError)?.description ?? "\(error)"))
            }
        }
    }

    private func startWatching() {
        guard watchTimer == nil else { return }
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkWatchedFiles()
        }
    }

    private func stopWatching() {
        watchTimer?.invalidate()
        watchTimer = nil
    }

    /// 启动时清理上次运行遗留的本地编辑临时目录
    static func purgeEditorTemp() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Picoterm", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    /// 主线程定时检查：本地文件变化 → 提示回传
    private func checkWatchedFiles() {
        for (index, file) in watched.enumerated().reversed() {
            let attrs = (try? FileManager.default.attributesOfItem(atPath: file.local.path)) ?? [:]
            let size = (attrs[.size] as? Int) ?? -1
            let mtime = (attrs[.modificationDate] as? Date) ?? Date.distantPast
            if !FileManager.default.fileExists(atPath: file.local.path) {
                watched.remove(at: index)
                // 被跟踪文件全部消失（用户删了临时副本）也要停表，定时器不能空转
                if watched.isEmpty { stopWatching() }
                continue
            }
            guard size != file.size || mtime > file.mtime, !uploading.contains(file.remote) else { continue }
            watched[index] = WatchedFile(remote: file.remote, local: file.local, name: file.name,
                                         size: size, mtime: mtime)
            let response = PicotermDialog.run(title: L("检测到修改"),
                                              content: PicotermDialog.message(L("「%@」已在本地被修改，是否回传到服务器？", file.name)),
                                              primaryTitle: L("回传"), cancelTitle: L("忽略"))
            if response == .OK {
                uploading.insert(file.remote)
                // 编辑回传内容已变，禁用断点续传（按大小续传会写坏远端文件）；
                // 成功才清本地临时副本并停止跟踪（取消/失败保留继续编辑）
                upload(local: file.local, name: (file.remote as NSString).lastPathComponent, resume: false) { [weak self] ok in
                    if ok {
                        try? FileManager.default.removeItem(at: file.local)
                        self?.watched.removeAll { $0.remote == file.remote }
                    }
                    self?.uploading.remove(file.remote)
                    if self?.watched.isEmpty == true { self?.stopWatching() }
                }
            }
        }
    }

    private var uploading: Set<String> = []

    private func disconnectInternal() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        if let sftp { client?.sftpShutdown(sftp) }
        sftp = nil
        client?.close()
        client?.teardown()
        client = nil
        entries = []
        connectedTo = nil
        homePath = nil
        ownerNames = [:]
        history = []
        historyIndex = -1
        canGoBack = false
        canGoForward = false
    }
    /// 拖拽下载承诺（2026-10-25 用户指定，Berth/Termind 拖出下载口径）：
    /// 返回该条目的文件承诺代理（仅文件；未连接返回 nil）。代理生命周期由
    /// 调用方（文件面板）持有到拖拽结束
    func promiseDelegate(for entry: Entry) -> SFTPPromiseDelegate? {
        guard let config = lastConfig, let host = connectedTo else { return nil }
        return SFTPPromiseDelegate(fileName: entry.name, config: config, host: host,
                                   remote: path + entry.name, size: entry.size)
    }
}


// MARK: - 拖出下载的文件承诺（NSFilePromiseProvider）：
// 拖动瞬间只承诺文件类型，落进 Finder/桌面后按目标路径异步下载，
// 进度与取消走底部传输条

final class SFTPPromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    let fileName: String
    let config: SSHConfig
    let host: String
    let remote: String
    let size: UInt64
    /// 状态提示（主线程回调；面板接走显示到汇总栏）
    var onStatus: ((String) -> Void)?

    init(fileName: String, config: SSHConfig, host: String, remote: String, size: UInt64) {
        self.fileName = fileName
        self.config = config
        self.host = host
        self.remote = remote
        self.size = size
        super.init()
    }

    func makeProvider() -> NSFilePromiseProvider {
        let ext = (fileName as NSString).pathExtension
        let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        return NSFilePromiseProvider(fileType: type.identifier, delegate: self)
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        fileName
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             operationQueueForFilePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        let queue = OperationQueue()
        queue.name = "picoterm.sftp.promise"
        return queue
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        onStatus?(L("拖出下载 %@ …", fileName))
        // 完成回调由 TransferRunner 的结束信号驱动（传输条可见进度/可取消）
        TransferRunner.download(config: config, host: host, remote: remote, name: fileName,
                                total: size, to: url) { ok, message in
            self.onStatus?(message)
            MainThread.perform {
                completionHandler(ok ? nil : SFTPPromiseError.failed(message))
            }
        }
    }
}

enum SFTPPromiseError: Error, CustomStringConvertible {
    case failed(String)

    var description: String { L("拖出下载失败") }
}

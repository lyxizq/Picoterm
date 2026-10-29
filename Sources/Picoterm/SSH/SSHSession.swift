import AppKit
import SwiftTerm
import PicotermCore

// SSH 会话：TerminalView + SSHClient 桥接；实现 TerminalSession 后
// 标签栏 / 终端容器 / 状态栏无需感知协议差异
@MainActor
final class SSHSession: NSObject, TerminalSession, TerminalViewDelegate {
    let id = UUID()
    var onStateChanged: (() -> Void)?
    private(set) var state: SessionState = .running
    private(set) var terminalSize: (cols: Int, rows: Int)?
    private let tv: CompletionTerminalView
    private let client = SSHClient()
    private let highlightPipe = LogHighlightPipe()
    /// clear/重置屏后保留登录横幅（TODO 66）
    private let bannerKeeper = LoginBannerKeeper()
    /// 会话起始时间：启动 5 秒内隐藏 Last login 登录横幅（TODO 62）
    private let sessionStartedAt = Date()
    private let queue = DispatchQueue(label: "picoterm.ssh.session", qos: .userInitiated)
    /// 输出加工专用队列（TODO 72/73）：高亮管道 + 横幅保留都在这里跑，
    /// 主线程只做最终馈送——正则/扫描不再阻塞按键响应（session 队列被事件循环独占，另开）
    private let processQueue = DispatchQueue(label: "picoterm.ssh.feed", qos: .userInitiated)
    let config: SSHConfig
    let hostEntryId: UUID?
    private let displayTitle: String
    /// 服务器状态采集（独立连接，不碰终端 libssh2 会话，也不向用户 shell 注入命令）
    private let metricsPoller = ServerMetricsPoller()
    /// 最近一次读数（主线程更新）；状态条换绑时立即显示用
    private(set) var latestMetrics: ServerMetricsReading?
    /// 状态读数回调（主线程）；nil = 采集停止。终端区的状态条消费
    var onMetricsUpdate: ((ServerMetricsReading?) -> Void)?

    init(config: SSHConfig, hostEntryId: UUID? = nil) {
        tv = CompletionTerminalView(frame: .zero)
        self.config = config
        self.hostEntryId = hostEntryId
        // 标签显示主机条目配置的名称（2026-10-25 用户指定）；无条目/空标签回退 user@host
        let entryLabel = hostEntryId.flatMap { id in
            HostStore.shared.hosts.first { $0.id == id }?.label
        } ?? ""
        displayTitle = entryLabel.isEmpty ? "\(config.user)@\(config.host)" : entryLabel
        super.init()
        metricsPoller.onReading = { [weak self] reading in
            guard let self else { return }
            if let reading {
                self.latestMetrics = reading
            }
            self.onMetricsUpdate?(reading)
        }
        AppTheme.apply(to: tv)
        tv.terminalDelegate = self
        highlightPipe.lineFilter = { line in
            line.starts(with: Array("Last login:".utf8))
                && Date().timeIntervalSince(self.sessionStartedAt) < 5
        }
        tv.sendCompletion = { [weak self] text in
            guard let self else { return }
            self.client.enqueueWrite(Array(text.utf8))
        }
        start(config)
    }

    /// Ported from Berth (GPL-3) KeyboardInteractiveAuth 的 UI 冒泡设计：
    /// 密码认证失败后自动转 keyboard-interactive 再试（堡垒机/MFA）。
    /// responder 会被 libssh2 在后台线程回调：NSAlert 必须主线程建，这里用
    /// DispatchQueue.main 同步等待结果（认证本身在会话串行队列，阻塞等待安全）。
    static func interactiveFallbackConfig(from config: SSHConfig, storedPassword: String) -> SSHConfig {
        var patched = config
        patched.auth = .keyboardInteractive(password: storedPassword) { challenge in
            if Thread.isMainThread {
                return presentKbdintDialog(challenge)
            }
            return DispatchQueue.main.sync {
                presentKbdintDialog(challenge)
            }
        }
        return patched
    }

    /// MFA 质询模态框（主线程专用）
    private static func verticalStack(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private static func presentKbdintDialog(_ challenge: KBDIntChallenge) -> [String]? {
            // MFA 质询：模态收集每个提示的应答（回显用普通输入框，不回显用可回显密码框——点眼睛验证身份后可核对）
            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300,
                                                 height: CGFloat(34 + challenge.prompts.count * 34)))
            var fields: [NSView & StringPromptField] = []
            var y = accessory.bounds.height - 30
            for (index, prompt) in challenge.prompts.enumerated() {
                let label = NSTextField(labelWithString: prompt.text)
                label.font = NSFont.systemFont(ofSize: 12)
                label.frame = NSRect(x: 0, y: y + 4, width: 300, height: 18)
                let field: NSView & StringPromptField
                if prompt.echo {
                    let text = NSTextField(string: "")
                    text.placeholderString = prompt.text
                    text.widthAnchor.constraint(equalToConstant: 300).isActive = true
                    field = text
                } else {
                    let secret = RevealableSecretField()
                    secret.placeholderString = prompt.text
                    secret.authReason = L("显示正在输入的验证应答")
                    field = secret
                }
                field.frame = NSRect(x: 0, y: y - 22, width: 300, height: 22)
                accessory.addSubview(label)
                accessory.addSubview(field)
                fields.append(field)
                y -= 34
            }
            var content: [NSView] = []
            if !challenge.instruction.isEmpty {
                content.append(PicotermDialog.message(challenge.instruction, width: 300))
            }
            content.append(contentsOf: accessory.subviews)
            guard PicotermDialog.run(title: challenge.name.isEmpty ? L("服务器要求验证") : challenge.name,
                                     content: Self.verticalStack(content),
                                     primaryTitle: L("提交")) == .OK else { return nil }
            return fields.map { $0.stringValue }
    }

    var title: String { state == .running ? displayTitle : displayTitle + L("（已断开）") }
    var symbol: String { "server.rack" }
    var terminalView: NSView { tv }

    func terminate() {
        guard state == .running else { return }
        state = .exited
        metricsPoller.stop()
        client.close()
        onStateChanged?()
    }

    func injectInput(_ bytes: [UInt8]) {
        guard state == .running else { return }
        freezeBanner()
        client.enqueueWrite(encodeForWire(bytes))
        if bytes.contains(0x0d) || bytes.contains(0x0a) { scheduleDirectoryProbe() }
    }

    // MARK: 字符集转码（Ported from Termind RemoteCharset 口径）
    // 输出解码归 processQueue（与高亮/横幅同队列），输入编码归主线程，两组转换器互不共享；
    // utf8 恒直通，iconv 不可用（理论上不发生）也直通不中断链路

    private var outputDecoder: RemoteCharsetStreamConverter?
    private var outputDecoderCharset: RemoteCharset?

    /// 远端输出 → UTF-8：流式转换，多字节尾缀跨块留存（字符集按主机配置，Ported from Termind）
    private func decodeForOutput(_ bytes: [UInt8]) -> [UInt8] {
        let charset = config.charset
        guard charset != .utf8 else {
            outputDecoder = nil
            outputDecoderCharset = nil
            return bytes
        }
        if charset != outputDecoderCharset {
            outputDecoder = try? RemoteCharsetStreamConverter(charset: charset, direction: .decoding)
            outputDecoderCharset = charset
            guard outputDecoder != nil else { return bytes }
        }
        guard let decoder = outputDecoder else { return bytes }
        let out = (try? decoder.convert(Data(bytes)))?.data ?? Data(bytes)
        return Array(out)
    }

    private var wireEncoder: RemoteCharsetStreamConverter?
    private var wireEncoderCharset: RemoteCharset?

    /// 键入 UTF-8 → 远端字符集；换字符集即重建
    private func encodeForWire(_ bytes: [UInt8]) -> [UInt8] {
        let charset = config.charset
        guard charset != .utf8 else {
            wireEncoder = nil
            wireEncoderCharset = nil
            return bytes
        }
        if charset != wireEncoderCharset {
            wireEncoder = try? RemoteCharsetStreamConverter(charset: charset, direction: .encoding)
            wireEncoderCharset = charset
            guard wireEncoder != nil else { return bytes }
        }
        guard let encoder = wireEncoder else { return bytes }
        let out = (try? encoder.convert(Data(bytes)))?.data ?? Data(bytes)
        return Array(out)
    }

    private func start(_ config: SSHConfig) {
        queue.async { [self] in
            do {
                // 连接前唤醒（Ported from Termind ConnectionWakeAction）：发完魔术包
                // 给主机一点启动时间再拨号；失败不阻断连接（主机可能本来就开着）
                if config.wakeBeforeConnect, !config.wolMac.isEmpty {
                    try? WakeOnLAN.send(macText: config.wolMac)
                    Thread.sleep(forTimeInterval: 2.0)
                }
                var effective = config
                do {
                    try client.connect(config: effective)
                } catch SSHClientError.authFailed {
                    // Ported from Berth：密码认证失败 → 自动转 keyboard-interactive（堡垒机/MFA）；
                    // 连接过程状态不进终端缓冲（保持终端干净），失败才显示错误
                    if case .password(let stored) = effective.auth, !stored.isEmpty {
                        effective = Self.interactiveFallbackConfig(from: effective, storedPassword: stored)
                        try client.connect(config: effective)
                    } else {
                        throw SSHClientError.authFailed(message: L("认证失败"))
                    }
                }
                try client.requestShell(cols: 80, rows: 24, terminal: effective.terminalType)
                // Shell 建好后开始服务器状态采集（用回退后的有效配置，认证口径一致）
                metricsPoller.start(config: effective)
                MainThread.perform(after: 1.5) { [weak self] in
                    guard let self, self.state == .running else { return }
                    self.scheduleDirectoryProbe()
                }
                // 目录跟随不再向服务器注入任何命令（TODO 71）：被动解析 OSC 7 / 窗口标题，
                // 兜底走 SFTP 独立连接只读探测——见 hostCurrentDirectoryUpdate / setTerminalTitle / scheduleDirectoryProbe
                client.runEventLoop(
                    onOutput: { chunk in
                        self.processQueue.async { self.processOutput(chunk) }
                    },
                    onDrain: {
                        self.processQueue.async { self.flushPendingOutput() }
                    },
                    onEof: { [client] in
                        client.teardown()
                    }
                )
                MainThread.perform {
                    self.markExited(message: L("[picoterm] 连接已断开\r\n"))
                }
            } catch {
                // Ported from Berth (GPL-3) — 错误按认证方式人话化
                let authKind: SSHErrorMapper.AuthMethodKind? = {
                    switch config.auth {
                    case .password: return .password
                    case .key: return .key
                    case .agent: return .agent
                    case .keyboardInteractive: return .password
                    }
                }()
                let message = SSHErrorMapper.friendlyMessage(for: error, authMethod: authKind)
                MainThread.perform {
                    self.markExited(message: L("[picoterm] %@\r\n", message))
                }
            }
        }
    }

    private func markExited(message: String?) {
        feed(message ?? "")
        guard state == .running else { return }
        state = .exited
        metricsPoller.stop()
        onStateChanged?()
    }

    private func feed(_ text: String) {
        guard !text.isEmpty else { return }
        tv.feed(text: text)
    }

    /// 右键菜单「清屏/全部清除/重置」用：清屏序列过一遍横幅保留管道再喂终端，
    /// 与用户敲 clear 同效——清屏后回插登录横幅（TODO 66 口径的程序化入口）
    func clearScreenKeepingBanner() {
        let out = bannerKeeper.process(Array("\u{1b}[H\u{1b}[2J".utf8))
        tv.feed(byteArray: out[...])
    }

    /// 输出加工（TODO 72/73）：管道（拼行 + 行过滤 + 可选着色）→ 横幅保留 → 字符集解码 → 主线程馈送
    private func processOutput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        highlightPipe.colorizeEnabled = AppSettings.shared.logHighlightEnabled
        let planned = bannerKeeper.process(highlightPipe.process(bytes))
        let decoded = decodeForOutput(planned)
        if !decoded.isEmpty {
            MainThread.perform { self.tv.feed(byteArray: decoded[...]) }
        }
    }

    /// 事件循环一轮读空后调用（processQueue）：管道里没凑齐整行的尾巴原样放出。
    /// 按键回显、vim/less 的光标序列都是这种"半行"，曾经要等 25ms 闲置 / 150ms 持满的
    /// 定时器才放行（长按键时回显按 150ms 一跳）——读空即放，回显延迟归零
    private func flushPendingOutput() {
        guard highlightPipe.hasPending else { return }
        let out = bannerKeeper.process(highlightPipe.flushPending())
        let decoded = decodeForOutput(out)
        if !decoded.isEmpty {
            MainThread.perform { self.tv.feed(byteArray: decoded[...]) }
        }
    }

    /// 首次按键定型登录横幅；bannerKeeper 归 processQueue 所有，跨线程访问须经它串行
    private func freezeBanner() {
        processQueue.async { [self] in bannerKeeper.freezeOnFirstInput() }
    }

    // MARK: TerminalViewDelegate

    /// 文件管理器跟随终端目录（OSC 7，格式 file://host/path）：仅跟随当前选中的会话
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let raw = directory, raw.hasPrefix("file://") else { return }
        var path = String(raw.dropFirst("file://".count))
        if !path.hasPrefix("/") {
            guard let slash = path.firstIndex(of: "/") else { return }
            path = String(path[slash...])
        }
        guard let decoded = path.removingPercentEncoding, decoded.hasPrefix("/") else { return }
        followDirectory(decoded)
    }

    /// 窗口标题里的目录（TODO 71）：Debian/Ubuntu/RHEL 默认 PS1 与 oh-my-zsh 都把 cwd 写进
    /// OSC 0/2 标题（"user@host: ~/dir"），被动解析即可跟随，不必向服务器注入任何命令
    func setTerminalTitle(source: TerminalView, title: String) {
        DebugLog.write("title: \(title.prefix(80))")
        guard let path = Self.directory(fromTitle: title, home: SFTPService.shared.homePath) else { return }
        followDirectory(path)
    }

    /// 被动来源（OSC 7 / 标题）报上来的 cwd：记一笔以免兜底探测重复发，再交给文件管理器
    private func followDirectory(_ path: String) {
        directoryReported = true
        lastKnownDirectory = path
        DebugLog.write("cwd reported: \(path) selected=\(SessionManager.shared.selected?.id == id)")
        guard AppSettings.shared.syncFileManagerWithTerminal, state == .running,
              SessionManager.shared.selected?.id == id else { return }
        SFTPService.shared.followTerminal(path)
    }

    /// 最近一次得知的远端 cwd（OSC 7 / 标题 / 兜底探测任一来源）；终端里相对路径点击的基准
    private(set) var lastKnownDirectory: String?

    /// 从窗口标题提取远端 cwd；非路径标题（运行中的命令名等）返回 nil。
    /// 认 "user@host: ~/x"、"user@host:~/x"、"host: /x" 与裸路径；"~" 需已知 home 才展开，
    /// "~user" 与 PROMPT_DIRTRIM 省略号（"~/.../x"）不认
    static func directory(fromTitle rawTitle: String, home: String?) -> String? {
        var title = rawTitle.trimmingCharacters(in: .whitespaces)
        if let colon = title.firstIndex(of: ":") {
            let prefix = title[..<colon]
            if !prefix.isEmpty, !prefix.contains(" "), !prefix.contains("/"), !prefix.contains("~") {
                title = title[title.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        guard title.hasPrefix("/") || title.hasPrefix("~"),
              !title.contains("/.../"), !title.hasPrefix("~/...") else { return nil }
        if title.hasPrefix("~") {
            guard let home else { return nil }
            if title == "~" { return home }
            guard title.hasPrefix("~/") else { return nil }
            return home + String(title.dropFirst())
        }
        return title
    }

    // MARK: 目录兜底探测（TODO 71）

    /// 自上次回车以来是否有被动来源报过 cwd；没有才在回车后探测一次
    private var directoryReported = false
    private var directoryProbeWork: DispatchWorkItem?
    private var directoryProbeInFlight = false

    /// 回车后 0.7s 仍无 OSC 7/标题上报（Arch、root 登录、busybox 等默认不写标题），
    /// 走 SFTP 独立连接按源端口定位本会话 shell、readlink /proc 读 cwd——不触碰用户终端
    private func scheduleDirectoryProbe() {
        guard AppSettings.shared.syncFileManagerWithTerminal else { return }
        DebugLog.write("probe scheduled")
        directoryReported = false
        directoryProbeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.directoryReported, !self.directoryProbeInFlight,
                  self.state == .running, SessionManager.shared.selected?.id == self.id else { return }
            self.directoryProbeInFlight = true
            DebugLog.write("probe firing port=\(self.client.localPort)")
            SFTPService.shared.probeTerminalDirectory(clientPort: self.client.localPort) { [weak self] path in
                guard let self else { return }
                self.directoryProbeInFlight = false
                DebugLog.write("probe result: \(path ?? "nil")")
                if let path { self.lastKnownDirectory = path }
                guard let path, !self.directoryReported, self.state == .running,
                      SessionManager.shared.selected?.id == self.id else { return }
                SFTPService.shared.followTerminal(path)
            }
        }
        directoryProbeWork = work
        MainThread.perform(after: 0.7, work)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = [UInt8](data)
        freezeBanner() // 首次按键后横幅定型（TODO 66）
        CompletionInputTracker.shared.feed(bytes)
        // enqueueWrite 线程安全（锁 + 唤醒管道），直接调用；事件循环队列正被 poll 阻塞
        client.enqueueWrite(encodeForWire(bytes))
        SessionManager.shared.broadcastInput(from: self, bytes: bytes)
        if bytes.contains(0x0d) || bytes.contains(0x0a) { scheduleDirectoryProbe() }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        tv.applyScrollbackSetting() // Terminal 已创建（首次 sizeChanged 兜底），TODO 74
        terminalSize = (newCols, newRows)
        NotificationCenter.default.post(name: .terminalSizeChanged, object: self)
        client.enqueueResize(cols: Int32(newCols), rows: Int32(newRows))
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// ⌘点击链接（SwiftTerm 识别的 URL/路径）：网页交系统，远端路径跳文件管理器，白名单外一律不动
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        let cwd = lastKnownDirectory
            ?? (SessionManager.shared.selected?.id == id && SFTPService.shared.connectedTo != nil
                ? SFTPService.shared.path : nil)
        switch LinkOpenPolicy.classify(link, isRemote: true, currentDirectory: cwd,
                                       home: SFTPService.shared.homePath) {
        case .web(let url):
            NSWorkspace.shared.open(url)
        case .remotePath(let path):
            guard SessionManager.shared.selected?.id == id else { return } // 文件管理器只跟随选中会话
            SFTPService.shared.reveal(path: path)
        case .localFile, .rejected:
            break
        }
    }

    func bell(source: TerminalView) {
        NSSound.beep()
    }
}

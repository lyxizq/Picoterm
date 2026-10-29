import Foundation
import CSSH2
import PicotermCore

// MARK: - libssh2 常量（头文件里是 #define 宏，不导入 Swift，这里按 1.11.1 头文件取值）

private enum LibSSH2 {
    static let flagSigpipe: Int32 = 1
    // libssh2_session_method_pref 方法槽位
    static let methodKex: Int32 = 0
    static let methodHostkey: Int32 = 1
    static let methodCryptCs: Int32 = 2
    static let methodCryptSc: Int32 = 3
    static let errorEagain: Int = -37
    static let errorSftpProtocol: Int32 = -31 // LIBSSH2_ERROR_SFTP_PROTOCOL：服务器 SFTP 层拒绝（非通道错误）
    static let disconnectByApplication: Int32 = 11
    static let channelWindowDefault: UInt32 = 2 * 1024 * 1024
    static let channelPacketDefault: UInt32 = 32768
    static let knownhostFileOpenSSH: Int32 = 1
    static let knownhostTypePlain: Int32 = 1
    static let knownhostKeyencRaw: Int32 = 1 << 16
    static let hostkeyTypeRSA: Int32 = 1
    static let hostkeyTypeECDSA256: Int32 = 3
    static let hostkeyTypeECDSA384: Int32 = 4
    static let hostkeyTypeECDSA521: Int32 = 5
    static let hostkeyTypeED25519: Int32 = 6
    static let keySSHRSA: Int32 = 2 << 18
    static let keyECDSA256: Int32 = 4 << 18
    static let keyECDSA384: Int32 = 5 << 18
    static let keyECDSA521: Int32 = 6 << 18
    static let keyED25519: Int32 = 7 << 18
    static let keyUnknown: Int32 = 15 << 18
    static let checkMatch: Int32 = 0
    static let checkMismatch: Int32 = 1
    static let checkNotFound: Int32 = 2
}

// MARK: - libssh2 封装：连接/认证/known_hosts/keepalive/PTY 事件循环
//
// 线程模型：connect/auth 在调用方队列一次性完成（阻塞式）；会话建立后所有 C
// 调用只在事件循环线程上进行。UI 线程通过「出站缓冲 + 自管道唤醒」投递输入、
// 尺寸变化和关闭请求，满足 libssh2 不允许并发调用同一 session 的限制。

enum SSHClientError: Error, CustomStringConvertible {
    case dnsFailed
    case connectFailed
    case handshakeFailed(code: Int32)
    case hostKeyMismatch
    case authFailed(message: String)
    case channelFailed(code: Int32)
    case sftpProtocol(status: UInt32)
    case localFileFailed(String)
    case disconnectedForSftp

    var description: String {
        switch self {
        case .dnsFailed: return L("无法解析主机地址")
        case .connectFailed: return L("无法建立 TCP 连接（超时或拒绝）")
        case .handshakeFailed(let code): return L("SSH 握手失败（%d）", code)
        case .hostKeyMismatch: return L("主机指纹与 known_hosts 不符，连接已拒绝")
        case .authFailed(let message): return L("认证失败：%@", message)
        case .channelFailed(let code): return L("打开会话通道失败（%d）", code)
        case .sftpProtocol(let status):
            let reason: String
            switch status {
            case 2: reason = L("文件或目录不存在")
            case 3: reason = L("权限不足")
            case 4: reason = L("服务器拒绝该操作")
            case 8: reason = L("服务器不支持该操作")
            case 11: reason = L("目标已存在")
            case 14: reason = L("服务器磁盘空间不足")
            default: reason = L("服务器状态码 %lu", status)
            }
            return L("SFTP 协议错误：%@", reason)
        case .localFileFailed(let detail): return L("本地文件操作失败：%@", detail)
        case .disconnectedForSftp: return L("SFTP 未连接")
        }
    }
}

struct SSHConfig {
    var host: String
    var port: UInt16 = 22
    var user: String
    var auth: Auth
    var keepaliveInterval: UInt32 = 30
    /// 远端字符集（Ported from Termind RemoteCharset）：非 UTF-8 时输入输出转码
    var charset: RemoteCharset = .utf8
    /// PTY 终端类型（连接编辑弹窗「终端」字段；HostEntry.terminal 直通）
    var terminalType: String = "xterm-256color"
    /// Wake-on-LAN：网卡 MAC；非空且 wakeBeforeConnect 时连接前先发魔术包
    var wolMac: String = ""
    var wakeBeforeConnect: Bool = false

    enum Auth {
        case password(String)
        case key(path: String, passphrase: String)
        case agent
        /// keyboard-interactive（RFC 4256）：堡垒机/MFA； responder 为 UI 提供需显示的提示，返回应答数组
        case keyboardInteractive(password: String, responder: (KBDIntChallenge) -> [String]?)
    }
}

extension SSHConfig {
    /// 连接标识（user@host:port）：SSH 会话与 SFTPService.connectedTo 用同一口径比对
    var connectionIdentity: String { "\(user)@\(host):\(port)" }
}

/// keyboard-interactive 质询（Ported from Berth KeyboardInteractiveAuth.Challenge）
struct KBDIntChallenge {
    struct Prompt {
        let text: String
        let echo: Bool
    }
    let name: String
    let instruction: String
    let prompts: [Prompt]
}

final class SSHClient {
    private var sock: Int32 = -1
    private var session: OpaquePointer?
    private var channel: OpaquePointer?

    // 自管道：向事件循环发「有出站数据 / 有窗口变化 / 请求关闭」的唤醒信号
    private var wakePipe: [Int32] = [-1, -1]

    // 出站缓冲与待应用的 pty 尺寸（UI 线程写，事件循环读）
    private let outLock = NSLock()
    private var outgoing: [UInt8] = []
    private var pendingResize: (cols: Int32, rows: Int32)?

    private let closed = AtomicFlag()
    private var keepaliveLastSent = Date()
    var keepaliveInterval: UInt32 = 30

    /// 本端临时端口：服务器侧按客户端源端口定位本会话的 sshd 子进程/shell（目录探测，TODO 71）
    private(set) var localPort: UInt16 = 0

    // MARK: 连接与认证（阻塞式，一次性）

    func connect(config: SSHConfig, withSessionChannel: Bool = true) throws {
        _ = libssh2_init(0)
        // 认证失败后换方式重连会再次进入 connect：先清掉上一轮的 socket/session
        if session != nil || sock >= 0 { teardown() }
        sock = try Self.connectSocket(host: config.host, port: config.port)
        localPort = Self.localPort(of: sock)

        session = libssh2_session_init_ex(nil, nil, nil, nil)
        guard let session else { throw SSHClientError.handshakeFailed(code: -1) }
        libssh2_session_set_blocking(session, 1)
        libssh2_session_flag(session, LibSSH2.flagSigpipe, 1)
        keepaliveInterval = config.keepaliveInterval

        // Ported from Berth SSHCompatAlgorithms：显式放宽算法偏好（现代在前 + 兼容兜底），
        // 服务器为 OpenSSH 9.x 时协商 ecdh/curve25519；老堡垒机可落到 DH group14
        _ = "ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group14-sha256,diffie-hellman-group14-sha1"
            .withCString { libssh2_session_method_pref(session, LibSSH2.methodKex, $0) }
        _ = "rsa-sha2-512,rsa-sha2-256,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,ssh-ed25519,ssh-rsa"
            .withCString { libssh2_session_method_pref(session, LibSSH2.methodHostkey, $0) }
        _ = "aes128-gcm@openssh.com,aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr"
            .withCString { libssh2_session_method_pref(session, LibSSH2.methodCryptCs, $0) }
        _ = "aes128-gcm@openssh.com,aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr"
            .withCString { libssh2_session_method_pref(session, LibSSH2.methodCryptSc, $0) }

        let rc = libssh2_session_handshake(session, sock)
        guard rc == 0 else { cleanupSocket(); throw SSHClientError.handshakeFailed(code: rc) }

        try verifyHostKey(host: config.host)

        switch config.auth {
        case .password(let password):
            try authPassword(user: config.user, password: password)
        case .key(let path, let passphrase):
            try authPublicKey(user: config.user, keyPath: path, passphrase: passphrase)
        case .agent:
            try authAgent(user: config.user)
        case .keyboardInteractive(let storedPassword, let responder):
            try authKeyboardInteractive(user: config.user,
                                        storedPassword: storedPassword,
                                        responder: responder)
        }

        // SFTP 专用连接不开闲置 session 通道：减少对服务端并发通道的占用（嵌入式设备限制严格）
        if withSessionChannel {
            guard let channel = libssh2_channel_open_ex(session, "session", 7,
                                                        LibSSH2.channelWindowDefault,
                                                        LibSSH2.channelPacketDefault, nil, 0) else {
                throw SSHClientError.channelFailed(code: libssh2_session_last_errno(session))
            }
            self.channel = channel
        }

        libssh2_keepalive_config(session, 0, config.keepaliveInterval)
        guard pipe(&wakePipe) == 0 else { throw SSHClientError.channelFailed(code: -5) }
        for fd in wakePipe {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        }
    }

    /// 无事件循环的连接（SFTP）由外部定时器串行调用：按 keepalive_config 周期保活，防服务端回收闲置通道
    func sendKeepalive() {
        guard let session else { return }
        _ = libssh2_keepalive_send(session, nil)
    }

    func requestShell(cols: Int32, rows: Int32, terminal: String = "xterm-256color") throws {
        guard let channel else { throw SSHClientError.channelFailed(code: -4) }
        let termName = terminal.isEmpty ? "xterm-256color" : terminal
        let termLength = UInt32(termName.utf8.count)
        let rc = termName.withCString { term in
            libssh2_channel_request_pty_ex(channel, term, termLength, nil, 0, cols, rows, 0, 0)
        }
        guard rc == 0 else { throw SSHClientError.channelFailed(code: rc) }
        let src = "shell".withCString { req in
            libssh2_channel_process_startup(channel, req, 5, nil, 0)
        }
        guard src == 0 else { throw SSHClientError.channelFailed(code: src) }
    }

    // MARK: 认证实现

    private func authPassword(user: String, password: String) throws {
        let rc = user.withCString { u in
            password.withCString { p in
                libssh2_userauth_password_ex(session, u, UInt32(strlen(u)), p, UInt32(strlen(p)), nil)
            }
        }
        guard rc == 0 else {
            throw SSHClientError.authFailed(message: lastSessionError(fallback: L("用户名或密码错误")))
        }
    }

    private func authPublicKey(user: String, keyPath: String, passphrase: String) throws {
        let pub = (keyPath as NSString).appendingPathExtension("pub") ?? keyPath
        let rc = user.withCString { u in
            passphrase.withCString { pass in
                pub.withCString { pk in
                    keyPath.withCString { sk in
                        libssh2_userauth_publickey_fromfile_ex(session, u, UInt32(strlen(u)),
                                                               pk, sk, pass)
                    }
                }
            }
        }
        guard rc == 0 else {
            throw SSHClientError.authFailed(message: lastSessionError(fallback: L("私钥无效或口令错误（%@）", keyPath)))
        }
    }

    // MARK: keyboard-interactive（Ported from Berth (GPL-3) KeyboardInteractiveAuth，适配 libssh2 回调式 API）
    // 行为对齐 Berth：首个「不回显」提示在密码未被消费前自动用存储密码作答；
    // 其余提示（MFA 动态码）经 responder 冒泡 UI；取消 = 认证中止；最多 3 轮。

    private func authKeyboardInteractive(user: String,
                                         storedPassword: String,
                                         responder: @escaping (KBDIntChallenge) -> [String]?) throws {
        // 上下文按线程隔离：终端会话与 SFTP 连接可能并发认证（各自串行队列），
        // 全局静态会互抢自动应答标志/覆盖 responder（表现为已存密码仍弹验证框、SFTP 认证失败）
        let threadKey = Self.kbdintThreadKey()
        Self.kbdintLock.lock()
        Self.kbdintContextByThread[threadKey] = (storedPassword, responder)
        Self.kbdintPasswordUsedByThread.remove(threadKey)
        Self.kbdintLock.unlock()
        defer {
            Self.kbdintLock.lock()
            Self.kbdintContextByThread[threadKey] = nil
            Self.kbdintPasswordUsedByThread.remove(threadKey)
            Self.kbdintLock.unlock()
        }

        var attempts = 0
        let maxAttempts = 3
        while attempts < maxAttempts {
            attempts += 1
            let rc = user.withCString { u in
                libssh2_userauth_keyboard_interactive_ex(
                    session, u, UInt32(strlen(u)),
                    { name, nameLen, instruction, instructionLen, numPrompts, prompts, responses, _ in
                        SSHClient.handleKbdintChallenge(name: name, nameLen: nameLen,
                                                        instruction: instruction, instructionLen: instructionLen,
                                                        numPrompts: numPrompts, prompts: prompts,
                                                        responses: responses)
                    })
            }
            if rc == 0 { return }
            if rc == -18 { // LIBSSH2_ERROR_AUTHENTICATION_FAILED：MFA 码错可重试
                continue
            }
            throw SSHClientError.authFailed(message: lastSessionError(fallback: L("键盘交互认证失败")))
        }
        throw SSHClientError.authFailed(message: L("认证失败：多轮质询均被拒绝（含 MFA 码错误）"))
    }

    /// C 回调（无捕获上下文）：经线程隔离的 kbdintContextByThread 组装质询并应答。
    /// 自动应答策略 Ported from Berth：首个「不回显」提示自动以存储密码作答（堡垒机第一轮 Password:），
    /// 其余（MFA 动态码）冒泡 UI；取消 = 空串应答。
    private static func handleKbdintChallenge(name: UnsafePointer<CChar>?,
                                              nameLen: CInt,
                                              instruction: UnsafePointer<CChar>?,
                                              instructionLen: CInt,
                                              numPrompts: CInt,
                                              prompts: UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?,
                                              responses: UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?) {
        guard let responses, numPrompts > 0 else { return }
        var uiPrompts: [KBDIntChallenge.Prompt] = []
        if let prompts {
            for i in 0..<Int(numPrompts) {
                let p = prompts[i]
                let length = Int(p.length)
                let text = p.text != nil
                    ? String(decoding: UnsafeBufferPointer(start: p.text, count: length), as: UTF8.self)
                    : ""
                uiPrompts.append(KBDIntChallenge.Prompt(text: text, echo: p.echo != 0))
            }
        }
        func cstring(_ pointer: UnsafePointer<CChar>?, _ length: CInt) -> String {
            guard let pointer, length > 0 else { return "" }
            let buffer = UnsafeBufferPointer(start: pointer, count: Int(length))
            return String(decoding: buffer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        let challengeName = cstring(name, nameLen)
        let challengeInstruction = cstring(instruction, instructionLen)
        let threadKey = kbdintThreadKey()

        // 自动应答：首个不回显提示用存储密码（本线程未消费过时）
        kbdintLock.lock()
        let context = kbdintContextByThread[threadKey]
        let consumed = kbdintPasswordUsedByThread.contains(threadKey)
        if let context, !context.password.isEmpty,
           let firstEcho = uiPrompts.first?.echo, !firstEcho, !consumed {
            kbdintPasswordUsedByThread.insert(threadKey)
            kbdintLock.unlock()
            for i in 0..<Int(numPrompts) {
                let answer = i == 0 ? context.password : ""
                let cstr = strdup(answer)
                responses[i].text = cstr
                responses[i].length = UInt32(answer.utf8.count)
            }
            return
        }
        kbdintLock.unlock()

        let answers = context?.responder(KBDIntChallenge(
            name: challengeName,
            instruction: challengeInstruction,
            prompts: uiPrompts)) ?? []
        for i in 0..<Int(numPrompts) {
            let answer = i < answers.count ? answers[i] : ""
            responses[i].text = strdup(answer)
            responses[i].length = UInt32(answer.utf8.count)
        }
    }

    private static let kbdintLock = NSLock()
    // libssh2 在调用线程内同步回调，键用 Foundation 线程对象即可互不串扰
    private static var kbdintContextByThread: [ObjectIdentifier: (password: String, responder: (KBDIntChallenge) -> [String]?)] = [:]
    private static var kbdintPasswordUsedByThread: Set<ObjectIdentifier> = []

    private static func kbdintThreadKey() -> ObjectIdentifier {
        ObjectIdentifier(Thread.current)
    }

    private func authAgent(user: String) throws {
        guard let agent = libssh2_agent_init(session) else {
            throw SSHClientError.authFailed(message: L("无法初始化 ssh-agent"))
        }
        defer { libssh2_agent_free(agent) }
        guard libssh2_agent_connect(agent) == 0 else {
            throw SSHClientError.authFailed(message: L("无法连接 ssh-agent（SSH_AUTH_SOCK 未设置或 agent 未运行）"))
        }
        defer { libssh2_agent_disconnect(agent) }
        guard libssh2_agent_list_identities(agent) == 0 else {
            throw SSHClientError.authFailed(message: L("读取 ssh-agent 身份失败"))
        }
        var prev: UnsafeMutablePointer<libssh2_agent_publickey>?
        var tried = 0
        while true {
            var identity: UnsafeMutablePointer<libssh2_agent_publickey>?
            let rc = libssh2_agent_get_identity(agent, &identity, prev)
            if rc == 1 { break }
            if rc != 0 { throw SSHClientError.authFailed(message: L("枚举 ssh-agent 身份失败")) }
            let urc = user.withCString { u in
                libssh2_agent_userauth(agent, u, identity)
            }
            if urc == 0 { return }
            tried += 1
            prev = identity
        }
        throw SSHClientError.authFailed(message: tried == 0 ? L("ssh-agent 中没有可用身份") : L("ssh-agent 身份均未被服务器接受"))
    }

    // MARK: known_hosts 校验（新主机自动记录，指纹不符拒绝连接）

    private func verifyHostKey(host: String) throws {
        guard let kh = libssh2_knownhost_init(session) else {
            throw SSHClientError.handshakeFailed(code: -2)
        }
        defer { libssh2_knownhost_free(kh) }

        let path = NSString(string: "~/.ssh/known_hosts").expandingTildeInPath
        if FileManager.default.fileExists(atPath: path) {
            libssh2_knownhost_readfile(kh, path, LibSSH2.knownhostFileOpenSSH)
        }

        var keyLen: Int = 0
        var keyType: Int32 = 0
        guard let key = libssh2_session_hostkey(session, &keyLen, &keyType) else {
            throw SSHClientError.handshakeFailed(code: -3)
        }

        let keyMask: Int32
        switch keyType {
        case LibSSH2.hostkeyTypeRSA: keyMask = LibSSH2.keySSHRSA
        case LibSSH2.hostkeyTypeECDSA256: keyMask = LibSSH2.keyECDSA256
        case LibSSH2.hostkeyTypeECDSA384: keyMask = LibSSH2.keyECDSA384
        case LibSSH2.hostkeyTypeECDSA521: keyMask = LibSSH2.keyECDSA521
        case LibSSH2.hostkeyTypeED25519: keyMask = LibSSH2.keyED25519
        default: keyMask = LibSSH2.keyUnknown
        }

        var store: UnsafeMutablePointer<libssh2_knownhost>? = nil
        let check = libssh2_knownhost_checkp(kh, host, 0, key, keyLen,
                                             LibSSH2.knownhostTypePlain | keyMask, &store)
        switch check {
        case LibSSH2.checkMatch:
            return
        case LibSSH2.checkMismatch:
            throw SSHClientError.hostKeyMismatch
        default:
            // 首次见到该主机：记录并写回 known_hosts（WindTerm 首连同款行为）
            let add = libssh2_knownhost_add(kh, host, nil, key, keyLen,
                                            LibSSH2.knownhostTypePlain | LibSSH2.knownhostKeyencRaw | keyMask,
                                            nil)
            guard add == 0, keyMask != LibSSH2.keyUnknown else { return }
            libssh2_knownhost_writefile(kh, path, LibSSH2.knownhostFileOpenSSH)
        }
    }

    private func lastSessionError(fallback: String) -> String {
        var msg: UnsafeMutablePointer<CChar>? = nil
        let rc = libssh2_session_last_error(session, &msg, nil, 0)
        if let m = msg, let text = String(validatingUTF8: m) {
            return L("%@（%d）", text, rc)
        }
        return fallback
    }

    // MARK: 事件循环（非阻塞会话 + poll；输出、输入、keepalive 都在这里串行处理）

    /// onOutput 每读到一块就回调；一轮把 socket 读空（EAGAIN）后再回调一次 onDrain，
    /// 会话据此立即放出没凑齐整行的输出（按键回显/TUI 光标序列），不必等定时器
    func runEventLoop(onOutput: @escaping ([UInt8]) -> Void,
                      onDrain: @escaping () -> Void,
                      onEof: @escaping () -> Void) {
        guard let channel, session != nil, sock >= 0, wakePipe[0] >= 0 else {
            onEof()
            return
        }
        // 握手/认证/PTY/Shell 全程阻塞式；进入事件循环后才切非阻塞（轮询 + EAGAIN 驱动）
        _ = libssh2_session_set_blocking(session, 0)
        var buffer = [UInt8](repeating: 0, count: 16384)
        defer { onEof() }

        while !closed.value {
            var fds = [
                pollfd(fd: sock, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakePipe[0], events: Int16(POLLIN), revents: 0),
            ]
            let pr = poll(&fds, 2, 1000)
            if closed.value { break }

            if keepaliveInterval > 0,
               Date().timeIntervalSince(keepaliveLastSent) >= TimeInterval(keepaliveInterval) {
                keepaliveLastSent = Date()
                _ = libssh2_keepalive_send(session, nil)
            }

            if pr > 0, fds[1].revents & Int16(POLLIN) != 0 {
                drainWakePipe()
            }
            flushOutgoing()
            applyPendingResize()

            if fds[0].revents & Int16(POLLIN) != 0 || fds[0].revents & Int16(POLLHUP) != 0 {
                var gotOutput = false
                var ended = false
                while true {
                    let n = buffer.withUnsafeMutableBytes { raw in
                        libssh2_channel_read_ex(channel, 0,
                                                raw.baseAddress?.assumingMemoryBound(to: CChar.self),
                                                raw.count)
                    }
                    if n > 0 {
                        gotOutput = true
                        onOutput(Array(buffer.prefix(n)))
                        continue
                    }
                    if n == LibSSH2.errorEagain { break }
                    ended = true // 0 = EOF；其余负值 = 传输错误，都按断开处理
                    break
                }
                if gotOutput { onDrain() }
                if ended { return }
            }
        }
    }

    /// UI 线程调用：投递键盘输入
    func enqueueWrite(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, !closed.value else { return }
        outLock.lock()
        outgoing.append(contentsOf: bytes)
        outLock.unlock()
        wake()
    }

    /// UI 线程调用：终端窗口尺寸变化
    func enqueueResize(cols: Int32, rows: Int32) {
        outLock.lock()
        pendingResize = (cols, rows)
        outLock.unlock()
        wake()
    }

    private func flushOutgoing() {
        outLock.lock()
        let chunk = outgoing
        outgoing = []
        outLock.unlock()
        guard !chunk.isEmpty, let channel else { return }
        var offset = 0
        while offset < chunk.count, !closed.value {
            let sent = chunk.withUnsafeBytes { raw -> Int in
                let base = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: CChar.self)
                return libssh2_channel_write_ex(channel, 0, base, raw.count - offset)
            }
            if sent > 0 {
                offset += sent
            } else if sent == LibSSH2.errorEagain {
                var pfd = [pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)]
                poll(&pfd, 1, 200)
            } else {
                return
            }
        }
    }

    private func applyPendingResize() {
        outLock.lock()
        let resize = pendingResize
        pendingResize = nil
        outLock.unlock()
        if let resize, let channel {
            libssh2_channel_request_pty_size_ex(channel, resize.cols, resize.rows, 0, 0)
        }
    }

    private func wake() {
        if wakePipe[1] >= 0 { _ = write(wakePipe[1], "1", 1) }
    }

    private func drainWakePipe() {
        var buf = [UInt8](repeating: 0, count: 64)
        while read(wakePipe[0], &buf, buf.count) > 0 {}
    }

    // MARK: 关闭

    /// UI 线程调用：请求关闭（事件循环自行退出并清理）
    func close() {
        closed.set()
        wake()
    }

    /// 事件循环结束后在循环线程调用
    func teardown() {
        if let session {
            _ = libssh2_session_set_blocking(session, 1)
        }
        if let channel {
            libssh2_channel_send_eof(channel)
            libssh2_channel_close(channel)
            libssh2_channel_wait_closed(channel)
            libssh2_channel_free(channel)
            self.channel = nil
        }
        if let session {
            libssh2_session_disconnect_ex(session, LibSSH2.disconnectByApplication, "", "")
            libssh2_session_free(session)
            self.session = nil
        }
        cleanupSocket()
        if wakePipe[0] >= 0 { Darwin.close(wakePipe[0]); wakePipe[0] = -1 }
        if wakePipe[1] >= 0 { Darwin.close(wakePipe[1]); wakePipe[1] = -1 }
    }

    private func cleanupSocket() {
        if sock >= 0 { Darwin.close(sock); sock = -1 }
    }

    // MARK: TCP 连接（非阻塞 connect + 超时）

    /// 已连接 socket 的本端端口（IPv4/IPv6），取不到返回 0
    private static func localPort(of fd: Int32) -> UInt16 {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &length) }
        }
        guard rc == 0 else { return 0 }
        switch Int32(storage.ss_family) {
        case AF_INET:
            return withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
            }
        case AF_INET6:
            return withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
            }
        default:
            return 0
        }
    }

    private static func connectSocket(host: String, port: UInt16, timeoutSeconds: Int32 = 10) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>? = nil
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
            throw SSHClientError.dnsFailed
        }
        defer { freeaddrinfo(res) }

        var info: UnsafeMutablePointer<addrinfo>? = first
        while let p = info {
            defer { info = p.pointee.ai_next }
            let fd = socket(p.pointee.ai_family, p.pointee.ai_socktype, p.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            // 关 Nagle（OpenSSH/PuTTY 交互会话同款）：libssh2 自己不设，按键小包会被攒到
            // 前一包 ACK 回来才发，连打时每键多等一个 RTT～对端延迟 ACK 定时器
            var noDelay: Int32 = 1
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let rc = Darwin.connect(fd, p.pointee.ai_addr, p.pointee.ai_addrlen)
            var connected = rc == 0
            if !connected && errno == EINPROGRESS {
                var pfd = [pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)]
                let pr = poll(&pfd, 1, timeoutSeconds * 1000)
                if pr > 0 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    connected = err == 0
                }
            }
            if connected {
                _ = fcntl(fd, F_SETFL, flags)
                return fd
            }
            Darwin.close(fd)
        }
        throw SSHClientError.connectFailed
    }
}

// MARK: - SFTP（libssh2_sftp；SFTPService 用独立连接在本类上做阻塞调用）

extension SSHClient {
    /// libssh2 返回 NULL/非 0 时的错误归类：-31 是服务器 SFTP 层拒绝（STATUS 失败），
    /// 带服务器状态码；其余按会话/通道错误
    private func sftpFailure(_ sftp: OpaquePointer) -> SSHClientError {
        let rc = libssh2_session_last_errno(session)
        if rc == LibSSH2.errorSftpProtocol {
            return .sftpProtocol(status: UInt32(libssh2_sftp_last_error(sftp)))
        }
        return .channelFailed(code: rc)
    }

    func sftpInit() throws -> OpaquePointer {
        guard let session, let sftp = libssh2_sftp_init(session) else {
            throw SSHClientError.channelFailed(code: -6)
        }
        return sftp
    }

    func sftpShutdown(_ sftp: OpaquePointer) {
        libssh2_sftp_shutdown(sftp)
    }

    func sftpRealpath(_ sftp: OpaquePointer, path: String) -> String {
        var buf = [CChar](repeating: 0, count: 1024)
        let rc = path.withCString { p in
            buf.withUnsafeMutableBufferPointer { out in
                libssh2_sftp_symlink_ex(sftp, p, UInt32(strlen(p)), out.baseAddress, UInt32(out.count), 2) // 2 = REALPATH
            }
        }
        guard rc > 0, let home = String(validatingUTF8: buf) else { return path }
        return home
    }

    struct SFTPEntry {
        let name: String
        let isDir: Bool
        let size: UInt64
        let mtime: UInt64
        let permissions: UInt32
        let uid: UInt32
    }

    func sftpList(_ sftp: OpaquePointer, path: String) throws -> [SFTPEntry] {
        guard let handle = path.withCString({ p in
            libssh2_sftp_open_ex(sftp, p, UInt32(strlen(p)), 0, 0, 1) // OPENDIR
        }) else {
            throw sftpFailure(sftp)
        }
        defer { libssh2_sftp_close_handle(handle) }

        var result: [SFTPEntry] = []
        var nameBuf = [CChar](repeating: 0, count: 512)
        var longBuf = [CChar](repeating: 0, count: 512)
        while true {
            var attrs = LIBSSH2_SFTP_ATTRIBUTES()
            let n = nameBuf.withUnsafeMutableBufferPointer { namePtr in
                longBuf.withUnsafeMutableBufferPointer { longPtr in
                    libssh2_sftp_readdir_ex(handle, namePtr.baseAddress, namePtr.count,
                                            longPtr.baseAddress, longPtr.count, &attrs)
                }
            }
            guard n > 0 else { break }
            let name = nameBuf.withUnsafeBufferPointer { ptr -> String in
                String(validatingUTF8: ptr.baseAddress!) ?? ""
            }
            if name == "." || name == ".." { continue }
            let isDir = (attrs.flags & 4) != 0 && (attrs.permissions & 0o170000) == 0o040000
            result.append(SFTPEntry(name: name,
                                    isDir: isDir,
                                    size: (attrs.flags & 1) != 0 ? attrs.filesize : 0,
                                    mtime: (attrs.flags & 8) != 0 ? UInt64(attrs.mtime) : 0,
                                    permissions: (attrs.flags & 4) != 0 ? UInt32(attrs.permissions) : 0,
                                    uid: (attrs.flags & 2) != 0 ? UInt32(attrs.uid) : 0))
        }
        return result.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name < b.name
        }
    }

    /// 读远端文件前 maxBytes 字节到内存（预览用；超限截断，标记 truncated）
    func sftpReadPrefix(_ sftp: OpaquePointer, path: String,
                        maxBytes: Int) throws -> (data: Data, truncated: Bool) {
        guard let handle = path.withCString({ p in
            libssh2_sftp_open_ex(sftp, p, UInt32(path.utf8.count), 1, 0, 0) // FXF_READ
        }) else {
            throw sftpFailure(sftp)
        }
        defer { libssh2_sftp_close_handle(handle) }
        var out = Data()
        out.reserveCapacity(min(maxBytes, 1 << 20))
        var buffer = [UInt8](repeating: 0, count: 32768)
        while out.count < maxBytes {
            let want = min(buffer.count, maxBytes - out.count)
            let n = buffer.withUnsafeMutableBytes { raw in
                libssh2_sftp_read(handle, raw.baseAddress?.assumingMemoryBound(to: CChar.self), want)
            }
            if n <= 0 { break }
            out.append(contentsOf: buffer.prefix(n))
        }
        return (out, truncated: out.count >= maxBytes)
    }

    /// 读远端文件指定区间 [offset, offset+length) 到回调（并行分块下载用；
    /// 读到 EOF 提前结束）。每块由调用方在独立连接上开
    func sftpReadRange(_ sftp: OpaquePointer, path: String, offset: UInt64, length: UInt64,
                       onChunk: (UnsafeBufferPointer<UInt8>, Int) throws -> Void) throws {
        guard let handle = path.withCString({ p in
            libssh2_sftp_open_ex(sftp, p, UInt32(path.utf8.count), 1, 0, 0) // FXF_READ
        }) else {
            throw sftpFailure(sftp)
        }
        defer { libssh2_sftp_close_handle(handle) }
        libssh2_sftp_seek64(handle, offset)
        var remaining = length
        var buffer = [UInt8](repeating: 0, count: 32768)
        while remaining > 0 {
            let want = Int(min(UInt64(buffer.count), remaining))
            let n = buffer.withUnsafeMutableBytes { raw in
                libssh2_sftp_read(handle, raw.baseAddress?.assumingMemoryBound(to: CChar.self), want)
            }
            if n > 0 {
                try buffer.withUnsafeBytes { raw in
                    try onChunk(UnsafeBufferPointer(start: raw.baseAddress?.assumingMemoryBound(to: UInt8.self), count: n), n)
                }
                remaining -= UInt64(n)
            } else if n == 0 {
                break // EOF（远端比预期短）
            } else {
                throw SSHClientError.channelFailed(code: -8)
            }
        }
    }

    /// 远端文件属性（断点续传决策用）；不存在时抛 sftpProtocol(2)
    struct SFTPStat {
        let size: UInt64
        let mtime: UInt64
        let atime: UInt64
        let permissions: UInt32 // 含类型高位（0o170000）
        let uid: UInt32
        let gid: UInt32
    }

    func sftpStat(_ sftp: OpaquePointer, path: String) throws -> SFTPStat {
        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        let rc = path.withCString { p in
            libssh2_sftp_stat_ex(sftp, p, UInt32(strlen(p)), 1, &attrs) // 1 = LIBSSH2_SFTP_STAT（宏常量）
        }
        guard rc == 0 else { throw sftpFailure(sftp) }
        // flags 位：1=SIZE 2=UIDGID 4=PERMISSIONS 8=ACMODTIME
        return SFTPStat(size: (attrs.flags & 1) != 0 ? attrs.filesize : 0,
                        mtime: (attrs.flags & 8) != 0 ? UInt64(attrs.mtime) : 0,
                        atime: (attrs.flags & 8) != 0 ? UInt64(attrs.atime) : 0,
                        permissions: (attrs.flags & 4) != 0 ? UInt32(attrs.permissions) : 0,
                        uid: (attrs.flags & 2) != 0 ? UInt32(attrs.uid) : 0,
                        gid: (attrs.flags & 2) != 0 ? UInt32(attrs.gid) : 0)
    }

    /// 下载；resumeFrom > 0 时远端 seek 到断点、本地追加（调用方保证断点 = 本地已传字节数）。
    /// progress 每个分块前回调（返回 false 取消，抛 TransferCancelled）
    func sftpDownload(_ sftp: OpaquePointer, remote: String, to local: URL,
                      resumeFrom: UInt64 = 0, progress: ((UInt64) -> Bool)? = nil) throws {
        guard let handle = remote.withCString({ p in
            libssh2_sftp_open_ex(sftp, p, UInt32(remote.utf8.count), 1, 0, 0) // FXF_READ, OPENFILE
        }) else {
            throw sftpFailure(sftp)
        }
        defer { libssh2_sftp_close_handle(handle) }
        if resumeFrom > 0 { libssh2_sftp_seek64(handle, resumeFrom) }
        // 本地父目录可能不存在（临时目录每次启动会被清理），先建目录再落文件
        do {
            try FileManager.default.createDirectory(at: local.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            throw SSHClientError.localFileFailed(L("无法创建目录 %@", local.deletingLastPathComponent().path))
        }
        let fm = FileManager.default
        let out: FileHandle
        if resumeFrom > 0, fm.fileExists(atPath: local.path) {
            guard let h = try? FileHandle(forUpdatingAtPath: local.path) else {
                throw SSHClientError.localFileFailed(L("无法续写 %@", local.path))
            }
            h.seekToEndOfFile()
            out = h
        } else {
            fm.createFile(atPath: local.path, contents: nil) // 截断旧文件全量重下
            guard let h = try? FileHandle(forWritingTo: local) else {
                throw SSHClientError.localFileFailed(L("无法写入 %@", local.path))
            }
            out = h
        }
        defer { try? out.close() }
        var done = resumeFrom
        var buffer = [UInt8](repeating: 0, count: 32768)
        while true {
            if let progress, !progress(done) { throw TransferCancelled() }
            let n = buffer.withUnsafeMutableBytes { raw in
                libssh2_sftp_read(handle, raw.baseAddress?.assumingMemoryBound(to: CChar.self), raw.count)
            }
            if n > 0 {
                out.write(Data(bytes: buffer.prefix(n)))
                done += UInt64(n)
            } else if n == 0 { break }
            else { throw SSHClientError.channelFailed(code: -8) }
        }
        if let progress { _ = progress(done) } // 终值回报（进度条走到 100%）
    }

    /// 上传；resumeFrom > 0 时远端 seek 到断点续写（不 TRUNC），否则 TRUNC 全量重传。
    /// 流式分块读写，不再整文件读入内存；progress 每个分块前回调（返回 false 取消）
    func sftpUpload(_ sftp: OpaquePointer, local: URL, to remote: String,
                    resumeFrom: UInt64 = 0, progress: ((UInt64) -> Bool)? = nil) throws {
        guard let input = try? FileHandle(forReadingFrom: local) else {
            throw SSHClientError.localFileFailed(L("无法读取 %@", local.path))
        }
        defer { try? input.close() }
        let flags: UInt = resumeFrom > 0 ? 2 | 8 : 2 | 8 | 16 // 续传 WRITE|CREAT；全新加 TRUNC
        guard let handle = remote.withCString({ p in
            libssh2_sftp_open_ex(sftp, p, UInt32(remote.utf8.count), flags, 420, 0) // 0644
        }) else {
            throw sftpFailure(sftp)
        }
        defer { libssh2_sftp_close_handle(handle) }
        if resumeFrom > 0 {
            input.seek(toFileOffset: resumeFrom)
            libssh2_sftp_seek64(handle, resumeFrom)
        }
        var done = resumeFrom
        while true {
            if let progress, !progress(done) { throw TransferCancelled() }
            let chunk = input.readData(ofLength: 65536)
            if chunk.isEmpty { break }
            let sent = chunk.withUnsafeBytes { raw -> Int in
                libssh2_sftp_write(handle, raw.baseAddress!.assumingMemoryBound(to: CChar.self), raw.count)
            }
            guard sent > 0 else { throw SSHClientError.channelFailed(code: -9) }
            done += UInt64(sent)
            if sent < chunk.count {
                // 部分写入（窗口限制）：读位置回到已确认偏移，下轮续写剩余
                input.seek(toFileOffset: done)
            }
        }
        if let progress { _ = progress(done) }
    }

    func sftpMkdir(_ sftp: OpaquePointer, path: String) throws {
        let rc = path.withCString { p in
            libssh2_sftp_mkdir_ex(sftp, p, UInt32(strlen(p)), 493) // 0755
        }
        guard rc == 0 else {
            throw sftpFailure(sftp)
        }
    }

    /// 新建空文件（WRITE|CREAT 打开后立即关闭）
    func sftpCreateFile(_ sftp: OpaquePointer, path: String) throws {
        guard let handle = path.withCString({ p in
            libssh2_sftp_open_ex(sftp, p, UInt32(strlen(p)), 2 | 8, 420, 0) // WRITE|CREAT, 0644
        }) else {
            throw sftpFailure(sftp)
        }
        libssh2_sftp_close_handle(handle)
    }

    func sftpUnlink(_ sftp: OpaquePointer, path: String) throws {
        let rc = path.withCString { p in
            libssh2_sftp_unlink_ex(sftp, p, UInt32(strlen(p)))
        }
        guard rc == 0 else {
            throw sftpFailure(sftp)
        }
    }

    func sftpRmdir(_ sftp: OpaquePointer, path: String) throws {
        let rc = path.withCString { p in
            libssh2_sftp_rmdir_ex(sftp, p, UInt32(strlen(p)))
        }
        guard rc == 0 else {
            throw sftpFailure(sftp)
        }
    }

    func sftpRename(_ sftp: OpaquePointer, from: String, to: String) throws {
        let rc = from.withCString { src in
            to.withCString { dst in
                libssh2_sftp_rename_ex(sftp, src, UInt32(strlen(src)), dst, UInt32(strlen(dst)), 5) // OVERWRITE|NATIVE
            }
        }
        guard rc == 0 else {
            throw sftpFailure(sftp)
        }
    }

    // MARK: direct-tcpip 通道（本地端口转发；通道上的读写由 PortForwardService 在
    // 独占队列上以非阻塞模式驱动，EAGAIN 语义与事件循环一致）

    /// 开一条 direct-tcpip 通道（阻塞模式调用；连到 targetHost:targetPort，
    /// origin 为发起方标识，远端审计可见）。失败抛 channelFailed
    func openDirectTCPIP(targetHost: String, targetPort: Int,
                         originHost: String, originPort: Int) throws -> OpaquePointer {
        guard let session else { throw SSHClientError.disconnectedForSftp }
        // 签名：libssh2_channel_direct_tcpip_ex(session, host, port, shost, sport)
        let channel = targetHost.withCString { target in
            originHost.withCString { origin in
                libssh2_channel_direct_tcpip_ex(session, target,
                                                Int32(targetPort), origin, Int32(originPort))
            }
        }
        guard let channel else {
            throw SSHClientError.channelFailed(code: libssh2_session_last_errno(session))
        }
        return channel
    }

    /// 会话阻塞模式切换（转发 worker 在非阻塞下 poll 驱动）
    func setBlocking(_ blocking: Bool) {
        guard let session else { return }
        _ = libssh2_session_set_blocking(session, blocking ? 1 : 0)
    }

    /// 非阻塞读通道（stdout 流）；返回 n>0 数据 / 0 EOF / errorEAGAIN 无数据 / 负值错误
    func forwardRead(_ channel: OpaquePointer, into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        libssh2_channel_read_ex(channel, 0,
                                buffer.assumingMemoryBound(to: CChar.self), count)
    }

    /// 非阻塞写通道；返回已写字节 / errorEAGAIN / 负值错误
    func forwardWrite(_ channel: OpaquePointer, bytes: UnsafeRawBufferPointer) -> Int {
        libssh2_channel_write_ex(channel, 0,
                                 bytes.baseAddress?.assumingMemoryBound(to: CChar.self), bytes.count)
    }

    /// 转发通道收尾：EOF + 关闭 + 释放
    func closeForwardChannel(_ channel: OpaquePointer) {
        _ = libssh2_channel_send_eof(channel)
        libssh2_channel_close(channel)
        libssh2_channel_free(channel)
    }

    /// 该连接是否还活着（转发 worker 判死用）
    var isAlive: Bool { session != nil }

    /// 在该 SSH 连接上跑一次性命令（阻塞），返回 (退出码, 输出)——压缩/解压等远端操作用
    func exec(_ command: String) throws -> (code: Int32, output: String) {        guard let session else { throw SSHClientError.disconnectedForSftp }
        guard let channel = libssh2_channel_open_ex(session, "session", 7,
                                                    LibSSH2.channelWindowDefault,
                                                    LibSSH2.channelPacketDefault, nil, 0) else {
            throw SSHClientError.channelFailed(code: libssh2_session_last_errno(session))
        }
        defer {
            libssh2_channel_close(channel)
            libssh2_channel_wait_closed(channel)
            libssh2_channel_free(channel)
        }
        let rc = command.withCString { cmd in
            libssh2_channel_process_startup(channel, "exec", 4, cmd, UInt32(strlen(cmd)))
        }
        guard rc == 0 else { throw SSHClientError.channelFailed(code: rc) }
        var output = ""
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = buffer.withUnsafeMutableBytes { raw in
                libssh2_channel_read_ex(channel, 0, raw.baseAddress?.assumingMemoryBound(to: CChar.self), raw.count)
            }
            if n > 0 { output += String(decoding: buffer.prefix(n), as: UTF8.self) }
            else if n == 0 { break }
            else if n == LibSSH2.errorEagain { usleep(50_000) }
            else { break }
        }
        libssh2_channel_wait_closed(channel)
        return (libssh2_channel_get_exit_status(channel), output)
    }
}

// 极简原子布尔（关闭标记跨线程读写）
final class AtomicFlag {
    private let lock = NSLock()
    private var raw = false
    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return raw
    }
    func set() {
        lock.lock(); raw = true; lock.unlock()
    }
}

import AppKit
import Darwin
import Foundation
import SwiftTerm
import PicotermCore

// Telnet 会话（TODO 15 素材，Ported from Termind (GPL-3) TelnetConnection 的
// 协商口径 — github.com/AkinoKaede/Termind）：POSIX socket + 最小 RFC 854 协商。
// 只主动 WILL NAWS / WILL SGA：对端 DO NAWS 即周期上报窗口尺寸（resize 即时上报），
// 其余 DO/WILL 一律 WONT/DONT 拒绝——终端行编辑/回显交给远端 login 处理，
// 不代答 ECHO/SGA 之外的选项，兼容 busybox telnetd/路由器控制台。
@MainActor
final class TelnetSession: NSObject, TerminalSession, TerminalViewDelegate {
    let id = UUID()
    var onStateChanged: (() -> Void)?
    private(set) var state: SessionState = .running
    private(set) var terminalSize: (cols: Int, rows: Int)?
    private let tv: TerminalView
    let config: TelnetEndpoint

    private let queue = DispatchQueue(label: "picoterm.telnet.session", qos: .userInitiated)
    private var sock: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var pendingOut: [UInt8] = []
    private var outLock = NSLock()
    /// 输出解码（GBK 等老编码 telnet 服务器常见）
    private var outputDecoder: RemoteCharsetStreamConverter?
    private var charsetInitialized = false

    struct TelnetEndpoint {
        let host: String
        let port: UInt16
        let charset: RemoteCharset

        var identity: String { "telnet://\(host):\(port)" }
    }

    init(endpoint: TelnetEndpoint) {
        tv = TerminalView(frame: .zero)
        config = endpoint
        super.init()
        AppTheme.apply(to: tv)
        tv.terminalDelegate = self
        tv.feed(text: L("[picoterm] 正在连接 %1$@:%2$ld …\r\n", endpoint.host, endpoint.port))
        connect()
    }

    var title: String { state == .running ? "Telnet \(config.host):\(config.port)" : L("Telnet %1$@（已断开）", config.host) }
    var symbol: String { "network" }
    var terminalView: NSView { tv }

    func terminate() {
        guard state == .running else { return }
        markExited(message: L("[picoterm] 连接已断开\r\n"))
    }

    func injectInput(_ bytes: [UInt8]) {
        enqueueWrite(bytes)
    }

    // MARK: 连接

    private func connect() {
        queue.async { [self] in
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(config.host, String(config.port), &hints, &res) == 0, let first = res else {
                MainThread.perform { self.markExited(message: L("[picoterm] 无法解析主机地址\r\n")) }
                return
            }
            defer { freeaddrinfo(res) }

            var info: UnsafeMutablePointer<addrinfo>? = first
            var fd: Int32 = -1
            while let p = info {
                defer { info = p.pointee.ai_next }
                fd = socket(p.pointee.ai_family, p.pointee.ai_socktype, p.pointee.ai_protocol)
                guard fd >= 0 else { continue }
                // 非阻塞 connect + 10s 超时（与 SSHClient.connectSocket 同款口径）
                let flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                let rc = Darwin.connect(fd, p.pointee.ai_addr, p.pointee.ai_addrlen)
                var connected = rc == 0
                if !connected, errno == EINPROGRESS {
                    var pfd = [pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)]
                    if poll(&pfd, 1, 10_000) > 0 {
                        var err: Int32 = 0
                        var len = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                        connected = err == 0
                    }
                }
                if connected {
                    _ = fcntl(fd, F_SETFL, flags) // 恢复阻塞，读事件由 DispatchSource 驱动
                    break
                }
                Darwin.close(fd)
                fd = -1
            }
            guard fd >= 0 else {
                MainThread.perform { self.markExited(message: L("[picoterm] 无法建立 TCP 连接\r\n")) }
                return
            }
            queue.async { [self] in startReading(fd) }
        }
    }

    private func startReading(_ fd: Int32) {
        sock = fd
        // 开场协商：WILL NAWS（窗口上报）+ WILL SGA
        enqueueRaw(Self.iacWill(31))
        enqueueRaw(Self.iacWill(3))
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        source.resume()
        readSource = source
        MainThread.perform { self.tv.feed(text: L("\r[picoterm] 已连接\r\n")) }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 16384)
        let n = buffer.withUnsafeMutableBytes { raw in
            read(sock, raw.baseAddress, raw.count)
        }
        guard n > 0 else {
            // 0 = 对端关闭；负值非 EAGAIN 也按断开处理
            MainThread.perform { self.markExited(message: L("[picoterm] 连接已断开\r\n")) }
            return
        }
        let (data, replies) = Self.negotiate(Array(buffer.prefix(n)))
        if !replies.isEmpty {
            enqueueRaw(replies)
        }
        guard !data.isEmpty else { return }
        let decoded = decodeForOutput(data)
        MainThread.perform { self.tv.feed(byteArray: decoded[...]) }
    }

    // MARK: RFC 854 协商（IAC 处理，Ported from Termind TelnetProtocolParser 的应答策略）

    private static let iac: UInt8 = 255
    private static let will: UInt8 = 251
    private static let wont: UInt8 = 252
    private static let doCmd: UInt8 = 253
    private static let dont: UInt8 = 254
    private static let sb: UInt8 = 250
    private static let se: UInt8 = 240
    /// 选项：1=ECHO 3=SGA 31=NAWS
    private static let optSuppressGoAhead: UInt8 = 3
    private static let optNaws: UInt8 = 31

    private static func iacWill(_ opt: UInt8) -> [UInt8] { [iac, will, opt] }
    private static func iacWont(_ opt: UInt8) -> [UInt8] { [iac, wont, opt] }
    private static func iacDo(_ opt: UInt8) -> [UInt8] { [iac, doCmd, opt] }
    private static func iacDont(_ opt: UInt8) -> [UInt8] { [iac, dont, opt] }

    /// 从字节流剥离 IAC 序列并生成应答。应答策略：
    /// DO NAWS/SGA → WILL；其他 DO → WONT；WILL SGA/ECHO → DO（远端回显）；
    /// 其他 WILL → DONT；IAC IAC → 数据 0xFF
    static func negotiate(_ input: [UInt8]) -> (data: [UInt8], replies: [UInt8]) {
        var data: [UInt8] = []
        data.reserveCapacity(input.count)
        var replies: [UInt8] = []
        var i = 0
        while i < input.count {
            guard input[i] == iac else {
                data.append(input[i])
                i += 1
                continue
            }
            guard i + 1 < input.count else { break } // 悬挂 IAC：丢弃（等下一块，保守拼不上）
            let cmd = input[i + 1]
            switch cmd {
            case iac:
                data.append(iac)
                i += 2
            case will:
                guard i + 2 < input.count else { return (data, replies) }
                let opt = input[i + 2]
                replies += (opt == optSuppressGoAhead || opt == 1) ? iacDo(opt) : iacDont(opt)
                i += 3
            case wont:
                guard i + 2 < input.count else { return (data, replies) }
                i += 3 // 无需应答
            case doCmd:
                guard i + 2 < input.count else { return (data, replies) }
                let opt = input[i + 2]
                replies += (opt == optNaws || opt == optSuppressGoAhead) ? iacWill(opt) : iacWont(opt)
                i += 3
            case dont:
                guard i + 2 < input.count else { return (data, replies) }
                i += 3
            case sb: // 子协商：整段找到 IAC SE；TERMINAL-TYPE(24) SEND(1) 应答 IS xterm-256color
                var j = i + 2
                var closed = false
                while j + 1 < input.count {
                    if input[j] == iac, input[j + 1] == se {
                        closed = true
                        break
                    }
                    j += 1
                }
                guard closed else { return (data, replies) } // 未完子协商：剩余整块丢弃（低频路径）
                let bodyStart = i + 2
                let body = Array(input[bodyStart..<j]) // 不含 IAC SE
                if body.count >= 2, body[0] == 24, body[1] == 1 { // TERMINAL-TYPE SEND
                    replies += [iac, sb, 24, 0] + Array("xterm-256color".utf8) + [iac, se]
                }
                i = j + 2
            default:
                i += 2 // 两字节命令（AYT/IP 等）
            }
        }
        return (data, replies)
    }

    // MARK: 写入

    func enqueueWrite(_ bytes: [UInt8]) {
        // 数据中的 0xFF 必须转义为 IAC IAC（RFC 854）
        let escaped = bytes.flatMap { $0 == Self.iac ? [Self.iac, Self.iac] : [$0] }
        outLock.lock()
        pendingOut.append(contentsOf: escaped)
        outLock.unlock()
        queue.async { [self] in flushOutgoing() }
    }

    /// 应答/协商字节入队（可能从主线程调）：锁内追加，队列上冲刷
    private func enqueueRaw(_ bytes: [UInt8]) {
        outLock.lock()
        pendingOut.append(contentsOf: bytes)
        outLock.unlock()
        queue.async { [self] in flushOutgoing() }
    }

    private func flushOutgoing() {
        outLock.lock()
        let chunk = pendingOut
        pendingOut = []
        outLock.unlock()
        guard !chunk.isEmpty, sock >= 0 else { return }
        var offset = 0
        while offset < chunk.count {
            let sent = chunk.withUnsafeBytes { raw in
                write(sock, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            }
            if sent > 0 {
                offset += sent
            } else if errno == EAGAIN {
                queue.asyncAfter(deadline: .now() + 0.01) { [self] in flushOutgoing() }
                // 未发完的塞回队头
                outLock.lock()
                pendingOut.insert(contentsOf: chunk[offset...], at: 0)
                outLock.unlock()
                return
            } else {
                MainThread.perform { self.markExited(message: L("[picoterm] 连接已断开\r\n")) }
                return
            }
        }
    }

    /// 远端 NAWS 上报：IAC SB NAWS <宽高 16 位大端> IAC SE
    private func sendNaws(cols: Int, rows: Int) {
        func hibyte(_ v: Int) -> UInt8 { UInt8((v >> 8) & 0xFF) }
        func lobyte(_ v: Int) -> UInt8 { UInt8(v & 0xFF) }
        enqueueRaw([Self.iac, Self.sb, Self.optNaws,
                    hibyte(cols), lobyte(cols), hibyte(rows), lobyte(rows),
                    Self.iac, Self.se])
    }

    // MARK: 字符集（与 SSHSession 同款口径）

    private func decodeForOutput(_ bytes: [UInt8]) -> [UInt8] {
        guard config.charset != .utf8 else { return bytes }
        if !charsetInitialized {
            outputDecoder = try? RemoteCharsetStreamConverter(charset: config.charset, direction: .decoding)
            charsetInitialized = true
        }
        guard let decoder = outputDecoder else { return bytes }
        return Array((try? decoder.convert(Data(bytes)))?.data ?? Data(bytes))
    }

    private func encodeForWire(_ bytes: [UInt8]) -> [UInt8] {
        guard config.charset != .utf8,
              let encoder = try? RemoteCharsetStreamConverter(charset: config.charset, direction: .encoding) else {
            return bytes
        }
        return Array((try? encoder.convert(Data(bytes)))?.data ?? Data(bytes))
    }

    private func markExited(message: String?) {
        if let message { tv.feed(text: message) }
        guard state == .running else { return }
        state = .exited
        readSource?.cancel()
        readSource = nil
        onStateChanged?()
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        enqueueWrite(encodeForWire([UInt8](data)))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        tv.applyScrollbackSetting()
        terminalSize = (newCols, newRows)
        NotificationCenter.default.post(name: .terminalSizeChanged, object: self)
        sendNaws(cols: newCols, rows: newRows)
    }

    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// Telnet 无文件通道：只放行网页类链接，路径点击无动作
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if case .web(let url) = LinkOpenPolicy.classify(link, isRemote: true, currentDirectory: nil, home: nil) {
            NSWorkspace.shared.open(url)
        }
    }

    func bell(source: TerminalView) {
        if AppSettings.shared.bellEnabled { NSSound.beep() }
    }
}

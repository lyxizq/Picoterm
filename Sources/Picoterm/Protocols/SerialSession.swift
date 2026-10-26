import AppKit
import Darwin
import Foundation
import SwiftTerm
import PicotermCore

// 串口会话（TODO 15 素材；Termind SerialConnection 同款定位——macOS 侧 /dev/tty.* 直连）：
// POSIX termios 配置（原始模式 + 波特率），DispatchSourceRead 驱动读，
// 换行 \r\n 由终端视图自身处理（TerminalView 对 CR/LF 敏感，这里不再做行规程加工）。
@MainActor
final class SerialSession: NSObject, TerminalSession, TerminalViewDelegate {
    let id = UUID()
    var onStateChanged: (() -> Void)?
    private(set) var state: SessionState = .running
    private(set) var terminalSize: (cols: Int, rows: Int)?
    private let tv: TerminalView

    let devicePath: String
    let baudRate: Int
    let charset: RemoteCharset

    private let queue = DispatchQueue(label: "picoterm.serial.session", qos: .userInitiated)
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var outputDecoder: RemoteCharsetStreamConverter?
    private var wireEncoder: RemoteCharsetStreamConverter?

    init(devicePath: String, baudRate: Int, charset: RemoteCharset) {
        tv = TerminalView(frame: .zero)
        self.devicePath = devicePath
        self.baudRate = baudRate
        self.charset = charset
        super.init()
        AppTheme.apply(to: tv)
        tv.terminalDelegate = self
        tv.feed(text: L("[picoterm] 打开串口 %1$@ @ %2$ld …\r\n", devicePath, baudRate))
        openDevice()
    }

    var title: String { state == .running ? L("串口 %@", (devicePath as NSString).lastPathComponent) : L("串口（已断开）") }
    var symbol: String { "cable.connector" }
    var terminalView: NSView { tv }

    func terminate() {
        guard state == .running else { return }
        markExited(message: L("[picoterm] 串口已关闭\r\n"))
    }

    func injectInput(_ bytes: [UInt8]) {
        writeRaw(encodeForWire(bytes))
    }

    // MARK: 打开与配置

    private static func baudConstant(_ rate: Int) -> speed_t? {
        // 常用波特率表（termios 常量为宏，Swift 不可直接 switch）
        let table: [Int: speed_t] = [
            9600: speed_t(B9600), 19200: speed_t(B19200), 38400: speed_t(B38400),
            57600: speed_t(B57600), 115200: speed_t(B115200), 230400: speed_t(B230400),
        ]
        return table[rate]
    }

    private func openDevice() {
        let path = devicePath
        let rate = baudRate
        queue.async { [self] in
            let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
            guard fd >= 0 else {
                let reason = errno == EBUSY ? L("设备被占用") : L("无法打开设备（权限不足或不存在）")
                MainThread.perform {
                    self.markExited(message: L("[picoterm] %1$@：%2$@\r\n", reason, path))
                }
                return
            }
            guard let speed = Self.baudConstant(rate) else {
                Darwin.close(fd)
                MainThread.perform {
                    self.markExited(message: L("[picoterm] 不支持的波特率：%ld\r\n", rate))
                }
                return
            }
            var termiosState = termios()
            guard tcgetattr(fd, &termiosState) == 0 else {
                Darwin.close(fd)
                MainThread.perform {
                    self.markExited(message: L("[picoterm] 无法读取串口属性（不是串口设备？）\r\n"))
                }
                return
            }
            // 原始模式：无行规程、无回显、8N1、无流控（cfmakeraw 后显式开接收）
            cfmakeraw(&termiosState)
            cfsetspeed(&termiosState, speed)
            let flag = tcflag_t(CREAD) | tcflag_t(CLOCAL)
            termiosState.c_cflag |= flag
            termiosState.c_cflag &= ~tcflag_t(CSIZE)
            termiosState.c_cflag |= tcflag_t(CS8)
            termiosState.c_cflag &= ~(tcflag_t(PARENB) | tcflag_t(CSTOPB) | tcflag_t(CRTSCTS))
            termiosState.c_cc.6 = 1  // VMIN
            termiosState.c_cc.7 = 0  // VTIME
            guard tcsetattr(fd, TCSANOW, &termiosState) == 0 else {
                Darwin.close(fd)
                MainThread.perform {
                    self.markExited(message: L("[picoterm] 无法配置串口\r\n"))
                }
                return
            }
            tcflush(fd, TCIOFLUSH)
            startReading(fd)
        }
    }

    private func startReading(_ fd: Int32) {
        self.fd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        source.resume()
        readSource = source
        MainThread.perform { self.tv.feed(text: L("\r[picoterm] 串口已打开，直接输入即可交互（退出请关闭标签）\r\n")) }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = buffer.withUnsafeMutableBytes { raw in
            read(fd, raw.baseAddress, raw.count)
        }
        guard n > 0 else {
            if n == 0 || errno != EAGAIN {
                MainThread.perform { self.markExited(message: L("[picoterm] 串口已断开\r\n")) }
            }
            return
        }
        let decoded = decodeForOutput(Array(buffer.prefix(n)))
        MainThread.perform { self.tv.feed(byteArray: decoded[...]) }
    }

    // MARK: 写入（锁保护的单 fd 直写；串口吞吐低，无需缓冲队列）

    private let writeLock = NSLock()

    private func writeRaw(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, fd >= 0, state == .running else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            }
            if sent > 0 {
                offset += sent
            } else if errno == EAGAIN {
                usleep(2_000) // 短等重试（串口 115200 下 4KB 极少需要）
            } else {
                return
            }
        }
    }

    // MARK: 字符集（与 SSHSession 同款口径）

    private func decodeForOutput(_ bytes: [UInt8]) -> [UInt8] {
        guard charset != .utf8 else { return bytes }
        if outputDecoder == nil {
            outputDecoder = try? RemoteCharsetStreamConverter(charset: charset, direction: .decoding)
        }
        guard let decoder = outputDecoder else { return bytes }
        return Array((try? decoder.convert(Data(bytes)))?.data ?? Data(bytes))
    }

    private func encodeForWire(_ bytes: [UInt8]) -> [UInt8] {
        guard charset != .utf8 else { return bytes }
        if wireEncoder == nil {
            wireEncoder = try? RemoteCharsetStreamConverter(charset: charset, direction: .encoding)
        }
        guard let encoder = wireEncoder else { return bytes }
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
        writeRaw(encodeForWire([UInt8](data)))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        tv.applyScrollbackSetting()
        terminalSize = (newCols, newRows)
        NotificationCenter.default.post(name: .terminalSizeChanged, object: self)
        // 串口无窗口尺寸概念，不上报
    }

    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }
    }

    func bell(source: TerminalView) {
        if AppSettings.shared.bellEnabled { NSSound.beep() }
    }
}

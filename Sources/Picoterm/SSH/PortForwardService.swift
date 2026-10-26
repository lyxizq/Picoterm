import Foundation
import Darwin
import PicotermCore

// 本地端口转发服务（Ported from Termind (GPL-3) PortForwardingController 的
// 多连接口径 — github.com/AkinoKaede/Termind，适配本工程 libssh2 栈）：
//
// - 每条规则一个 RuleRuntime：本地 listener + N 条独立 SSH 连接（凭据口径复用
//   SFTPService.makeConnectedClient），accept 后分给通道数最少的 worker——
//   N 条连接各自承载独立的 direct-tcpip 通道，互不阻塞，吞吐随连接数提升
//   （Termind 实测 12 连接 2.54×）。
// - worker = 每条 SSH 连接一个串行队列 + poll 循环（wake pipe + 各本地 fd），
//   非阻塞 channel 读写（EAGAIN 语义与 SSHClient 事件循环一致）。
// - 单侧 EOF 即关整条通道（转发场景无半关重用价值），断连只影响该通道。
//
// 线程口径：libssh2 会话绝不跨线程共享——每条 worker 的 session 只在其队列上碰；
// 活跃通道计数用独立小锁（绝不 queue.sync 到 worker 队列：泵是长跑循环会死锁）。

@MainActor
final class PortForwardService {
    static let shared = PortForwardService()

    /// 规则运行状态（主线程读）
    enum RuleState: Equatable {
        case stopped
        case running(activeConnections: Int)
        case failed(String)

        var label: String {
            switch self {
            case .stopped: L("已停止")
            case .running(let active): L("运行中 · %ld 连接", active)
            case .failed(let reason): L("失败：%@", reason)
            }
        }
    }

    private var runtimes: [UUID: RuleRuntime] = [:]
    private(set) var states: [UUID: RuleState] = [:]
    /// 状态变化通知（主线程回调）
    var onStateChanged: ((UUID, RuleState) -> Void)?

    /// 应用全部启用的规则（启动/规则变化时调用；已运行的按 id 幂等跳过）
    func applyRules() {
        let rules = PortForwardStore.shared.rules
        let enabledIds = Set(rules.filter(\.enabled).map(\.id))
        for (id, runtime) in runtimes where !enabledIds.contains(id) {
            runtime.stop()
            runtimes.removeValue(forKey: id)
            states[id] = .stopped
            onStateChanged?(id, .stopped)
        }
        for rule in rules where rule.enabled && runtimes[rule.id] == nil {
            let runtime = RuleRuntime(rule: rule) { [weak self] id, state in
                guard let self else { return }
                self.states[id] = state
                self.onStateChanged?(id, state)
            }
            runtimes[rule.id] = runtime
            states[rule.id] = .running(activeConnections: 0)
            onStateChanged?(rule.id, .running(activeConnections: 0))
            runtime.start()
        }
    }

    /// 单条规则启停切换
    func toggle(rule: PortForwardRule) {
        if let runtime = runtimes[rule.id] {
            runtime.stop()
            runtimes.removeValue(forKey: rule.id)
            states[rule.id] = .stopped
            onStateChanged?(rule.id, .stopped)
        } else {
            PortForwardStore.shared.setEnabled(true, id: rule.id)
            applyRules()
        }
    }

    func stopAll() {
        for (_, runtime) in runtimes { runtime.stop() }
        runtimes.removeAll()
    }
}

// MARK: - 单条规则的运行时（listener + N worker）

private final class RuleRuntime {
    private let rule: PortForwardRule
    private let report: (UUID, PortForwardService.RuleState) -> Void
    private let queue = DispatchQueue(label: "picoterm.forward.rule", qos: .utility)

    private var listenerFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let workerLock = NSLock()
    private var workers: [ForwardWorker] = []
    private var stopped = false
    /// 上报节流：通道数变化才上报（accept/close 风暴时省主线程通知）
    private var lastReportedCount = -1

    init(rule: PortForwardRule, report: @escaping (UUID, PortForwardService.RuleState) -> Void) {
        self.rule = rule
        self.report = report
    }

    func start() {
        queue.async { [self] in
            guard let entry = HostStore.shared.hosts.first(where: { $0.id == rule.hostEntryId }) else {
                return fail(L("主机条目不存在"))
            }
            let (config, needsSecret) = HostStore.shared.sshConfig(for: entry)
            guard !needsSecret else {
                return fail(L("主机未存密码（先成功连一次 SSH）"))
            }

            // 本地监听（SO_REUSEADDR：TIME_WAIT 后可立即重启）
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return fail(L("无法创建监听 socket")) }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(rule.bindPort).bigEndian
            if inet_pton(AF_INET, rule.bindHost, &addr.sin_addr) != 1 {
                Darwin.close(fd)
                return fail(L("监听地址无效：%@", rule.bindHost))
            }
            let bound = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else {
                Darwin.close(fd)
                return fail(L("端口 %ld 被占用或无权限绑定", Int(rule.bindPort)))
            }
            guard listen(fd, 64) == 0 else {
                Darwin.close(fd)
                return fail(L("无法监听 %ld", Int(rule.bindPort)))
            }
            listenerFd = fd

            // N 条 SSH 连接 worker（建连失败降级到能建成的条数，至少 1）
            let wanted = max(1, min(12, rule.parallelConnections))
            workerLock.lock()
            for _ in 0..<wanted {
                guard let worker = ForwardWorker(rule: rule, config: config) else { continue }
                workers.append(worker)
                worker.start()
            }
            let workerCount = workers.count
            workerLock.unlock()
            guard workerCount > 0 else {
                Darwin.close(fd)
                listenerFd = -1
                return fail(L("SSH 连接失败（主机不可达或认证失败）"))
            }

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptPending() }
            source.setCancelHandler { [fd] in Darwin.close(fd) }
            source.resume()
            acceptSource = source
        }
    }

    private func fail(_ reason: String) {
        MainThread.perform { [self] in
            report(rule.id, .failed(reason))
        }
    }

    private func acceptPending() {
        while !stopped {
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(listenerFd, &addr, &len)
            guard client >= 0 else { return }
            workerLock.lock()
            let worker = workers.min { $0.channelCount < $1.channelCount }
            workerLock.unlock()
            guard let worker else {
                Darwin.close(client)
                return
            }
            worker.adopt(clientFd: client) { [weak self] in
                self?.reportActive()
            }
        }
    }

    private func reportActive() {
        workerLock.lock()
        let count = workers.reduce(0) { $0 + $1.channelCount }
        workerLock.unlock()
        guard count != lastReportedCount else { return }
        lastReportedCount = count
        let ruleId = rule.id
        MainThread.perform { [self] in
            report(ruleId, .running(activeConnections: count))
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            acceptSource?.cancel()
            acceptSource = nil
            workerLock.lock()
            let all = workers
            workers = []
            workerLock.unlock()
            all.forEach { $0.stop() }
            let ruleId = rule.id
            MainThread.perform { [self] in
                report(ruleId, .stopped)
            }
        }
    }
}

// MARK: - 单条 SSH 连接的转发 worker（通道泵）

private final class ForwardWorker {
    private let rule: PortForwardRule
    private let config: SSHConfig
    private let queue = DispatchQueue(label: "picoterm.forward.worker", qos: .userInitiated)
    private let client: SSHClient
    private var wakePipe: [Int32] = [-1, -1]
    private var stopped = false
    private var reported = false // 首次通道计数上报（收尾时清一次计数）

    // 活跃通道（本地 fd ↔ ssh channel）；tunnels 只在 worker 队列上碰
    private struct Tunnel {
        let localFd: Int32
        let channel: OpaquePointer
    }
    private var tunnels: [Tunnel] = []

    // 活跃计数：独立小锁（RuleRuntime 的 accept 侧读；绝不能 queue.sync——泵是长跑循环）
    private let countLock = NSLock()
    private var storedCount = 0
    var channelCount: Int {
        countLock.lock(); defer { countLock.unlock() }
        return storedCount
    }

    init?(rule: PortForwardRule, config: SSHConfig) {
        self.rule = rule
        self.config = config
        do {
            client = try SFTPService.makeConnectedClient(config: config)
        } catch {
            return nil
        }
        guard pipe(&wakePipe) == 0 else {
            client.teardown()
            return nil
        }
        for fd in wakePipe {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        }
    }

    func start() {
        queue.async { [self] in pumpLoop() }
    }

    /// accept 侧投递新连接（任意线程调）：开 direct-tcpip 通道并纳入泵
    func adopt(clientFd: Int32, onChange: @escaping () -> Void) {
        queue.async { [self] in
            guard !stopped else {
                Darwin.close(clientFd)
                return
            }
            let flags = fcntl(clientFd, F_GETFL, 0)
            _ = fcntl(clientFd, F_SETFL, flags | O_NONBLOCK)
            do {
                let channel = try client.openDirectTCPIP(
                    targetHost: rule.targetHost, targetPort: rule.targetPort,
                    originHost: "127.0.0.1", originPort: 0)
                client.setBlocking(false) // 泵全程非阻塞
                tunnels.append(Tunnel(localFd: clientFd, channel: channel))
                bumpCount(+1)
                wake()
                MainThread.perform(onChange)
            } catch {
                Darwin.close(clientFd)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            wake()
        }
    }

    private func bumpCount(_ delta: Int) {
        countLock.lock()
        storedCount = max(0, storedCount + delta)
        countLock.unlock()
    }

    private func wake() {
        if wakePipe[1] >= 0 { _ = write(wakePipe[1], "1", 1) }
    }

    /// poll 主循环：wake pipe + 各本地 fd；本地可读 → channel 写；
    /// channel 侧每轮全量非阻塞读 → 本地写；任一侧 EOF/错误即关整条通道
    private func pumpLoop() {
        var buffer = [UInt8](repeating: 0, count: 32768)
        var eagainRun = 0 // 连续 EAGAIN 轮数：超阈值拉长 poll 超时防忙转
        defer {
            for tunnel in tunnels {
                Darwin.close(tunnel.localFd)
                client.closeForwardChannel(tunnel.channel)
            }
            tunnels = []
            bumpCount(-storedCount)
            if wakePipe[0] >= 0 { Darwin.close(wakePipe[0]); wakePipe[0] = -1 }
            if wakePipe[1] >= 0 { Darwin.close(wakePipe[1]); wakePipe[1] = -1 }
            client.teardown()
        }

        while !stopped {
            var fds = [pollfd(fd: wakePipe[0], events: Int16(POLLIN), revents: 0)]
            for tunnel in tunnels {
                fds.append(pollfd(fd: tunnel.localFd, events: Int16(POLLIN) | Int16(POLLHUP), revents: 0))
            }
            let timeout: Int32 = eagainRun > 8 ? 50 : 20
            let pr = poll(&fds, nfds_t(fds.count), timeout)
            if stopped { break }
            if pr > 0, fds[0].revents & Int16(POLLIN) != 0 {
                var drain = [UInt8](repeating: 0, count: 64)
                while read(wakePipe[0], &drain, drain.count) > 0 {}
            }

            var eagainThisRound = false
            var nextTunnels: [Tunnel] = []
            nextTunnels.reserveCapacity(tunnels.count)

            // 本地 → 远端
            if pr > 0 {
                var index = 1
                pumpLocal: for tunnel in tunnels {
                    defer { index += 1 }
                    let events = index < fds.count ? fds[index].revents : 0
                    if events & (Int16(POLLIN) | Int16(POLLHUP)) == 0 {
                        nextTunnels.append(tunnel)
                        continue
                    }
                    let n = read(tunnel.localFd, &buffer, buffer.count)
                    if n > 0 {
                        var offset = 0
                        while offset < n {
                            let sent = buffer.withUnsafeBytes { raw in
                                client.forwardWrite(tunnel.channel,
                                                    bytes: UnsafeRawBufferPointer(rebasing: raw[offset..<n]))
                            }
                            if sent > 0 {
                                offset += sent
                            } else if sent == -37 { // LIBSSH2_ERROR_EAGAIN
                                eagainThisRound = true
                                usleep(2_000) // 远端窗口暂满：短睡重试
                            } else {
                                closeTunnel(tunnel)
                                continue pumpLocal
                            }
                        }
                        nextTunnels.append(tunnel)
                    } else if n == 0 || errno != EAGAIN {
                        closeTunnel(tunnel) // 本地关闭/错误
                    } else {
                        nextTunnels.append(tunnel)
                    }
                }
            } else {
                nextTunnels = tunnels
            }
            tunnels = nextTunnels

            // 远端 → 本地（每轮全量非阻塞读——channel 数据不产生 poll 位）
            var kept: [Tunnel] = []
            kept.reserveCapacity(tunnels.count)
            pumpRemote: for tunnel in tunnels {
                while true {
                    let capacity = buffer.count
                    let n = buffer.withUnsafeMutableBytes { raw in
                        client.forwardRead(tunnel.channel, into: raw.baseAddress!, count: capacity)
                    }
                    if n > 0 {
                        var offset = 0
                        while offset < n {
                            let sent = buffer.withUnsafeBytes { raw in
                                write(tunnel.localFd, raw.baseAddress!.advanced(by: offset), n - offset)
                            }
                            if sent > 0 {
                                offset += sent
                            } else if errno == EAGAIN {
                                usleep(2_000)
                            } else {
                                closeTunnel(tunnel)
                                continue pumpRemote
                            }
                        }
                    } else if n == 0 {
                        closeTunnel(tunnel) // 远端 EOF
                        continue pumpRemote
                    } else if n == -37 { // EAGAIN：本通道暂无数据
                        if !eagainThisRound { eagainThisRound = tunnels.count > 4 }
                        break
                    } else {
                        closeTunnel(tunnel) // 通道错误
                        continue pumpRemote
                    }
                }
                kept.append(tunnel)
            }
            tunnels = kept

            if eagainThisRound {
                eagainRun += 1
            } else {
                eagainRun = 0
            }
        }
    }

    private func closeTunnel(_ tunnel: Tunnel) {
        Darwin.close(tunnel.localFd)
        client.closeForwardChannel(tunnel.channel)
        bumpCount(-1)
    }
}

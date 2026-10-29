import Foundation

// 服务器状态采集轮询器：每条 SSH 会话一条独立采集连接，周期跑只读脚本取资源快照。
// 并发口径与 SFTPService 相同——libssh2 会话被终端事件循环线程独占，绝不跨线程共用，
// 这里自己开 SSHClient、全部 C 调用串行在内部队列上执行；
// 也符合「不向用户 shell 注入命令」口径：独立 exec 通道，不触碰用户终端。
final class ServerMetricsPoller {
    static let pollInterval: TimeInterval = 3

    /// 主线程回调；nil = 采集已停止（断连/认证失败/输出不可用），UI 收到后隐藏状态条
    var onReading: ((ServerMetricsReading?) -> Void)?

    private let queue = DispatchQueue(label: "picoterm.ssh.metrics", qos: .utility)
    private var client: SSHClient?
    private var timer: DispatchSourceTimer?
    private var lastSample: ServerMetricsSample?
    private var stopped = false
    /// 采集结果只经主线程回调
    private func deliver(_ reading: ServerMetricsReading?) {
        MainThread.perform { [onReading] in onReading?(reading) }
    }

    /// 连接并开始轮询（幂等：已在跑则忽略）。连接失败静默退出，只记诊断日志。
    func start(config: SSHConfig) {
        queue.async { [self] in
            guard client == nil, timer == nil, !stopped else { return }
            do {
                let c = SSHClient()
                try c.connect(config: config)
                client = c
            } catch {
                DebugLog.write("metrics connect failed: \((error as? SSHClientError)?.description ?? "\(error)")")
                stopped = true
                deliver(nil)
                return
            }
            // 首轮立即采，之后按固定间隔（DispatchSourceTimer 挂在串行队列上，
            // exec 阻塞期间不会重入——队列天然串行化）
            pollOnce()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + Self.pollInterval,
                       repeating: Self.pollInterval)
            t.setEventHandler { [weak self] in self?.pollOnce() }
            t.resume()
            timer = t
        }
    }

    /// 停止并断开（主线程或队列调用均可；真正清理在队列上做）
    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            timer?.cancel()
            timer = nil
            client?.close()
            client = nil
            lastSample = nil
            deliver(nil)
        }
    }

    private func pollOnce() {
        guard !stopped, let client else { return }
        let takenAt = Date()
        guard let result = try? client.exec(ServerMetrics.collectionScript),
              result.code == 0 || !result.output.isEmpty else {
            DebugLog.write("metrics exec failed, stop polling")
            stop()
            return
        }
        let sample = ServerMetricsSample(parsing: result.output, takenAt: takenAt)
        guard sample.isUsable else {
            DebugLog.write("metrics sample unusable (restricted shell?), stop polling")
            stop()
            return
        }
        let reading = ServerMetricsReading(sample: sample, previous: lastSample)
        lastSample = sample
        deliver(reading)
    }
}

import Foundation

// 文件传输管理（TODO 51/52/57）：全局传输注册表 + 每个传输一条独立 SFTP 连接的执行器。
// 每传输独立连接的原因：文件管理器的 SFTP 连接跟随会话切换，切走即断；
// 传输独立后切会话不打断传输，且多会话可并行传输（底部进度栏聚合展示）。
//
// 断点续传：下载从本地半截文件按字节数续（远端 seek + 本地追加）；
// 上传对远端半截文件按远端实际大小 seek 续写（SFTP 无 append，seek+write 等价实现）；
// 内容以「同路径同内容」为假设（ WindTerm 同口径），本地编辑回传属内容变更场景不走续传。
// 结束的条目（完成/失败/取消）不自动消失，由用户逐条点击关闭或「清除」一键清空（TODO 57）。

/// 进度回调返回 false 表示已请求取消，传输循环即刻中止
struct TransferCancelled: Error {}

final class TransferTask {
    enum State { case running, finished, failed, cancelled }

    let id = UUID()
    let host: String
    let name: String
    let isUpload: Bool

    private let lock = NSLock()
    private var _total: UInt64
    private var _done: UInt64 = 0
    private var _state: State = .running
    private var _cancelled = false
    // 速度（字节/秒）：250ms 采样窗取瞬时值、EMA 平滑，进度栏 0.1s 刷新读取
    private var _speed: UInt64 = 0
    private var _speedRefBytes: UInt64 = 0
    private var _speedRefAt: Date?

    init(host: String, name: String, isUpload: Bool, total: UInt64) {
        self.host = host
        self.name = name
        self.isUpload = isUpload
        self._total = total
    }

    /// 总字节数可校正：列表入口传的 size 可能陈旧（活跃文件边下边变），
    /// 传输连接建立后 stat 远端的新鲜值回填（TODO 57）
    var total: UInt64 { lock.withLock { _total } }
    var done: UInt64 { lock.withLock { _done } }
    var speed: UInt64 { lock.withLock { _speed } }
    var state: State { lock.withLock { _state } }
    var isCancelled: Bool { lock.withLock { _cancelled } }

    /// UI 侧请求取消；传输循环在下一个分块边界生效
    func requestCancel() { lock.withLock { _cancelled = true } }

    fileprivate func set(total newValue: UInt64) { lock.withLock { if newValue > 0 { _total = newValue } } }
    fileprivate func set(done newValue: UInt64) {
        lock.withLock {
            _done = max(_done, newValue)
            let now = Date()
            if let refAt = _speedRefAt {
                let dt = now.timeIntervalSince(refAt)
                if dt >= 0.25 {
                    let inst = UInt64(Double(_done - _speedRefBytes) / dt)
                    _speed = UInt64(Double(_speed) * 0.6 + Double(inst) * 0.4)
                    _speedRefBytes = _done
                    _speedRefAt = now
                }
            } else {
                _speedRefBytes = _done
                _speedRefAt = now
            }
        }
    }
    fileprivate func finish(state newState: State) {
        lock.withLock {
            _cancelled = newState == .cancelled
            _state = newState
            _speed = 0
        }
    }
}

final class TransferStore {
    static let shared = TransferStore()

    /// 主线程读写；bar/面板据此渲染
    private(set) var tasks: [TransferTask] = []
    var onChanged: (() -> Void)?

    /// 节流时间戳（notifyMain 跨线程读，锁保护）：0.1s 内的进度事件不再向主线程跳
    private var lastNotifyAt = Date.distantPast
    private let throttleLock = NSLock()

    @discardableResult
    func begin(host: String, name: String, isUpload: Bool, total: UInt64) -> TransferTask {
        let task = TransferTask(host: host, name: name, isUpload: isUpload, total: total)
        MainThread.perform { [self] in
            tasks.append(task)
            notify(force: true)
        }
        return task
    }

    /// 传输队列线程调用：stat 新鲜总大小回填（活跃文件大小会变）
    func update(total: UInt64, for task: TransferTask) {
        task.set(total: total)
        notifyMain(force: false)
    }

    /// 传输队列线程调用：回报进度并查询取消状态。
    /// 高速传输每 64KB 一回调，节流先在调用线程判定，不过期就不向主线程派发
    func progress(_ task: TransferTask, done: UInt64) -> Bool {
        task.set(done: done)
        let cancelled = task.isCancelled
        notifyMain(force: false)
        return !cancelled
    }

    /// 结束条目保留在栏上（TODO 57：不自动消失），用户逐条点 ✕/✓ 关闭或「清除」清空
    func finish(_ task: TransferTask, _ state: TransferTask.State) {
        task.finish(state: state)
        MainThread.perform { [self] in notify(force: true) }
    }

    /// 逐条关闭（条目上的按钮）
    func remove(_ task: TransferTask) {
        tasks.removeAll { $0.id == task.id }
        notify(force: true)
    }

    func cancel(_ task: TransferTask) { task.requestCancel() }

    /// 「清除」一键清掉所有已结束条目（运行中的不动）
    func clearFinished() {
        tasks.removeAll { $0.state != .running }
        notify(force: true)
    }

    /// 调用线程侧节流（0.1s）：未过期直接返回，避免每分块一次主线程派发；
    /// 过期即更新时间戳并派发（主线程侧不再二次判定，否则会被自己拦掉）
    private func notifyMain(force: Bool) {
        throttleLock.lock()
        if !force, Date().timeIntervalSince(lastNotifyAt) < 0.1 {
            throttleLock.unlock()
            return
        }
        lastNotifyAt = Date()
        throttleLock.unlock()
        MainThread.perform { [self] in onChanged?() }
    }

    /// 进度通知节流 0.1s（完成/新增等状态变化 force 刷新）；仅主线程调用
    private func notify(force: Bool) {
        guard force || Date().timeIntervalSince(lastNotifyAt) >= 0.1 else { return }
        lastNotifyAt = Date()
        onChanged?()
    }
}

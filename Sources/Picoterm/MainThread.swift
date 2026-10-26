import AppKit

/// 回主线程执行 UI 更新——**模态弹窗开着时也送达**。
/// `NSApp.runModal` 是嵌套运行循环，不排空 GCD 主队列：`DispatchQueue.main.async` 的块会一直
/// 卡到弹窗关闭（2026-10-26 探针实测）；`RunLoop.perform(inModes:)` 在默认 / 模态 / 事件跟踪三种
/// 模式下都执行，且从后台线程投递会立即唤醒主循环（实测 0ms 延迟）。
/// 终端馈送、断线提示、传输进度这类"弹窗开着也该动"的更新一律走这里；同一来源的块保持 FIFO。
enum MainThread {
    private static let modes: [RunLoop.Mode] = [.default, .modalPanel, .eventTracking]

    static func perform(_ block: @escaping () -> Void) {
        RunLoop.main.perform(inModes: modes, block: block)
    }

    /// 延迟执行（替代 main.asyncAfter 闭包形式）
    static func perform(after delay: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
            perform(block)
        }
    }

    /// 延迟执行可取消的工作项（替代 main.asyncAfter(execute:)）；取消在投递前后都生效
    static func perform(after delay: TimeInterval, _ work: DispatchWorkItem) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
            guard !work.isCancelled else { return }
            perform {
                guard !work.isCancelled else { return }
                work.perform()
            }
        }
    }
}

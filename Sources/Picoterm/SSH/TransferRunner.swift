import Foundation
import PicotermCore

// 传输执行器（TODO 51/52）：每个传输一条独立 SFTP 连接（切会话不断传、多会话可并行），
// 断点续传决策 + 进度/取消回报；认证复用 SFTPService.makeConnectedClient 口径

enum TransferRunner {
    /// 大文件并行分块下载入口（Termind 多连接 SFTP 口径）：
    /// ≥32MB 且无本地断点时拆 N 段、N 条 SSH 连接并行拉取，速度随连接数提升；
    /// 其余情况（小文件/断点续传）回退单连接路径
    static func download(config: SSHConfig, host: String, remote: String, name: String,
                         total: UInt64, to local: URL,
                         completion: ((Bool, String) -> Void)? = nil) {
        // 本地已有半截文件（续传场景）直接走单连接；全新大文件走并行
        if let attrs = try? FileManager.default.attributesOfItem(atPath: local.path),
           let localSize = (attrs[.size] as? NSNumber)?.uint64Value, localSize > 0 {
            downloadSingle(config: config, host: host, remote: remote, name: name,
                           total: total, to: local, completion: completion)
            return
        }
        guard total >= 32 << 20 else {
            downloadSingle(config: config, host: host, remote: remote, name: name,
                           total: total, to: local, completion: completion)
            return
        }
        downloadParallel(config: config, host: host, remote: remote, name: name,
                         total: total, to: local, connections: 3, completion: completion)
    }

    /// 并行分块下载：预分配全尺寸本地文件，N 条连接各拉一段（区间互不重叠，
    /// 各自 FileHandle 独立 seek 写入，无锁竞争）；进度 = 汇总计数
    private static func downloadParallel(config: SSHConfig, host: String, remote: String, name: String,
                                         total: UInt64, to local: URL, connections: Int,
                                         completion: ((Bool, String) -> Void)?) {
        let queue = DispatchQueue(label: "picoterm.transfer.pl.\(UUID().uuidString)", qos: .userInitiated)
        queue.async {
            let task = TransferStore.shared.begin(host: host, name: name, isUpload: false, total: total)
            do {
                // 先 stat 校准总大小
                let probe = try SFTPService.makeConnectedClient(config: config)
                let sftp = try probe.sftpInit()
                var effectiveTotal = total
                if let stat = try? probe.sftpStat(sftp, path: remote), stat.size > 0 {
                    effectiveTotal = stat.size
                }
                probe.sftpShutdown(sftp)
                probe.close()
                probe.teardown()
                TransferStore.shared.update(total: effectiveTotal, for: task)
                guard effectiveTotal >= 32 << 20, !task.isCancelled else {
                    // stat 后变小了：回退单连接（重新调度）
                    MainThread.perform {
                        TransferStore.shared.remove(task)
                        downloadSingle(config: config, host: host, remote: remote, name: name,
                                       total: effectiveTotal, to: local, completion: completion)
                    }
                    return
                }

                // 预分配全尺寸文件（truncate 到目标大小，各块 seek 写入）
                FileManager.default.createFile(atPath: local.path, contents: nil)
                guard let mainHandle = try? FileHandle(forUpdatingAtPath: local.path) else {
                    throw SSHClientError.localFileFailed(L("无法写入 %@", local.path))
                }
                try? mainHandle.truncate(atOffset: effectiveTotal)
                try? mainHandle.close()

                // 分块（最后一块吃尾差）
                let count = max(1, min(connections, Int(effectiveTotal / (8 << 20)) + 1))
                let chunkSize = effectiveTotal / UInt64(count)
                var ranges: [(start: UInt64, length: UInt64)] = []
                for index in 0..<count {
                    let start = chunkSize * UInt64(index)
                    let length = index == count - 1 ? effectiveTotal - start : chunkSize
                    ranges.append((start, length))
                }

                // 汇总进度 + 取消共享
                let counter = NSLock()
                var done: UInt64 = 0
                var firstError: Error?
                var cancelled = false
                let group = DispatchGroup()
                let workerQueue = DispatchQueue(label: "picoterm.transfer.workers", attributes: .concurrent)

                for range in ranges {
                    group.enter()
                    workerQueue.async {
                        defer { group.leave() }
                        guard !cancelled else { return }
                        do {
                            let client = try SFTPService.makeConnectedClient(config: config)
                            let sftp = try client.sftpInit()
                            defer {
                                client.sftpShutdown(sftp)
                                client.close()
                                client.teardown()
                            }
                            guard let handle = FileHandle(forUpdatingAtPath: local.path) else {
                                throw SSHClientError.localFileFailed(L("无法写入 %@", local.path))
                            }
                            defer { try? handle.close() }
                            handle.seek(toFileOffset: range.start)
                            var offset = range.start
                            try client.sftpReadRange(sftp, path: remote, offset: range.start,
                                                     length: range.length) { chunk, size in
                                if task.isCancelled { throw TransferCancelled() }
                                handle.write(Data(chunk))
                                offset += UInt64(size)
                                counter.lock()
                                done += UInt64(size)
                                let current = done
                                counter.unlock()
                                _ = TransferStore.shared.progress(task, done: current)
                            }
                            _ = offset
                        } catch {
                            counter.lock()
                            if firstError == nil { firstError = error }
                            cancelled = cancelled || error is TransferCancelled
                            counter.unlock()
                        }
                    }
                }
                group.wait()

                if let error = firstError {
                    let isCancel = error is TransferCancelled || cancelled
                    TransferStore.shared.finish(task, isCancel ? .cancelled : .failed)
                    let message = isCancel ? L("已取消下载 %@", name)
                        : L("下载失败：%@", (error as? SSHClientError)?.description ?? "\(error)")
                    MainThread.perform { completion?(false, message) }
                } else {
                    TransferStore.shared.finish(task, .finished)
                    MainThread.perform {
                        completion?(true, L("已下载（%ld 连接并行）%@ → %@", count, name, local.path))
                    }
                }
            } catch {
                TransferStore.shared.finish(task, .failed)
                MainThread.perform {
                    completion?(false, L("下载失败：%@", (error as? SSHClientError)?.description ?? "\(error)"))
                }
            }
        }
    }

    /// 单连接下载（原有路径：断点续传 + 进度/取消）
    private static func downloadSingle(config: SSHConfig, host: String, remote: String, name: String,
                                       total: UInt64, to local: URL,
                                       completion: ((Bool, String) -> Void)? = nil) {
        let queue = DispatchQueue(label: "picoterm.transfer.dl.\(UUID().uuidString)", qos: .userInitiated)
        queue.async {
            let task = TransferStore.shared.begin(host: host, name: name, isUpload: false, total: total)
            do {
                let client = try SFTPService.makeConnectedClient(config: config)
                let sftp = try client.sftpInit()
                defer {
                    client.sftpShutdown(sftp)
                    client.close()
                    client.teardown()
                }
                // 总大小以传输开始时的远端 stat 为准（列表传入的 size 可能陈旧：
                // 活跃日志边下边长/轮转，否则完成时进度条到不了 100%）
                var effectiveTotal = total
                if let stat = try? client.sftpStat(sftp, path: remote), stat.size > 0 {
                    effectiveTotal = stat.size
                    TransferStore.shared.update(total: stat.size, for: task)
                }
                // 断点：本地已有半截文件（0 < 本地 < 远端）则从断点续读追加；完整/超长则整体重下
                var resume: UInt64 = 0
                if let attrs = try? FileManager.default.attributesOfItem(atPath: local.path),
                   let localSize = (attrs[.size] as? NSNumber)?.uint64Value,
                   localSize > 0, localSize < effectiveTotal {
                    resume = localSize
                }
                try client.sftpDownload(sftp, remote: remote, to: local, resumeFrom: resume) { done in
                    TransferStore.shared.progress(task, done: done)
                }
                TransferStore.shared.finish(task, .finished)
                let note = resume > 0 ? L("已下载（断点续传）%@ → %@", name, local.path) : L("已下载 %@ → %@", name, local.path)
                MainThread.perform { completion?(true, note) }
            } catch {
                let cancelled = error is TransferCancelled
                TransferStore.shared.finish(task, cancelled ? .cancelled : .failed)
                let message = cancelled ? L("已取消下载 %@", name)
                    : L("下载失败：%@", (error as? SSHClientError)?.description ?? "\(error)")
                MainThread.perform { completion?(false, message) }
            }
        }
    }

    /// 面板上传：独立 SFTP 连接 + 断点续传 + 进度/取消。
    /// allowResume=false 用于本地编辑回传（内容已变，按大小续传会写坏远端文件）
    static func upload(config: SSHConfig, host: String, local: URL, remote: String, name: String,
                       allowResume: Bool = true,
                       completion: ((Bool, String) -> Void)? = nil) {
        let queue = DispatchQueue(label: "picoterm.transfer.ul.\(UUID().uuidString)", qos: .userInitiated)
        queue.async {
            let localSize = UInt64((try? local.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            let task = TransferStore.shared.begin(host: host, name: name, isUpload: true, total: localSize)
            do {
                let client = try SFTPService.makeConnectedClient(config: config)
                let sftp = try client.sftpInit()
                defer {
                    client.sftpShutdown(sftp)
                    client.close()
                    client.teardown()
                }
                // 断点：远端半截（0 < 远端 < 本地）则 seek 到远端实际大小续写；同大小/更大则全量重传
                var resume: UInt64 = 0
                if allowResume, localSize > 0,
                   let stat = try? client.sftpStat(sftp, path: remote),
                   stat.size > 0, stat.size < localSize {
                    resume = stat.size
                }
                try client.sftpUpload(sftp, local: local, to: remote, resumeFrom: resume) { done in
                    TransferStore.shared.progress(task, done: done)
                }
                TransferStore.shared.finish(task, .finished)
                let note = resume > 0 ? L("已上传（断点续传）%@", name) : L("已上传 %@", name)
                MainThread.perform { completion?(true, note) }
            } catch {
                let cancelled = error is TransferCancelled
                TransferStore.shared.finish(task, cancelled ? .cancelled : .failed)
                let message = cancelled ? L("已取消上传 %@", name)
                    : L("上传失败：%@", (error as? SSHClientError)?.description ?? "\(error)")
                MainThread.perform { completion?(false, message) }
            }
        }
    }
}

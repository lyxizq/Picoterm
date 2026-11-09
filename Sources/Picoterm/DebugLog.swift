import Foundation

// 轻量诊断日志（排障用）：追加到数据目录 debug.log，超 256KB 截断重写。
// 只在关键交互点打点（弹窗动作/地址栏/目录跟随/探测），量小无性能影响。
enum DebugLog {
    private static let queue = DispatchQueue(label: "picoterm.debuglog")
    private static var url: URL {
        AppSettings.shared.dataDir.appendingPathComponent("debug.log")
    }

    static func write(_ line: String) {
        queue.async {
            let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            let text = "[\(stamp)] \(line)\n"
            if let data = text.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: url.path),
                   (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 > 256_000 {
                    try? data.write(to: url)
                } else {
                    if let handle = try? FileHandle(forWritingTo: url) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        try? handle.close()
                    } else {
                        try? data.write(to: url)
                    }
                }
            }
        }
    }
}

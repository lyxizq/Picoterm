import AppKit
import PicotermCore

// 文件打开工具（TODO 56）：设置里配置了工具地址后，所有本地文件打开动作
// 一律优先用它——支持 .app（用该 App 打开任意类型文件）或命令行可执行文件
// （以文件路径为参数拉起）；工具启动失败回退系统默认方式
enum FileOpener {
    /// 打开本地文件；返回回退提示文案（nil = 正常用配置工具/系统默认打开）
    @discardableResult
    static func open(_ url: URL) -> String? {
        let tool = AppSettings.shared.fileOpenToolPath
        guard !tool.isEmpty else {
            NSWorkspace.shared.open(url)
            return nil
        }
        var isDir: ObjCBool = false
        let isAppBundle = tool.lowercased().hasSuffix(".app")
            && FileManager.default.fileExists(atPath: tool, isDirectory: &isDir)
            && isDir.boolValue
        do {
            if isAppBundle {
                NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: tool),
                                        configuration: NSWorkspace.OpenConfiguration())
            } else {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = [url.path]
                try process.run()
            }
            return nil
        } catch {
            NSWorkspace.shared.open(url)
            return L("工具 %@ 启动失败，已用系统默认方式打开", tool)
        }
    }
}

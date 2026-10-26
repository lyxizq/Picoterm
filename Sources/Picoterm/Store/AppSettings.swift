import AppKit
import Foundation
import PicotermCore

// 列表字号变化广播（设置即改即生效，会话树/文件列表各自监听刷新）
extension Notification.Name {
    static let listFontSizeChanged = Notification.Name("picoterm.listFontSizeChanged")
}

// App 级设置：数据目录可自定义，默认 ~/.picoterm
// 设置本体存 App Support（数据目录自身不能存在数据目录里，鸡生蛋问题）
final class AppSettings {
    static let shared = AppSettings()

    private(set) var dataDirOverride: String?
    private var storage: [String: String] = [:]

    private var settingsURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Picoterm", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    var dataDir: URL {
        if let override = dataDirOverride, !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".picoterm", isDirectory: true)
    }

    /// 当前生效路径的展示文本
    var dataDirDescription: String { dataDir.path }

    // 终端外观（TODO 11）

    var terminalFontSize: Double {
        get { Double(storage["fontSize"] ?? "") ?? 12.5 }
        set { storage["fontSize"] = String(newValue); save() }
    }

    /// dark | light
    var terminalTheme: String {
        get { storage["theme"] ?? "dark" }
        set { storage["theme"] = newValue; save() }
    }

    /// 终端主题 id（TerminalThemes.all 的 id；兼容旧值 dark/light → midnight/light）
    var terminalThemeId: String {
        get {
            let raw = storage["themeId"] ?? ""
            if !raw.isEmpty { return raw }
            return storage["theme"] == "light" ? "light" : "midnight"
        }
        set { storage["themeId"] = newValue; save() }
    }

    /// 终端字体族（空 = 系统等宽默认）
    var terminalFontFamily: String {
        get { storage["fontFamily"] ?? "" }
        set { storage["fontFamily"] = newValue; save() }
    }

    /// 光标样式 block | underline | bar（Berth CursorPrefs 口径）
    var cursorStyle: String {
        get { storage["cursorStyle"] ?? "block" }
        set { storage["cursorStyle"] = newValue; save() }
    }

    /// 终端链接点击方式（2026-10-26）：true = ⌘+点击（macOS 惯例，默认），false = 直接点击（Tabby 默认）
    var linkClickRequiresCommand: Bool {
        get { storage["linkClickCmd"] != "0" }
        set { storage["linkClickCmd"] = newValue ? "1" : "0"; save() }
    }

    /// 终端回滚缓冲行数（TODO 74，默认 9999；经 TerminalView.changeScrollback 运行时即时生效）
    var terminalScrollback: Int {
        get { min(max(Int(storage["scrollback"] ?? "") ?? 9999, 100), 100_000) }
        set { storage["scrollback"] = String(min(max(newValue, 100), 100_000)); save() }
    }

    /// 选中即复制（Berth 复制行为）
    var copyOnSelection: Bool {
        get { storage["copyOnSelection"] == "1" }
        set { storage["copyOnSelection"] = newValue ? "1" : "0"; save() }
    }

    /// bell 提示（beep/可视）
    var bellEnabled: Bool {
        get { storage["bellEnabled"] != "0" }
        set { storage["bellEnabled"] = newValue ? "1" : "0"; save() }
    }

    /// 文件管理器跟随终端当前目录（被动解析 OSC 7 / 窗口标题 + SFTP 连接只读探测兜底，不注入命令，TODO 71）
    var syncFileManagerWithTerminal: Bool {
        get { storage["syncFMWithTerm"] != "0" }
        set { storage["syncFMWithTerm"] = newValue ? "1" : "0"; save() }
    }

    /// 终端日志高亮（WindTerm 式客户端关键字着色：时间戳/级别/IP/URL；SSH 输出）
    var logHighlightEnabled: Bool {
        get { storage["logHighlight"] != "0" }
        set { storage["logHighlight"] = newValue ? "1" : "0"; save() }
    }

    /// SSH 字符集（Ported from Termind RemoteCharset 口径）：新建连接的默认字符集
    ///（连接编辑弹窗可按主机改）；既有会话的编码随各自主机配置
    var sshCharset: RemoteCharset {
        get { RemoteCharset(rawValue: storage["sshCharset"] ?? "") ?? .utf8 }
        set { storage["sshCharset"] = newValue.rawValue; save() }
    }

    // MARK: 界面主题（2026-10-24 用户指定：黑白两种，设置窗口切换）

    /// white | black。切换即改 NSApp.appearance：自适应颜色（文字/分隔线/毛玻璃）立即跟随，
    /// 发丝线等 cgColor 快照经各表面视图的 viewDidChangeEffectiveAppearance 重刷
    var interfaceTheme: String {
        get { storage["interfaceTheme"] ?? "white" }
        set {
            storage["interfaceTheme"] = newValue
            save()
            applyInterfaceAppearance()
        }
    }

    func applyInterfaceAppearance() {
        NSApp.appearance = NSAppearance(named: interfaceTheme == "black" ? .darkAqua : .aqua)
    }

    // MARK: 列表字号（2026-10-24 用户指定：会话列表 / 文件管理列表，设置即改即生效）

    /// 变更后广播 listFontSizeChanged，两个列表视图各自重算行高与字体
    private func postListFontSizeChanged() {
        NotificationCenter.default.post(name: .listFontSizeChanged, object: nil)
    }

    /// 会话树字号（默认 13；行高 = 字号 + 13）
    var sessionListFontSize: Int {
        get { storage["sessionListFontSize"].flatMap(Int.init) ?? 13 }
        set {
            let clamped = min(18, max(10, newValue))
            guard clamped != sessionListFontSize else { return }
            storage["sessionListFontSize"] = String(clamped)
            save()
            postListFontSizeChanged()
        }
    }

    /// 文件列表字号（默认 13；名称列=字号，次级列 -2/-1，行高 = 字号 + 13）
    var fileListFontSize: Int {
        get { storage["fileListFontSize"].flatMap(Int.init) ?? 13 }
        set {
            let clamped = min(18, max(10, newValue))
            guard clamped != fileListFontSize else { return }
            storage["fileListFontSize"] = String(clamped)
            save()
            postListFontSizeChanged()
        }
    }

    /// 文件打开工具路径（空 = 系统默认应用）；支持 .app 或命令行可执行文件，
    /// 配置后所有打开本地文件的动作一律优先用它、不分文件类型
    var fileOpenToolPath: String {
        get { storage["fileOpenTool"] ?? "" }
        set { storage["fileOpenTool"] = newValue; save() }
    }

    // MARK: 界面语言（2026-10-26 用户指定：中/英切换；视图文案在构建期取 L()，重启后完全生效）

    /// system | zh | en（AppLanguage.rawValue）。AppDelegate 启动时把存储值灌入 L10n.preference
    var interfaceLanguage: String {
        get { storage["language"] ?? "system" }
        set {
            storage["language"] = newValue
            save()
            L10n.preference = AppLanguage(rawValue: newValue) ?? .system
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        storage = obj
        dataDirOverride = obj["dataPath"]
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(storage).write(to: settingsURL, options: .atomic)
        } catch {
            NSLog("picoterm: 保存设置失败 \(error)")
        }
    }

    /// 更改数据目录；传 nil 恢复默认 ~/.picoterm
    func setDataDir(_ path: String?) {
        dataDirOverride = (path?.isEmpty == false) ? path : nil
        storage["dataPath"] = dataDirOverride
        save()
        HostStore.shared.reload()
    }
}

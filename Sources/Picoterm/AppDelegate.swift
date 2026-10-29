import AppKit
import PicotermCore
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var windowController: MainWindowController?
    /// 关于面板（TODO 78）：标准 About 面板图标过大且无标题，自绘 64×64 图标 + PicoTerm 标题；
    /// 模态显示（2026-10-26 弹窗统一模态口径），红绿灯关闭 = 结束模态
    private var aboutPanel: NSPanel?

    @objc func showAboutPanel(_ sender: Any?) {
        let panel = aboutPanel ?? makeAboutPanel()
        aboutPanel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        guard NSApp.modalWindow == nil else { return }
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === aboutPanel { NSApp.stopModal(withCode: .cancel) }
        return true
    }

    private func makeAboutPanel() -> NSPanel {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 132))
        let titleLabel = NSTextField(labelWithString: "PicoTerm")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let versionLabel = NSTextField(labelWithString: L("版本 %@", version))
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        // 第三方声明（移植口径：Tabby MIT 须标注版权；社区配色源自 iTerm2-Color-Schemes）
        let noticeLabel = NSTextField(wrappingLabelWithString:
            L("Portions copyright Tabby Developers (MIT) · 终端配色来自 iTerm2-Color-Schemes (MIT)\n部分功能移植自 Berth、Termind (GPL-3)"))
        noticeLabel.font = .systemFont(ofSize: 10)
        noticeLabel.textColor = .tertiaryLabelColor
        noticeLabel.alignment = .center
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(titleLabel)
        content.addSubview(versionLabel)
        content.addSubview(noticeLabel)
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            versionLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            versionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            noticeLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            noticeLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            noticeLabel.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 14),
        ])
        let panel = NSPanel(contentRect: content.bounds,
                            styleMask: [.titled, .closable],
                            backing: .buffered, defer: false)
        panel.title = L("关于 PicoTerm")
        panel.contentView = content
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        return panel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 调试探针：建设置窗口做命中测试后退出（不进正常启动流程）
        if CommandLine.arguments.contains("--probe-settings-layout") {
            SettingsLayoutProbe.run()
            return
        }
        // 崩溃留痕：Obj-C 异常写入数据目录，便于用户侧取证
        NSSetUncaughtExceptionHandler { exception in
            let text = "\(Date())\n\(exception.name.rawValue): \(exception.reason ?? "-")\n"
                + exception.callStackSymbols.joined(separator: "\n") + "\n\n"
            let dir = AppSettings.shared.dataDir
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("crash.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                try? handle.close()
            } else {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        // 界面语言先于菜单/主窗口灌入（菜单与首窗构建期即取 L() 文案）
        AppSettings.shared.load()
        L10n.preference = AppLanguage(rawValue: AppSettings.shared.interfaceLanguage) ?? .system
        installMenus()
        SFTPService.purgeEditorTemp()
        let wc = MainWindowController()
        windowController = wc
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 主窗口红绿灯路径已确认过退出：终止回调不再二次询问
    var quitConfirmed = false

    /// 有未关闭的 SSH 会话时确认退出（TODO 68）；红绿灯（MainWindowController.windowShouldClose）与 ⌘Q 共用。
    /// 返回 true = 可以退出（无会话直接放行）
    @MainActor
    func confirmQuit(parent: NSWindow?) -> Bool {
        let runningSSH = SessionManager.shared.sessions.filter { ($0 as? SSHSession)?.state == .running }
        guard !runningSSH.isEmpty else { return true }
        let text = runningSSH.count == 1
            ? L("有 1 个 SSH 会话尚未关闭，退出 Picoterm 将断开该连接。确定退出吗？")
            : L("有 %ld 个 SSH 会话尚未关闭，退出 Picoterm 将断开这些连接。确定退出吗？", runningSSH.count)
        let response = PicotermDialog.run(title: L("退出 Picoterm"),
                                          content: PicotermDialog.message(text),
                                          primaryTitle: L("退出"), destructive: true,
                                          parent: parent)
        return response == .OK
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitConfirmed { return .terminateNow }
        return confirmQuit(parent: NSApp.mainWindow) ? .terminateNow : .terminateCancel
    }

    private func installMenus() {
        let main = NSMenu()

        let appRoot = NSMenuItem()
        main.addItem(appRoot)
        let appMenu = NSMenu(title: "Picoterm")
        appMenu.addItem(withTitle: L("关于 PicoTerm"),
                        action: #selector(showAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("隐藏 Picoterm"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: L("退出 Picoterm"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appRoot.submenu = appMenu

        let editRoot = NSMenuItem()
        main.addItem(editRoot)
        let editMenu = NSMenu(title: L("编辑"))
        editMenu.addItem(withTitle: L("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let findItem = editMenu.addItem(withTitle: L("查找…"),
                                        action: NSSelectorFromString("performFindPanelAction:"),
                                        keyEquivalent: "f")
        findItem.tag = 1 // NSTextFinderAction showFindInterface
        editRoot.submenu = editMenu

        let viewRoot = NSMenuItem()
        main.addItem(viewRoot)
        let viewMenu = NSMenu(title: L("显示"))
        viewMenu.addItem(withTitle: L("设置"),
                         action: #selector(MainWindowController.openSettings(_:)),
                         keyEquivalent: ",")
        viewMenu.addItem(withTitle: L("新建本地 Shell"),
                         action: #selector(MainWindowController.newLocalShellSession(_:)),
                         keyEquivalent: "t")
        let broadcast = viewMenu.addItem(withTitle: L("同步输入到所有会话"),
                                         action: #selector(MainWindowController.toggleBroadcast(_:)),
                                         keyEquivalent: "")
        broadcast.state = .off
        viewMenu.addItem(withTitle: L("命令面板"),
                         action: #selector(MainWindowController.showCommandPalette(_:)),
                         keyEquivalent: "k")
        viewMenu.addItem(withTitle: L("切换右侧面板"),
                         action: #selector(MainWindowController.toggleRightPane(_:)),
                         keyEquivalent: "b")
        let fullscreen = viewMenu.addItem(withTitle: L("进入全屏"),
                                          action: #selector(NSWindow.toggleFullScreen(_:)),
                                          keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.command, .control]
        viewRoot.submenu = viewMenu

        let windowRoot = NSMenuItem()
        main.addItem(windowRoot)
        let windowMenu = NSMenu(title: L("窗口"))
        windowMenu.addItem(withTitle: L("最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("关闭"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowRoot.submenu = windowMenu

        NSApp.mainMenu = main
    }
}

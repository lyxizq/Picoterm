import AppKit
import PicotermCore

// MARK: - 主窗口

final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let root = RootView()
    private var settingsWindow: SettingsWindowController?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.minSize = NSSize(width: 1000, height: 640)
        window.center()
        // 窗口大小/位置由 AppKit 自动持久化（UserDefaults），下次启动恢复上次的 frame；
        // 设置 autosave 名时若已有存档会立即覆盖上面 center 的结果，顺序即语义
        window.setFrameAutosaveName("PicotermMainWindow")
        // 退化 frame 兜底（2026-10-24 实测：存档出现过 10pt 宽的窗口并被原样恢复——
        // minSize 只约束用户拖拽，管不住 setFrame 恢复）：宽高不足即弃用存档回默认尺寸
        if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            DebugLog.write("launch guard hit, frame=\(window.frame)")
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame PicotermMainWindow")
            window.setContentSize(NSSize(width: 1280, height: 800))
            window.center()
            DebugLog.write("launch guard done, frame=\(window.frame)")
        } else {
            DebugLog.write("launch guard skip, frame=\(window.frame)")
        }
        super.init(window: window)
        window.contentView = root
        window.delegate = self
        root.onOpenSettings = { [weak self] in self?.openSettings(nil) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 防退化夹持：任何来源（含程序性 setFrame）的 resize 结果过小时夹回下限，
    /// 避免「细条窗口」再次被写进 frame 存档
    func windowShouldResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: max(frameSize.width, 300), height: max(frameSize.height, 300))
    }

    /// 红绿灯关主窗口 = 退出 App：先确认再关（此前窗口先消失、再由终止回调弹确认，取消已无意义）
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let app = NSApp.delegate as? AppDelegate else { return true }
        guard app.confirmQuit(parent: sender) else { return false }
        app.quitConfirmed = true
        return true
    }

    @objc func toggleRightPane(_ sender: Any?) { root.toggleRightPane() }

    @objc func newLocalShellSession(_ sender: Any?) {
        SessionManager.shared.createLocalShell()
    }

    @objc func toggleBroadcast(_ sender: NSMenuItem) {
        let on = sender.state != .on
        sender.state = on ? .on : .off
        SessionManager.shared.broadcastInputEnabled = on
    }

    @objc func showCommandPalette(_ sender: Any?) {
        root.presentCommandPalette()
    }

    @objc func openSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
        settingsWindow?.activate()
    }
}

// MARK: - 根布局：标题栏 / 左右分栏 / 状态栏

final class RootView: NSView {
    var onOpenSettings: (() -> Void)? {
        get { titleBar.onOpenSettings }
        set { titleBar.onOpenSettings = newValue }
    }

    private let backdrop = Materials.vibrancy(.underWindowBackground)
    private let titleBar = TitleBarView()
    private let split = InteractiveSplitView()
    private let terminalPane = TerminalPaneView()
    private let rightPane = RightPaneView()
    private let transferBar = TransferBarView()
    private let statusBar = StatusBarView()

    private var didSetInitialLayout = false
    // 默认占比：右栏 ≈ 窗口宽 1/4，左终端占其余（对齐设计稿比例）；有存档则恢复存档
    private let rightRatio: CGFloat = 0.245
    private var lastRightWidth: CGFloat = 380
    /// 分栏比例存档的防抖写盘
    private var splitSaveWork: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(terminalPane)
        split.addArrangedSubview(rightPane)
        // 拖动优先级：右栏 260 高于终端 250，拖分隔条时终端侧伸缩、右栏跟手
        split.setHoldingPriority(.init(260), forSubviewAt: 1)
        // 面板最小宽度经 delegate constrain 提供：arranged subview 上挂外部
        // 必需优先级宽度约束会令分隔条完全拖不动（NSSplitView 文档口径）
        split.delegate = self

        for view: NSView in [backdrop, titleBar, split, transferBar, statusBar] {
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleBar.topAnchor.constraint(equalTo: topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: 76),

            split.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            split.bottomAnchor.constraint(equalTo: transferBar.topAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),

            // 传输进度栏：工作区最下方（状态栏上方），无传输时高度 0 隐藏
            transferBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            transferBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            transferBar.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 首帧布局完成后再设分割位置；提前设会被 NSSplitView 初始布局覆盖
        if window != nil && !didSetInitialLayout {
            didSetInitialLayout = true
            MainThread.perform { [self] in
                // 恢复上次调好的分栏比例（无存档或存档离谱时用默认值）
                let saved = UserDefaults.standard.double(forKey: "picoterm.mainSplitRatio")
                let ratio = (saved > 0.15 && saved < 0.85) ? CGFloat(saved) : rightRatio
                lastRightWidth = min(560, max(300, bounds.width * ratio))
                split.setPosition(bounds.width - lastRightWidth, ofDividerAt: 0)
            }
            // 会话系统接线：初始一个本地 Shell，之后全部经 SessionManager
            let manager = SessionManager.shared
            titleBar.onToggleRightPane = { [weak self] in self?.toggleRightPane() }
            titleBar.bindSessionManager()
            AppSettings.shared.load()
            AppSettings.shared.applyInterfaceAppearance()
            CommandHistory.shared.load()
            HostStore.shared.load()
            // 端口转发规则随启动恢复（启用的规则自动建隧道）
            PortForwardStore.shared.load()
            PortForwardService.shared.applyRules()
            rightPane.bindHostStore()
            manager.observeSelected { [weak self] in
                guard let self else { return }
                if let session = manager.selected {
                    terminalPane.show(session)
                }
                statusBar.update(session: manager.selected)
                // 右下文件管理器跟随选中的 SSH 会话打开 SFTP
                if let ssh = manager.selected as? SSHSession, let hostId = ssh.hostEntryId,
                   let entry = HostStore.shared.hosts.first(where: { $0.id == hostId }) {
                    let (config, needsSecret) = HostStore.shared.sshConfig(for: entry)
                    if !needsSecret {
                        SFTPService.shared.connectIfNeeded(config: config)
                    }
                }
            }
            manager.observeSessions { [weak self] in
                guard let self else { return }
                terminalPane.prune(kept: manager.sessions.map(\.id))
                statusBar.update(session: SessionManager.shared.selected)
            }
            manager.restoreStatePersister = { locals, sshIds in
                HostStore.shared.saveRestoreState(locals: locals, sshIds: sshIds)
            }
            // 启动空窗口：不默认开连接（TODO 16）；需要时 ⌘T / 面板 / 命令面板新建
        }
    }

    /// ⌘K：命令面板数据源
    func presentCommandPalette() {
        let manager = SessionManager.shared
        var items: [PaletteItem] = manager.sessions.map { session in
            PaletteItem(title: L("切换到 %@", manager.displayTitle(for: session)), symbol: session.symbol) {
                manager.select(session)
            }
        }
        if let current = manager.selected {
            items.append(PaletteItem(title: L("重命名当前标签…"), symbol: "pencil") { [weak self] in
                self?.titleBar.promptRenameTab(current)
            })
        }
        items.append(PaletteItem(title: L("新建本地 Shell"), symbol: "terminal.fill") {
            manager.createLocalShell()
        })
        for entry in HostStore.shared.hosts {
            guard entry.proto != "ssh" || !HostStore.shared.sshConfig(for: entry).needsSecret else { continue }
            let detail = entry.proto == "serial"
                ? (entry.serialDevice as NSString).lastPathComponent
                : "\(entry.user)@\(entry.host)"
            items.append(PaletteItem(title: L("连接 %@（%@）", entry.label, detail),
                                     symbol: entry.proto == "ssh" ? "server.rack" : "network") {
                SessionManager.shared.createSession(for: entry)
            })
        }
        items.append(PaletteItem(title: L("设置 ⌘,"), symbol: "gearshape") { [weak self] in
            self?.onOpenSettings?()
        })
        terminalPane.presentPalette(items: items)
    }

    func toggleRightPane() {
        if split.isSubviewCollapsed(rightPane) || rightPane.frame.width < 40 {
            split.setPosition(bounds.width - lastRightWidth, ofDividerAt: 0)
        } else {
            lastRightWidth = min(520, max(280, rightPane.frame.width))
            split.setPosition(bounds.width, ofDividerAt: 0)
        }
    }
}

// MARK: - 主分栏尺寸约束（拖动范围：终端 ≥ 420，右栏 ≥ 300）

extension RootView: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView,
                   constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        proposedMinimumPosition < 420 ? 420 : proposedMinimumPosition
    }

    func splitView(_ splitView: NSSplitView,
                   constrainMaxCoordinate proposedMaximum: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        let max = splitView.bounds.width - 300
        return proposedMaximum > max ? max : proposedMaximum
    }

    /// 窗口缩放时右栏保持宽度（终端伸缩）
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview subview: NSView) -> Bool {
        subview !== rightPane
    }

    /// 拖动/缩放后保存分栏比例（防抖 0.3s，窗口大小变化也在存档口径内）；
    /// 折叠态（⌘B 隐藏右栏）不存档，避免恢复出 0 宽
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard bounds.width > 100 else { return }
        splitSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.bounds.width > 100,
                  self.rightPane.frame.width > 40, !self.split.isSubviewCollapsed(self.rightPane) else { return }
            UserDefaults.standard.set(Double(self.rightPane.frame.width / self.bounds.width),
                                      forKey: "picoterm.mainSplitRatio")
        }
        splitSaveWork = work
        MainThread.perform(after: 0.3, work)
    }
}

// MARK: - 右侧栏：上会话 / 下文件管理器

final class RightPaneView: NSView {
    // 会话/文件管理器/脚本三面板底色 = 透明（2026-10-24 用户指定毛玻璃）：不再垫任何
    // 表面/材质，直接透出 RootView 整窗 vibrancy（与标题栏同一块毛玻璃）；任何实色
    // 或再叠一层材质都会把透明感盖掉（.contentBackground 实测与白底难以区分）
    private let split = InteractiveSplitView()
    private let sessionPanel = SessionPanelView()
    private let filePanel = FilePanelView()

    func bindHostStore() {
        sessionPanel.bindHostStore()
    }

    private var didSetInitialLayout = false
    /// 会话/文件面板分栏比例的防抖写盘
    private var splitSaveWork: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        split.isVertical = false
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(sessionPanel)
        split.addArrangedSubview(filePanel)
        // 同主分栏：min/max 走 delegate，不挂外部必需高度约束（否则分隔条拖不动）
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        split.delegate = self
        // 脚本面板跟随树选中主机（未连接也可查看/编辑）
        sessionPanel.onHostPicked = { [weak filePanel] id, label in
            filePanel?.handleHostPicked(id, label: label)
        }

        addSubview(split)

        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.topAnchor.constraint(equalTo: topAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && !didSetInitialLayout {
            MainThread.perform { [self] in
                guard !didSetInitialLayout else { return }
                didSetInitialLayout = true
                // 右栏内部：上会话/下文件管理器，恢复上次比例（默认 45%）
                let saved = UserDefaults.standard.double(forKey: "picoterm.rightSplitRatio")
                let ratio = (saved > 0.15 && saved < 0.85) ? CGFloat(saved) : 0.45
                split.setPosition(bounds.height * ratio, ofDividerAt: 0)
            }
        }
    }
}

// MARK: - 右栏内部分栏尺寸约束（会话面板 ≥ 160，文件管理器 ≥ 200）

extension RightPaneView: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView,
                   constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        proposedMinimumPosition < 160 ? 160 : proposedMinimumPosition
    }

    func splitView(_ splitView: NSSplitView,
                   constrainMaxCoordinate proposedMaximum: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        let max = splitView.bounds.height - 200
        return proposedMaximum > max ? max : proposedMaximum
    }

    /// 拖动/缩放后保存比例（防抖 0.3s）
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard bounds.height > 100 else { return }
        splitSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.bounds.height > 100 else { return }
            UserDefaults.standard.set(Double(self.split.arrangedSubviews[0].frame.height / self.bounds.height),
                                      forKey: "picoterm.rightSplitRatio")
        }
        splitSaveWork = work
        MainThread.perform(after: 0.3, work)
    }
}

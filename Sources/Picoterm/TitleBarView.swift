import AppKit
import PicotermCore

/// 横向滚动视图：垂直滚轮/触摸板手势也映射为横向滚动（tab 栏无纵向内容）
final class HorizontalWheelScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaX != 0 {
            super.scrollWheel(with: event)
        } else if event.scrollingDeltaY != 0, let clip = contentView as? NSClipView {
            let origin = clip.bounds.origin
            let width = tabScrollContentWidth - clip.bounds.width
            let x = min(max(origin.x + event.scrollingDeltaY, 0), max(width, 0))
            clip.scroll(to: NSPoint(x: x, y: 0))
            clip.reflectScrolledClipView(clip)
        } else {
            super.scrollWheel(with: event)
        }
    }

    private var tabScrollContentWidth: CGFloat {
        (documentView?.fittingSize.width ?? 0)
    }
}

// 标题栏：留出系统红绿灯位，左侧会话标签栏 + 右侧操作区
final class TitleBarView: NSVisualEffectView {
    var onToggleRightPane: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let tabStack = NSStackView()
    /// tab 栏横向滚动壳：tab 多时滚动查看（垂直滚轮也映射为横滚）
    private let tabScroll = HorizontalWheelScrollView()
    private let newTabButton = GlassIconButton(symbol: "plus", size: 24, pointSize: 11, tooltip: L("新建连接 ⌘T"))
    private var sessionTabs: [UUID: TabButton] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .titlebar
        blendingMode = .behindWindow
        state = .active
        translatesAutoresizingMaskIntoConstraints = false

        tabStack.orientation = .horizontal
        tabStack.alignment = .centerY
        tabStack.spacing = 6
        tabStack.translatesAutoresizingMaskIntoConstraints = false

        tabScroll.hasHorizontalScroller = true
        tabScroll.hasVerticalScroller = false
        tabScroll.borderType = .noBorder
        tabScroll.drawsBackground = false
        tabScroll.translatesAutoresizingMaskIntoConstraints = false
        tabScroll.horizontalScroller?.controlSize = .small
        // overlay 悬浮滚动条：不占内容高度，tab 保持完整高度贴左排布
        tabScroll.scrollerStyle = .overlay
        tabScroll.documentView = tabStack

        // 双行标题栏：顶行 = 软件名（正中独占一行）+ 右侧操作按钮（左上是系统红绿灯）；
        // 底行 = 会话 tab 栏（贴窗口左缘，无红绿灯避让留白）
        let topRow = NSView()
        topRow.translatesAutoresizingMaskIntoConstraints = false
        let tabRow = NSView()
        tabRow.translatesAutoresizingMaskIntoConstraints = false

        let appLabel = NSTextField(labelWithString: "Picoterm")
        appLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        appLabel.textColor = .labelColor
        appLabel.translatesAutoresizingMaskIntoConstraints = false

        let sidebarButton = GlassIconButton(symbol: "sidebar.right", tooltip: L("显示/隐藏右侧面板 ⌘B"))
        let settingsButton = GlassIconButton(symbol: "gearshape", tooltip: L("设置 ⌘,"))
        let actions = NSStackView(views: [sidebarButton, settingsButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false

        sidebarButton.button.target = self
        sidebarButton.button.action = #selector(toggleSidebar)
        settingsButton.button.target = self
        settingsButton.button.action = #selector(openSettings)

        addSubview(topRow)
        addSubview(tabRow)
        topRow.addSubview(appLabel)
        topRow.addSubview(actions)
        tabRow.addSubview(tabScroll)
        tabStack.addArrangedSubview(newTabButton)

        NSLayoutConstraint.activate([
            // 顶行 0..38 / 底行 38..76（总高由外层 RootView 定 76）
            topRow.topAnchor.constraint(equalTo: topAnchor),
            topRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            topRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            topRow.heightAnchor.constraint(equalToConstant: 38),

            tabRow.topAnchor.constraint(equalTo: topRow.bottomAnchor),
            tabRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabRow.bottomAnchor.constraint(equalTo: bottomAnchor),

            appLabel.centerXAnchor.constraint(equalTo: topRow.centerXAnchor),
            appLabel.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),

            actions.trailingAnchor.constraint(equalTo: topRow.trailingAnchor, constant: -12),
            actions.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
            actions.heightAnchor.constraint(equalToConstant: 30),

            // tab 栏贴左（仅 8pt 边距），右侧 12pt，多 tab 横向滚动
            tabScroll.leadingAnchor.constraint(equalTo: tabRow.leadingAnchor, constant: 8),
            tabScroll.trailingAnchor.constraint(equalTo: tabRow.trailingAnchor, constant: -12),
            tabScroll.centerYAnchor.constraint(equalTo: tabRow.centerYAnchor),
            tabScroll.heightAnchor.constraint(equalToConstant: 34),

            tabStack.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor),
            tabStack.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor),
            tabStack.bottomAnchor.constraint(equalTo: tabScroll.contentView.bottomAnchor),
            tabStack.widthAnchor.constraint(greaterThanOrEqualTo: tabScroll.contentView.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 接入会话管理器：标签 = 真实会话，+ 新建本地 Shell
    func bindSessionManager() {
        let manager = SessionManager.shared
        newTabButton.button.target = self
        newTabButton.button.action = #selector(newLocalShell)
        rebuildTabs()
        manager.observeSessions { [weak self] in self?.rebuildTabs() }
    }

    private func rebuildTabs() {
        let manager = SessionManager.shared
        sessionTabs.values.forEach {
            tabStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        sessionTabs.removeAll()
        for session in manager.sessions {
            let tab = TabButton(title: Self.truncatedTitle(manager.displayTitle(for: session)),
                                symbol: session.symbol,
                                isOn: manager.selected?.id == session.id)
            tab.colorBar = TabColors.color(for: manager.colorTag(for: session))
            tab.setHoverTooltip(Self.hoverTooltip(for: session))
            tab.onSelect = { [weak manager] in manager?.select(session) }
            tab.onClose = { [weak manager] in manager?.close(session) }
            tab.sessionMenu = makeSessionMenu(session: session, otherCount: manager.sessions.count - 1)
            // 拖拽重排（2026-10-24 用户指定）：拖动实时换位，松手提交顺序。
            // 闭包只携带会话 id——按下非选中标签会先触发 select→rebuildTabs 重建全部
            // 标签视图，被按住的旧实例已脱离视图树，所以每次移动都要按 id 重新解析
            // 当前的活标签再换位，直接引用按下时的视图会拖不动
            let sessionId = session.id
            tab.onDragMoved = { [weak self] point in
                self?.reorderTab(sessionId: sessionId, toWindowX: point.x)
            }
            tab.onDragEnded = { [weak self] in self?.commitTabOrder() }
            sessionTabs[session.id] = tab
            tabStack.addArrangedSubview(tab)
        }
        // 「+」保持在末尾
        tabStack.removeArrangedSubview(newTabButton)
        tabStack.addArrangedSubview(newTabButton)
        scrollToSelectedTab()
    }

    /// 选中/新增 tab 滚动到可见区
    private func scrollToSelectedTab() {
        guard let selected = SessionManager.shared.selected,
              let tab = sessionTabs[selected.id] else { return }
        tab.layoutSubtreeIfNeeded()
        tab.scrollToVisible(tab.bounds)
    }

    // MARK: 标签文字与悬停提示（2026-10-25 用户指定）

    /// tab 上只显示前 20 个字符，超出补 "..."（完整文字进悬停提示）
    private static func truncatedTitle(_ text: String) -> String {
        guard text.count > 20 else { return text }
        return String(text.prefix(20)) + "..."
    }

    /// 两行悬停提示：完整标签 + 连接信息（用户名@IP:端口 / telnet 地址 / 串口设备）
    private static func hoverTooltip(for session: TerminalSession) -> String {
        let detail: String?
        if let ssh = session as? SSHSession {
            detail = "\(ssh.config.user)@\(ssh.config.host):\(ssh.config.port)"
        } else if let telnet = session as? TelnetSession {
            detail = telnet.config.identity
        } else if let serial = session as? SerialSession {
            detail = L("%@ @ %ld 波特", serial.devicePath, serial.baudRate)
        } else {
            detail = nil
        }
        let title = SessionManager.shared.displayTitle(for: session)
        return detail.map { "\(title)\n\($0)" } ?? title
    }

    // MARK: 标签右键菜单（重命名 / 颜色 / 关闭会话 / 关闭其他 / 关闭全部，关闭均带二次确认）

    /// 颜色子菜单项载荷
    private final class ColorChoice {
        let session: TerminalSession
        let tag: String
        init(session: TerminalSession, tag: String) {
            self.session = session
            self.tag = tag
        }
    }

    private func makeSessionMenu(session: TerminalSession, otherCount: Int) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let rename = NSMenuItem(title: L("重命名标签…"), action: #selector(renameTabMenuItem(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = session
        menu.addItem(rename)

        let colorItem = NSMenuItem(title: L("颜色"), action: nil, keyEquivalent: "")
        let colors = NSMenu()
        colors.autoenablesItems = false
        let currentTag = SessionManager.shared.colorTag(for: session)
        for preset in TabColors.presets {
            let item = NSMenuItem(title: preset.name, action: #selector(colorMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.image = TabColors.dotImage(for: preset.color)
            item.state = preset.tag == currentTag ? .on : .off
            item.representedObject = ColorChoice(session: session, tag: preset.tag)
            colors.addItem(item)
        }
        colorItem.submenu = colors
        menu.addItem(colorItem)
        menu.addItem(.separator())

        let items: [(String, Selector, Bool)] = [
            (L("关闭会话"), #selector(closeSessionMenuItem(_:)), true),
            (L("关闭其他会话"), #selector(closeOtherSessionsMenuItem(_:)), otherCount > 0),
            (L("关闭所有会话"), #selector(closeAllSessionsMenuItem(_:)), true),
        ]
        for (title, action, enabled) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = session
            item.isEnabled = enabled
            menu.addItem(item)
        }
        return menu
    }

    @objc private func renameTabMenuItem(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? TerminalSession else { return }
        promptRenameTab(session)
    }

    @objc private func colorMenuItem(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ColorChoice else { return }
        SessionManager.shared.setColorTag(choice.tag, for: choice.session)
    }

    /// 重命名标签（右键 / 命令面板）：留空恢复默认；有主机条目时可勾选同步改连接标签
    func promptRenameTab(_ session: TerminalSession) {
        let manager = SessionManager.shared
        var current = manager.customTitle(for: session) ?? session.title
        let disconnectedSuffix = L("（已断开）")
        if current.hasSuffix(disconnectedSuffix) {
            current = String(current.dropLast(disconnectedSuffix.count)).trimmingCharacters(in: .whitespaces)
        }
        let field = NSTextField(string: current)
        field.placeholderString = L("留空恢复默认标题")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        var views: [NSView] = [field]
        let hostEntry = manager.hostEntry(for: session)
        let syncToggle = NSButton(checkboxWithTitle: L("同时更新连接标签"), target: nil, action: nil)
        if hostEntry != nil { views.append(syncToggle) }
        let content = NSStackView(views: views)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        guard PicotermDialog.run(title: L("重命名标签"), content: content, primaryTitle: L("保存"),
                                 parent: window) == .OK else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        manager.setCustomTitle(text, for: session)
        if var entry = hostEntry, syncToggle.state == .on, !text.isEmpty {
            entry.label = text
            HostStore.shared.updateHost(entry)
        }
    }

    @objc private func closeSessionMenuItem(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? TerminalSession else { return }
        guard confirmClose(L("确定关闭会话「%@」？", SessionManager.shared.displayTitle(for: session))) else { return }
        SessionManager.shared.close(session)
    }

    @objc private func closeOtherSessionsMenuItem(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? TerminalSession else { return }
        let others = SessionManager.shared.sessions.filter { $0.id != session.id }
        guard !others.isEmpty else { return }
        guard confirmClose(L("确定关闭其他 %ld 个会话？这些会话将全部断开。", others.count), destructive: true) else { return }
        others.forEach { SessionManager.shared.close($0) }
    }

    @objc private func closeAllSessionsMenuItem(_ sender: NSMenuItem) {
        let all = SessionManager.shared.sessions
        guard !all.isEmpty else { return }
        guard confirmClose(L("确定关闭全部 %ld 个会话？", all.count), destructive: true) else { return }
        all.forEach { SessionManager.shared.close($0) }
    }

    /// 二次确认；批量关闭用红色主按钮
    private func confirmClose(_ text: String, destructive: Bool = false) -> Bool {
        PicotermDialog.run(title: L("关闭会话"),
                           content: PicotermDialog.message(text),
                           primaryTitle: L("关闭"),
                           destructive: destructive,
                           parent: window) == .OK
    }

    @objc private func newLocalShell() {
        SessionManager.shared.createLocalShell()
    }

    // MARK: 标签拖拽重排

    /// 拖动实时换位：按 id 取当前活标签，越过某兄弟 tab 中点 → 插到它前面，否则排到「+」前
    private func reorderTab(sessionId: UUID, toWindowX x: CGFloat) {
        guard let tab = sessionTabs[sessionId] else {
            DebugLog.write("reorder: no live tab")
            return
        }
        let point = tabStack.convert(NSPoint(x: x, y: 0), from: nil)
        let arranged = tabStack.arrangedSubviews
        let siblings = arranged.filter { $0 !== tab && $0 !== newTabButton }
        let anchor = siblings.first { point.x < $0.frame.midX } ?? newTabButton
        guard let currentIndex = arranged.firstIndex(of: tab),
              var targetIndex = arranged.firstIndex(of: anchor) else {
            DebugLog.write("reorder: missing index anchor=\(anchor === newTabButton ? "plus" : "tab")")
            return
        }
        if currentIndex < targetIndex { targetIndex -= 1 } // 移除自身后按剩余序插入
        guard targetIndex != currentIndex else { return }
        DebugLog.write("reorder move \(currentIndex)→\(targetIndex) x=\(Int(x))")
        tabStack.removeArrangedSubview(tab)
        tab.removeFromSuperview()
        tabStack.insertArrangedSubview(tab, at: targetIndex)
        tabStack.layoutSubtreeIfNeeded()
    }

    /// 松手：把 tabStack 的视觉顺序提交回 SessionManager（触发 rebuildTabs 对齐）
    private func commitTabOrder() {
        let idsInOrder = tabStack.arrangedSubviews.compactMap { view in
            sessionTabs.first { $0.value === view }?.key
        }
        SessionManager.shared.reorderSessions(byIds: idsInOrder)
    }

    @objc private func toggleSidebar() { onToggleRightPane?() }

    @objc private func openSettings() { onOpenSettings?() }

    override func mouseDown(with event: NSEvent) {
        // 点击标签栏空白处拖动窗口
        window?.performDrag(with: event)
    }
}

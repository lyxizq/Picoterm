import AppKit
import SwiftTerm
import PicotermCore

// 左侧终端区：单一终端卡片（会话切换时在卡片里换装终端视图，回滚缓冲由会话自身保活）
final class TerminalPaneView: NSView, NSMenuItemValidation, NSMenuDelegate {
    private var card: NSView?
    private(set) var currentSession: TerminalSession?
    private let palette = CommandPaletteView()
    private var splitView: InteractiveSplitView!
    /// 服务器状态条（SSH 会话下方；本地 Shell / 采集不可用时隐藏）
    private let metricsBar = ServerMetricsBarView()
    /// 终端卡片底 ↔ 状态条顶的间距（状态条隐藏时归零，保持原布局）
    private var cardBottomToMetricsBar: NSLayoutConstraint!
    /// 终端搜索条（⌘F；WindTerm 式悬浮卡片右上角，全部匹配高亮 + 逐个跳转）
    private let searchBar = TerminalSearchBarView()

    override init(frame frameRect: NSRect) {
        let paneSplit = InteractiveSplitView()
        paneSplit.isVertical = true
        paneSplit.dividerStyle = .thin
        paneSplit.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: frameRect)

        palette.isHidden = true
        palette.onClose = { [weak self] in self?.refocusTerminal() }

        metricsBar.isHidden = true
        metricsBar.onVisibilityChange = { [weak self] visible in
            self?.cardBottomToMetricsBar?.constant = visible ? -8 : 0
        }

        searchBar.isHidden = true
        searchBar.onSearchChanged = { [weak self] text in self?.searchChanged(text) }
        searchBar.onFindNext = { [weak self] in self?.findInTerminal(next: true) }
        searchBar.onFindPrevious = { [weak self] in self?.findInTerminal(next: false) }
        searchBar.onClose = { [weak self] in self?.closeSearch() }

        addSubview(paneSplit)
        addSubview(metricsBar)
        addSubview(palette)
        addSubview(searchBar)
        NSLayoutConstraint.activate([
            palette.centerXAnchor.constraint(equalTo: centerXAnchor),
            palette.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            palette.widthAnchor.constraint(equalToConstant: 480),
            palette.heightAnchor.constraint(equalToConstant: 320),

            searchBar.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            searchBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])

        cardBottomToMetricsBar = paneSplit.bottomAnchor.constraint(equalTo: metricsBar.topAnchor)
        NSLayoutConstraint.activate([
            paneSplit.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            cardBottomToMetricsBar,
            paneSplit.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            paneSplit.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),

            metricsBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            metricsBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            metricsBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])

        splitView = paneSplit
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func presentPalette(items: [PaletteItem]) {
        palette.present(items: items)
    }

    // MARK: 终端搜索（⌘F；参考 WindTerm 查找）

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "f" {
            openSearch()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private var searchableTerminal: TerminalView? {
        currentSession?.terminalView as? TerminalView
    }

    private func openSearch() {
        searchBar.isHidden = false
        searchBar.focus()
    }

    private func searchChanged(_ text: String) {
        guard let terminal = searchableTerminal else { return }
        let query = text.trimmingCharacters(in: .whitespaces)
        terminal.setSearchHighlights(term: query)
        if !query.isEmpty {
            terminal.findNext(query, scrollToResult: true)
        }
        updateSearchCount()
    }

    private func findInTerminal(next: Bool) {
        guard let terminal = searchableTerminal else { return }
        let query = searchBar.searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        if next {
            terminal.findNext(query, scrollToResult: true)
        } else {
            terminal.findPrevious(query, scrollToResult: true)
        }
        updateSearchCount()
    }

    private func updateSearchCount() {
        guard let terminal = searchableTerminal else { return }
        let query = searchBar.searchText.trimmingCharacters(in: .whitespaces)
        let (index, total) = terminal.searchMatchSummary(query)
        searchBar.setCount(query.isEmpty || total == 0 ? L("无结果") : "\(index)/\(total)")
    }

    private func closeSearch() {
        if let terminal = searchableTerminal {
            terminal.clearSearch()
            terminal.clearSearchHighlights()
        }
        searchBar.searchText = ""
        searchBar.setCount("")
        searchBar.isHidden = true
        refocusTerminal()
    }

    private func refocusTerminal() {
        if let currentSession {
            window?.makeFirstResponder(currentSession.terminalView)
        }
    }

    // MARK: 终端右键菜单（参考 WindTerm 终端右键菜单；未实现的能力不进菜单）

    private lazy var contextMenu: NSMenu = makeContextMenu()

    /// 右键位置命中的链接（menuNeedsUpdate 时取，供「打开/复制链接」两项用）
    private var contextLink: (link: String, params: [String: String])?
    private static let linkItemTag = 9001

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return item
        }
        add(L("复制"), #selector(ctxCopy(_:)))
        add(L("粘贴"), #selector(ctxPaste(_:)))
        menu.addItem(.separator())
        let find = add(L("查找…"), #selector(ctxFind(_:)))
        find.keyEquivalent = "f" // 仅展示快捷键，⌘F 事件由终端区 performKeyEquivalent 接管
        let online = add(L("在线搜索"), #selector(ctxSearchOnline(_:)))
        let engines = NSMenu()
        for (name, template) in [("Google", "https://www.google.com/search?q=%@"),
                                 ("Bing", "https://www.bing.com/search?q=%@"),
                                 (L("百度"), "https://www.baidu.com/s?wd=%@")] {
            let engine = NSMenuItem(title: name, action: #selector(ctxSearchWith(_:)), keyEquivalent: "")
            engine.target = self
            engine.representedObject = template
            engines.addItem(engine)
        }
        online.submenu = engines
        menu.addItem(.separator())
        add(L("清屏"), #selector(ctxClearScreen(_:)))
        add(L("清除回滚"), #selector(ctxClearScrollback(_:)))
        add(L("全部清除"), #selector(ctxClearAll(_:)))
        menu.addItem(.separator())
        add(L("全选"), #selector(ctxSelectAll(_:)))
        add(L("重置"), #selector(ctxReset(_:)))
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(ctxCopy(_:)), #selector(ctxSearchOnline(_:)), #selector(ctxSearchWith(_:)):
            return !(searchableTerminal?.getSelection() ?? "").isEmpty
        case #selector(ctxPaste(_:)):
            return NSPasteboard.general.string(forType: .string) != nil
        case #selector(ctxOpenLink(_:)), #selector(ctxCopyLink(_:)):
            return contextLink != nil
        default:
            return currentSession != nil
        }
    }

    /// 右键落在链接（URL/路径）上时菜单顶部多出「打开链接 / 复制链接」；每次弹出前重算
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.filter { $0.tag == Self.linkItemTag }.forEach { menu.removeItem($0) }
        contextLink = nil
        guard let terminal = searchableTerminal, let event = NSApp.currentEvent,
              event.type == .rightMouseDown || event.type == .leftMouseDown else { return }
        let point = terminal.convert(event.locationInWindow, from: nil)
        guard let found = terminal.link(at: point) else { return }
        contextLink = found
        let display = found.link.count > 60 ? String(found.link.prefix(60)) + "…" : found.link
        let open = NSMenuItem(title: L("打开链接 %@", display), action: #selector(ctxOpenLink(_:)), keyEquivalent: "")
        let copy = NSMenuItem(title: L("复制链接"), action: #selector(ctxCopyLink(_:)), keyEquivalent: "")
        let separator = NSMenuItem.separator()
        for (index, item) in [open, copy, separator].enumerated() {
            item.target = self
            item.tag = Self.linkItemTag
            menu.insertItem(item, at: index)
        }
    }

    /// 经会话的 requestOpenLink 走统一口径（SSH 路径跳文件管理器、本地路径进 Finder、白名单外不动）
    @objc private func ctxOpenLink(_ sender: NSMenuItem) {
        guard let terminal = searchableTerminal, let found = contextLink else { return }
        terminal.terminalDelegate?.requestOpenLink(source: terminal, link: found.link, params: found.params)
    }

    @objc private func ctxCopyLink(_ sender: NSMenuItem) {
        guard let found = contextLink else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(found.link, forType: .string)
    }

    @objc private func ctxCopy(_ sender: NSMenuItem) {
        // 直达终端视图的 copy: 选择器（响应链 sendAction 会误中搜索框等焦点控件）
        searchableTerminal?.perform(#selector(NSText.copy(_:)), with: sender)
    }

    @objc private func ctxPaste(_ sender: NSMenuItem) {
        // paste: 走 SwiftTerm 内部粘贴路径（括号粘贴模式等已处理）
        searchableTerminal?.perform(#selector(NSText.paste(_:)), with: sender)
    }

    @objc private func ctxFind(_ sender: NSMenuItem) {
        openSearch()
    }

    @objc private func ctxSearchOnline(_ sender: NSMenuItem) {} // 仅为让父项随选区可用性联动

    @objc private func ctxSearchWith(_ sender: NSMenuItem) {
        guard let template = sender.representedObject as? String else { return }
        let query = (searchableTerminal?.getSelection() ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, var components = URLComponents(string: template) else { return }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "%@", with: encoded)
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func ctxClearScreen(_ sender: NSMenuItem) {
        // SSH 走横幅保留管道（清屏后回插登录横幅），本地 shell 直接喂清屏序列
        if let ssh = currentSession as? SSHSession {
            ssh.clearScreenKeepingBanner()
        } else {
            searchableTerminal?.feed(text: "\u{1b}[H\u{1b}[2J")
        }
    }

    @objc private func ctxClearScrollback(_ sender: NSMenuItem) {
        searchableTerminal?.clearScrollback()
    }

    @objc private func ctxClearAll(_ sender: NSMenuItem) {
        ctxClearScrollback(sender)
        ctxClearScreen(sender)
    }

    @objc private func ctxSelectAll(_ sender: NSMenuItem) {
        searchableTerminal?.selectAll()
    }

    @objc private func ctxReset(_ sender: NSMenuItem) {
        searchableTerminal?.resetToInitialState()
        // SSH 重置后同样回插登录横幅，与 clear 口径一致
        (currentSession as? SSHSession)?.clearScreenKeepingBanner()
    }

    // MARK: 终端卡片

    private func makeCard() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.masksToBounds = true
        card.layer?.backgroundColor = AppTheme.terminalBackground.withAlphaComponent(0.98).cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
        return card
    }

    private func embed(session: TerminalSession, in card: NSView) {
        let view = session.terminalView
        view.translatesAutoresizingMaskIntoConstraints = false
        view.menu = contextMenu
        // 清掉卡片上旧会话的补全容器，避免 Tab 落到别的会话
        card.subviews.compactMap { $0 as? CompletionTerminalContainer }.forEach {
            ($0.terminalView as? CompletionTerminalView)?.completionContainer = nil
            $0.removeFromSuperview()
        }
        card.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: card.topAnchor),
            view.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        // ⇥ 补全容器（SSH 会话；本地 shell 交由 shell 自身补全）
        if let completionView = view as? CompletionTerminalView {
            let container = CompletionTerminalContainer(terminalView: completionView)
            card.addSubview(container)
            NSLayoutConstraint.activate([
                container.topAnchor.constraint(equalTo: card.topAnchor),
                container.bottomAnchor.constraint(equalTo: card.bottomAnchor),
                container.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            ])
            completionView.completionContainer = container
            if let window = window {
                completionView.installMonitor(in: window)
            } else {
                // 首次挂载时窗口可能未就绪，延迟一拍再装
                MainThread.perform { [weak completionView] in
                    if let window = completionView?.window {
                        completionView?.installMonitor(in: window)
                    }
                }
            }
        }
    }

    /// 切换选中会话：同一会话聚焦，否则换装进唯一卡片
    func show(_ session: TerminalSession) {
        if currentSession?.id == session.id {
            window?.makeFirstResponder(session.terminalView)
            return
        }
        if card == nil {
            let newCard = makeCard()
            splitView.addArrangedSubview(newCard)
            card = newCard
        }
        if let card {
            embed(session: session, in: card)
            currentSession = session
            metricsBar.bind(session as? SSHSession)
            // 搜索条的高亮/选区属于上一个终端视图，换会话即收起
            closeSearch()
            window?.makeFirstResponder(session.terminalView)
        }
    }

    /// 会话关闭后：被关的是当前会话则清空卡片（下一会话由 show 换装）
    func prune(kept ids: [UUID]) {
        if let current = currentSession, !ids.contains(current.id) {
            currentSession = nil
            metricsBar.bind(nil)
            if let card {
                card.subviews.forEach { $0.removeFromSuperview() }
                splitView.removeArrangedSubview(card)
                card.removeFromSuperview()
            }
            self.card = nil
        }
    }
}

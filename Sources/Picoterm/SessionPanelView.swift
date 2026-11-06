import AppKit
import PicotermCore

// 右上面板：会话列表（真实主机树，来自 HostStore）
final class SessionPanelView: NSView {
    private let sessionsTab = TabButton(title: L("会话"), symbol: "terminal.fill", isOn: true, showsClose: false, height: 26)
    private let scroll = NSScrollView()
    private let outline = NSOutlineView()
    private let contextMenu = NSMenu()

    /// 树选中主机（单击）：id 为 nil 表示选中了非主机节点（调用方回退到会话来源）
    var onHostPicked: ((UUID?, String) -> Void)?

    private var nodes: [Node] = []

    /// 行高随字号设置（行高 = 字号 + 13，默认 13 → 26）
    static var rowHeightForFont: CGFloat {
        CGFloat(AppSettings.shared.sessionListFontSize + 13)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(forName: .listFontSizeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyFontSize()
        }

        let header = Surfaces.glass(hairline: .bottom)
        header.translatesAutoresizingMaskIntoConstraints = false

        let tools = NSStackView(views: [
            GlassIconButton(symbol: "plus", size: 22, pointSize: 10, tooltip: L("新建连接")),
            GlassIconButton(symbol: "folder.badge.plus", size: 22, pointSize: 10, tooltip: L("新建分组")),
        ])
        tools.orientation = .horizontal
        tools.alignment = .centerY
        tools.spacing = 4
        tools.translatesAutoresizingMaskIntoConstraints = false
        if let buttons = tools.arrangedSubviews as? [GlassIconButton], buttons.count >= 2 {
            buttons[0].button.target = self
            buttons[0].button.action = #selector(newConnection)
            buttons[1].button.target = self
            buttons[1].button.action = #selector(newGroup)
        }

        let headerTabs = NSStackView(views: [sessionsTab])
        headerTabs.orientation = .horizontal
        headerTabs.alignment = .centerY
        headerTabs.spacing = 6
        headerTabs.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(headerTabs)
        header.addSubview(tools)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowHeight = Self.rowHeightForFont
        outline.indentationPerLevel = 12
        outline.indentationMarkerFollowsCell = false
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(rowDoubleClicked)
        outline.menu = contextMenu
        contextMenu.delegate = self
        outline.autosaveExpandedItems = false
        // 列宽自行管理：按最长行撑开、超出可视宽出横向滚动条，标签不再省略号截断
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        // 拖拽主机到不同分组（2026-10-24 用户指定）：仅主机行可拖起，分组为投放目标
        outline.registerForDraggedTypes([Self.hostDragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(scroll)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),

            headerTabs.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            headerTabs.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            tools.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            tools.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            tools.heightAnchor.constraint(equalToConstant: 24),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 字号设置变化：重算行高并刷新（单元格字体在 configure 时随设置重取）
    private func applyFontSize() {
        outline.rowHeight = Self.rowHeightForFont
        outline.reloadData()
        syncHorizontalWidth()
    }

    override func layout() {
        super.layout()
        syncHorizontalWidth()
    }

    /// 面板宽度变化时保底撑满可视宽（内容更宽时保持内容宽，横向滚动查看）
    private func syncHorizontalWidth() {
        guard outline.tableColumns.count == 1 else { return }
        var needed: CGFloat = 0
        func measure(_ node: Node, level: Int) {
            needed = max(needed, CGFloat(level) * outline.indentationPerLevel + 26
                         + NodeCellView.contentWidth(node: node))
            node.children.forEach { measure($0, level: level + 1) }
        }
        nodes.forEach { measure($0, level: 0) }
        let column = outline.tableColumns[0]
        let width = max(needed, scroll.contentSize.width)
        guard width > 0.5 else { return }
        if abs(column.width - width) > 0.5 {
            column.width = width
        }
    }

    /// 接入主机存储：树 = 真实分组与连接
    func bindHostStore() {
        HostStore.shared.observe { [weak self] in self?.refreshTree() }
        refreshTree()
    }

    private func refreshTree() {
        nodes = HostStore.shared.groups.map { group in
            let children = HostStore.shared.hosts(in: group).map { entry in
                Node(title: entry.label,
                     detail: "\(entry.user)@\(entry.host):\(entry.port)",
                     symbol: "server.rack",
                     tint: TabColors.color(for: entry.colorTag),
                     children: [],
                     ref: "host:\(entry.id.uuidString)")
            }
            return Node(title: group.name, symbol: "folder.fill", tint: .systemBlue,
                        children: children, ref: "group:\(group.id.uuidString)")
        }
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        syncHorizontalWidth()
    }

    // MARK: 新建 / 连接 / 编辑 / 删除

    @objc private func newConnection() {
        showConnectionDialog(editing: nil, defaultGroupId: HostStore.shared.groups.first?.id)
    }

    @objc private func newGroup() {
        promptText(title: L("新建分组"), placeholder: L("分组名称")) { name in
            guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            HostStore.shared.addGroup(named: name.trimmingCharacters(in: .whitespaces))
        }
    }

    private func showConnectionDialog(editing entry: HostEntry?, defaultGroupId: UUID?) {
        let groups = HostStore.shared.groups
        guard !groups.isEmpty else { return }
        // 自建模态窗口（无 NSAlert 大图标）；取消/关窗返回 nil
        // 编辑时把已存密码回填进弹窗——否则空密码框保存会把 secrets.json 里的记录删掉
        let controller = ConnectionDialogWindowController(groups: groups, entry: entry,
                                                          defaultGroupId: defaultGroupId,
                                                          initialSecret: entry.flatMap { HostStore.shared.secret(for: $0.id) })
        controller.runModal()
        guard let result = controller.result else { return }
        HostStore.shared.setSecret(result.secret, for: result.entry.id)
        if entry == nil {
            HostStore.shared.addHost(result.entry)
        } else {
            HostStore.shared.updateHost(result.entry)
        }
    }

    private func connect(_ entry: HostEntry) {
        // Telnet/串口无凭据：直接走统一入口；SSH 密码未存时提示补录
        guard entry.proto == "ssh" else {
            SessionManager.shared.createSession(for: entry)
            return
        }
        let (config, needsSecret) = HostStore.shared.sshConfig(for: entry)
        if !needsSecret {
            SessionManager.shared.createSession(for: entry)
            return
        }
        // 密码未存：提示输入，可勾选记住（存数据目录 secrets.json）；点眼睛验证身份后可核对明文
        let input = RevealableSecretField()
        input.placeholderString = L("密码")
        input.authReason = L("显示正在输入的密码")
        let remember = NSButton(checkboxWithTitle: L("记住密码"), target: nil, action: nil)
        remember.state = .on
        let content = NSStackView(views: [
            PicotermDialog.message("\(entry.user)@\(entry.host):\(entry.port)", width: 300),
            input, remember,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        guard PicotermDialog.run(title: L("输入密码"), content: content, primaryTitle: L("连接"),
                                 parent: window) == .OK, !input.stringValue.isEmpty else { return }
        if remember.state == .on {
            HostStore.shared.setSecret(input.stringValue, for: entry.id)
        }
        var patched = config
        patched.auth = .password(input.stringValue)
        SessionManager.shared.createSSHSession(config: patched, hostEntryId: entry.id)
    }

    private func editEntry(_ entry: HostEntry) {
        showConnectionDialog(editing: entry, defaultGroupId: entry.groupId)
    }

    private func deleteEntry(_ entry: HostEntry) {
        let text = L("确定删除「%@」（%@）？其保存的密码将一并删除。", entry.label, "\(entry.user)@\(entry.host)")
        guard PicotermDialog.run(title: L("删除连接"), content: PicotermDialog.message(text),
                                 primaryTitle: L("删除"), destructive: true,
                                 parent: window) == .OK else { return }
        HostStore.shared.deleteHost(id: entry.id)
    }

    private func deleteGroup(_ group: HostGroup) {
        let count = HostStore.shared.hosts(in: group).count
        let text = count > 0
            ? L("分组「%@」下有 %ld 个连接，删除将一并移除。", group.name, count)
            : L("确定删除分组「%@」？", group.name)
        guard PicotermDialog.run(title: L("删除分组"), content: PicotermDialog.message(text),
                                 primaryTitle: L("删除"), destructive: true,
                                 parent: window) == .OK else { return }
        HostStore.shared.deleteGroup(id: group.id)
    }

    private func promptText(title: String, placeholder: String, completion: @escaping (String?) -> Void) {
        let input = NSTextField(string: "")
        input.placeholderString = placeholder
        let response = PicotermDialog.run(title: title, content: input, primaryTitle: L("确定"),
                                          parent: window)
        completion(response == .OK ? input.stringValue : nil)
    }

    // MARK: 双击 / 右键

    @objc private func rowDoubleClicked() {
        guard let node = clickedNode(), let ref = node.ref else { return }
        if ref.hasPrefix("host:") {
            if let entry = hostEntry(from: ref) { connect(entry) }
        } else if ref.hasPrefix("group:") {
            if outline.isItemExpanded(node) {
                outline.collapseItem(node)
            } else {
                outline.expandItem(node)
            }
        }
    }

    private func clickedNode() -> Node? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard row >= 0 else { return nil }
        return outline.item(atRow: row) as? Node
    }

    private func hostEntry(from ref: String) -> HostEntry? {
        guard ref.hasPrefix("host:"), let id = UUID(uuidString: String(ref.dropFirst(5))) else { return nil }
        return HostStore.shared.hosts.first { $0.id == id }
    }

    private func group(from ref: String) -> HostGroup? {
        guard ref.hasPrefix("group:"), let id = UUID(uuidString: String(ref.dropFirst(6))) else { return nil }
        return HostStore.shared.groups.first { $0.id == id }
    }
}

extension SessionPanelView: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? nodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? nodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.isGroup ?? false
    }

    // MARK: 拖拽主机换分组

    static let hostDragType = NSPasteboard.PasteboardType("com.lyxizq.picoterm.host")

    /// 仅主机行可拖起（分组不可拖）
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? Node, let ref = node.ref, ref.hasPrefix("host:"),
              let entry = hostEntry(from: ref) else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(entry.id.uuidString, forType: Self.hostDragType)
        return pasteboardItem
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let node = item as? Node, let ref = node.ref,
              dragHostId(from: info) != nil else { return [] }
        if ref.hasPrefix("group:") {
            return .move // 命中分组行：-1=落行上（组尾追加），否则按插入线位置
        }
        // 命中主机行：重定向为其所属分组的插入线（插到该主机位置）
        guard let entry = hostEntry(from: ref),
              let parentNode = groupNode(containingHost: entry.id) else { return [] }
        let position = parentNode.children.firstIndex { $0.ref == node.ref } ?? parentNode.children.count
        outline.setDropItem(parentNode, dropChildIndex: position)
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard let idText = dragHostId(from: info), let id = UUID(uuidString: idText),
              let node = item as? Node, let ref = node.ref, ref.hasPrefix("group:"),
              let group = group(from: ref) else { return false }
        // 同组内拖动时 outline 给的 childIndex 含被拖行自身，HostStore 移除后重算位置可容忍 ±1
        HostStore.shared.moveHost(id: id, toGroup: group.id,
                                  index: index >= 0 ? index : nil)
        return true
    }

    private func dragHostId(from info: NSDraggingInfo) -> String? {
        info.draggingPasteboard.string(forType: Self.hostDragType)
    }

    /// 主机所在分组的树节点
    private func groupNode(containingHost hostId: UUID) -> Node? {
        let ref = "host:\(hostId.uuidString)"
        return nodes.first { group in group.children.contains { $0.ref == ref } }
    }
}

extension SessionPanelView: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("nodeCell")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NodeCellView) ?? NodeCellView()
        cell.identifier = identifier
        cell.configure(node: node)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { true }

    /// 单击选中：主机节点 → 通知脚本面板（未连接也可查看/编辑其脚本）；非主机节点回退
    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node,
              let ref = node.ref, ref.hasPrefix("host:"),
              let entry = hostEntry(from: ref) else {
            onHostPicked?(nil, "")
            return
        }
        onHostPicked?(entry.id, entry.label)
    }
}

extension SessionPanelView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = clickedNode() else {
            menu.addItem(NSMenuItem(title: L("新建连接"), action: #selector(newConnection), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: L("新建分组"), action: #selector(newGroup), keyEquivalent: ""))
            return
        }
        if let ref = node.ref, ref.hasPrefix("group:") {
            menu.addItem(NSMenuItem(title: L("在此分组下新建连接"), action: #selector(newConnectionInGroup(_:)), keyEquivalent: ""))
            if let group = group(from: ref) {
                let count = HostStore.shared.hosts(in: group).count
                if count > 0 {
                    menu.addItem(NSMenuItem(title: L("连接本组全部主机（%ld）", count), action: #selector(connectGroupMenu(_:)), keyEquivalent: ""))
                }
            }
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: L("删除分组"), action: #selector(deleteGroupMenu(_:)), keyEquivalent: ""))
            menu.items.forEach { $0.target = self; $0.representedObject = ref }
        } else if let ref = node.ref, ref.hasPrefix("host:"), let entry = hostEntry(from: ref) {
            menu.addItem(NSMenuItem(title: L("连接"), action: #selector(connectMenu(_:)), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: L("编辑"), action: #selector(editMenu(_:)), keyEquivalent: ""))
            let colorItem = NSMenuItem(title: L("颜色"), action: nil, keyEquivalent: "")
            colorItem.submenu = makeColorMenu(for: entry)
            menu.addItem(colorItem)
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: L("删除"), action: #selector(deleteMenu(_:)), keyEquivalent: ""))
            menu.items.forEach { $0.target = self; $0.representedObject = entry.id.uuidString }
        }
    }

    /// 主机颜色子菜单（2026-10-26 用户指定）：与标签右键同一套 6 色预设，写回 HostEntry.colorTag
    private final class HostColorChoice {
        let id: UUID
        let tag: String
        init(id: UUID, tag: String) {
            self.id = id
            self.tag = tag
        }
    }

    private func makeColorMenu(for entry: HostEntry) -> NSMenu {
        let colors = NSMenu()
        colors.autoenablesItems = false
        for preset in TabColors.presets {
            let item = NSMenuItem(title: preset.name, action: #selector(hostColorMenu(_:)), keyEquivalent: "")
            item.target = self
            item.image = TabColors.dotImage(for: preset.color)
            item.state = preset.tag == entry.colorTag ? .on : .off
            item.representedObject = HostColorChoice(id: entry.id, tag: preset.tag)
            colors.addItem(item)
        }
        return colors
    }

    @objc private func hostColorMenu(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? HostColorChoice,
              var entry = HostStore.shared.hosts.first(where: { $0.id == choice.id }) else { return }
        entry.colorTag = choice.tag
        HostStore.shared.updateHost(entry)
    }

    @objc private func newConnectionInGroup(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? String,
              let group = group(from: ref) else { return }
        showConnectionDialog(editing: nil, defaultGroupId: group.id)
    }

    /// 分组一键全连（工作区模板的简化形态，2026-10-26 用户指定）：已开着的 SSH 主机不重复连，
    /// 密码未存的主机照常逐个弹补录框
    @objc private func connectGroupMenu(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? String, let group = group(from: ref) else { return }
        let openIds = Set(SessionManager.shared.sessions.compactMap { ($0 as? SSHSession)?.hostEntryId })
        for entry in HostStore.shared.hosts(in: group) where !openIds.contains(entry.id) {
            connect(entry)
        }
    }

    @objc private func connectMenu(_ sender: NSMenuItem) {
        guard let idText = sender.representedObject as? String,
              let id = UUID(uuidString: idText),
              let entry = HostStore.shared.hosts.first(where: { $0.id == id }) else { return }
        connect(entry)
    }

    @objc private func editMenu(_ sender: NSMenuItem) {
        guard let idText = sender.representedObject as? String,
              let id = UUID(uuidString: idText),
              let entry = HostStore.shared.hosts.first(where: { $0.id == id }) else { return }
        editEntry(entry)
    }

    @objc private func deleteMenu(_ sender: NSMenuItem) {
        guard let idText = sender.representedObject as? String,
              let id = UUID(uuidString: idText),
              let entry = HostStore.shared.hosts.first(where: { $0.id == id }) else { return }
        deleteEntry(entry)
    }

    @objc private func deleteGroupMenu(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? String, let group = group(from: ref) else { return }
        deleteGroup(group)
    }
}

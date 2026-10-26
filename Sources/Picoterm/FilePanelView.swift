import AppKit
import UniformTypeIdentifiers
import PicotermCore

// 系统文件图标：按扩展名走 macOS 识别（NSWorkspace），目录用文件夹图标
// （2026-10-23 用户指定：列表与属性弹窗共用）
enum FileIcons {
    static func image(name: String, isDir: Bool, size: CGFloat? = nil) -> NSImage {
        let base = isDir ? NSWorkspace.shared.icon(for: .folder)
            : NSWorkspace.shared.icon(for: UTType(filenameExtension: (name as NSString).pathExtension) ?? .data)
        guard let size else { return base }
        let scaled = base.copy() as! NSImage
        scaled.size = NSSize(width: size, height: size)
        return scaled
    }
}

// 右下面板：SFTP 文件管理器（真实远端目录：列表/进入/上传/下载/新建目录）
final class FilePanelView: NSView {
    private var entries: [SFTPService.Entry] = []
    private let contextMenu = NSMenu()

    /// 行高随字号设置（行高 = 字号 + 13，默认 13 → 26）
    static var rowHeightForFont: CGFloat {
        CGFloat(AppSettings.shared.fileListFontSize + 13)
    }

    private let table = FileTableView()
    private let scroll = NSScrollView()
    private let pathBox = PathBoxView()
    /// 「…」下拉按钮
    private var moreButton: GlassIconButton?
    /// 目录收藏（2026-10-26 用户指定）：星形按钮弹收藏菜单，当前目录已收藏时实心
    private var favoriteButton: GlassIconButton?
    private let pathField = PathEditField(string: "/")
    /// 当前目录搜索（2026-10-24 用户指定：搜索按钮 → 弹出输入框 → 回车筛选；换目录自动清空）
    private var searchText = ""
    private var searchButton: GlassIconButton?
    private let searchEditField = PathEditField(string: "")
    /// 上一次渲染的目录：识别换目录以清空过滤
    private var lastDirectory = ""
    private let summaryLabel = NSTextField(labelWithString: L("未连接（连接 SSH 主机后自动打开）"))
    private let crumbStack = CrumbStackView()

    // 「文件 / 脚本」双页签：文件区与脚本区互斥展示（TODO 23）
    private let fileContainer = NSView()
    private let snippetContainer = NSView()
    private let snippetPanel = SnippetPanelView()
    private var fileTab: TabButton?
    private var snippetTab: TabButton?

    private struct Columns {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let date = NSUserInterfaceItemIdentifier("date")
        static let kind = NSUserInterfaceItemIdentifier("kind")
        static let perm = NSUserInterfaceItemIdentifier("perm")
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(forName: .listFontSizeChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            table.rowHeight = Self.rowHeightForFont
            table.reloadData()
        }

        // 面板头：文件管理器 / 脚本 页签
        let header = Surfaces.glass(hairline: .bottom)
        header.translatesAutoresizingMaskIntoConstraints = false

        let tabFile = TabButton(title: L("文件管理器"), symbol: "folder.fill", isOn: true, showsClose: false, height: 26)
        let tabScript = TabButton(title: L("脚本"), symbol: "curlybraces", isOn: false, showsClose: false, height: 26)
        tabFile.onSelect = { [weak self] in self?.switchTab(.file) }
        tabScript.onSelect = { [weak self] in self?.switchTab(.snippet) }
        fileTab = tabFile
        snippetTab = tabScript

        header.addSubview(tabFile)
        header.addSubview(tabScript)

        // 路径栏：功能按钮在右（前进/后退按钮已按 2026-10-24 用户指定移除）
        let pathBar = NSView()
        pathBar.translatesAutoresizingMaskIntoConstraints = false

        let pathButtons = NSStackView(views: [
            GlassIconButton(symbol: "arrow.up", size: 22, pointSize: 10, tooltip: L("上级目录")),
            GlassIconButton(symbol: "arrow.triangle.2.circlepath", size: 22, pointSize: 10, tooltip: L("刷新")),
            GlassIconButton(symbol: "star", size: 22, pointSize: 10, tooltip: L("收藏目录")),
            GlassIconButton(symbol: "ellipsis", size: 22, pointSize: 10, tooltip: L("新建 / 跳转")),
        ])
        pathButtons.orientation = .horizontal
        pathButtons.alignment = .centerY
        pathButtons.spacing = 4
        pathButtons.translatesAutoresizingMaskIntoConstraints = false
        if let buttons = pathButtons.arrangedSubviews as? [GlassIconButton] {
            buttons[0].button.target = self
            buttons[0].button.action = #selector(goUp)
            buttons[1].button.target = self
            buttons[1].button.action = #selector(refreshList)
            favoriteButton = buttons[2]
            buttons[2].button.target = self
            buttons[2].button.action = #selector(favoriteClicked)
            moreButton = buttons[3]
            buttons[3].button.target = self
            buttons[3].button.action = #selector(moreClicked)
        }

        // 地址栏（TODO 77）：分段点击直达；点 … 按钮或空白处进入路径输入，回车跳转
        pathBox.translatesAutoresizingMaskIntoConstraints = false
        pathBox.wantsLayer = true
        pathBox.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.02).cgColor
        pathBox.layer?.cornerRadius = 8
        pathBox.onClicked = { [weak self] in self?.enterPathEdit() }
        pathBox.toolTip = L("点击分段直达；点 … 或空白处输入路径回车跳转")

        let pathMenu = NSMenu()
        pathMenu.autoenablesItems = false
        for (title, action) in [(L("复制路径"), #selector(copyPath)), (L("编辑路径…"), #selector(editPath))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            pathMenu.addItem(item)
        }
        pathBox.menu = pathMenu

        crumbStack.orientation = .horizontal
        crumbStack.alignment = .centerY
        crumbStack.spacing = 3
        crumbStack.translatesAutoresizingMaskIntoConstraints = false

        pathField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        pathField.isBordered = false
        pathField.drawsBackground = false
        pathField.focusRingType = .none
        pathField.target = self
        pathField.action = #selector(pathSubmitted)
        pathField.delegate = self
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.isHidden = true
        pathField.onCancel = { [weak self] in self?.exitPathEdit(reason: "esc") }

        let searchButton = GlassIconButton(symbol: "magnifyingglass", size: 22, pointSize: 10,
                                           tooltip: L("搜索当前目录（回车筛选；清空后回车恢复全部）"))
        searchButton.button.target = self
        searchButton.button.action = #selector(searchClicked)
        self.searchButton = searchButton

        searchEditField.placeholderString = L("搜索当前目录（多个关键字用空格分隔）")
        searchEditField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        searchEditField.isBordered = false
        searchEditField.drawsBackground = false
        searchEditField.focusRingType = .none
        searchEditField.target = self
        searchEditField.action = #selector(searchSubmitted)
        searchEditField.delegate = self
        searchEditField.translatesAutoresizingMaskIntoConstraints = false
        searchEditField.isHidden = true
        searchEditField.onCancel = { [weak self] in self?.exitSearchEdit() }

        pathBar.addSubview(pathBox)
        pathBox.addSubview(crumbStack)
        pathBox.addSubview(pathField)
        pathBox.addSubview(searchEditField)
        pathBar.addSubview(searchButton)
        pathBar.addSubview(pathButtons)

        // 文件表：名称 | 大小 | 修改时间 | 类型（后缀）
        let nameColumn = NSTableColumn(identifier: Columns.name)
        nameColumn.title = L("名称")
        nameColumn.width = 160
        nameColumn.minWidth = 100
        nameColumn.resizingMask = .autoresizingMask
        let sizeColumn = NSTableColumn(identifier: Columns.size)
        sizeColumn.title = L("大小")
        sizeColumn.width = 70
        sizeColumn.minWidth = 52
        sizeColumn.maxWidth = 110
        sizeColumn.resizingMask = .userResizingMask
        let kindColumn = NSTableColumn(identifier: Columns.kind)
        kindColumn.title = L("类型")
        kindColumn.width = 60
        kindColumn.maxWidth = 90
        kindColumn.resizingMask = .userResizingMask
        let permColumn = NSTableColumn(identifier: Columns.perm)
        permColumn.title = L("权限")
        permColumn.width = 96
        permColumn.minWidth = 72
        permColumn.maxWidth = 140
        permColumn.resizingMask = .userResizingMask
        let dateColumn = NSTableColumn(identifier: Columns.date)
        dateColumn.title = L("修改时间")
        dateColumn.width = 130
        dateColumn.minWidth = 110
        dateColumn.resizingMask = .userResizingMask

        table.addTableColumn(nameColumn)
        table.addTableColumn(sizeColumn)
        table.addTableColumn(kindColumn)
        table.addTableColumn(permColumn)
        table.addTableColumn(dateColumn)
        permColumn.sortDescriptorPrototype = NSSortDescriptor(key: "perm", ascending: true)
        // 列头点击排序（同列再点反向，目录恒在前）
        nameColumn.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)
        sizeColumn.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)
        dateColumn.sortDescriptorPrototype = NSSortDescriptor(key: "date", ascending: false)
        kindColumn.sortDescriptorPrototype = NSSortDescriptor(key: "kind", ascending: true)
        table.dataSource = self
        table.delegate = self
        // 拖拽上传（2026-10-24 用户指定）：Finder 拖文件到面板任意位置即上传到当前目录
        registerForDraggedTypes([.fileURL])
        // 拖出下载（2026-10-25 用户指定）：把文件拖到 Finder/桌面即下载（文件承诺机制）
        table.setDraggingSourceOperationMask([.copy], forLocal: false)
        table.rowHeight = Self.rowHeightForFont
        table.style = .inset
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        // Finder 式多选（2026-10-24 用户指定）：⇧ 点选连续区间、⌘ 点选增减，均为 NSTableView 原生行为
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.sizeLastColumnToFit()
        // macOS 26/27 原生列宽拖动失效（同 NSSplitView divider 一类问题）：自建表头接管边界拖动
        table.headerView = ResizableTableHeaderView()
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.menu = contextMenu
        contextMenu.delegate = self
        // 空格预览选中文件（Finder Quick Look 口径，2026-10-26 用户指定）
        table.onSpace = { [weak self] in self?.previewSelected() }

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // 汇总栏
        let footer = Surfaces.glass(hairline: .top)
        footer.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = NSFont.systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingMiddle
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        footer.addSubview(summaryLabel)

        // 文件区 / 脚本区：互斥容器，均铺满 header 以下
        fileContainer.translatesAutoresizingMaskIntoConstraints = false
        snippetContainer.translatesAutoresizingMaskIntoConstraints = false
        fileContainer.addSubview(pathBar)
        fileContainer.addSubview(scroll)
        fileContainer.addSubview(footer)
        snippetContainer.addSubview(snippetPanel)
        snippetContainer.isHidden = true

        addSubview(header)
        addSubview(fileContainer)
        addSubview(snippetContainer)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),

            tabFile.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            tabFile.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            tabScript.leadingAnchor.constraint(equalTo: tabFile.trailingAnchor, constant: 6),
            tabScript.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            fileContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            fileContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            fileContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            fileContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            snippetContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            snippetContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            snippetContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            snippetContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            snippetPanel.topAnchor.constraint(equalTo: snippetContainer.topAnchor),
            snippetPanel.leadingAnchor.constraint(equalTo: snippetContainer.leadingAnchor),
            snippetPanel.trailingAnchor.constraint(equalTo: snippetContainer.trailingAnchor),
            snippetPanel.bottomAnchor.constraint(equalTo: snippetContainer.bottomAnchor),

            pathBar.topAnchor.constraint(equalTo: fileContainer.topAnchor),
            pathBar.leadingAnchor.constraint(equalTo: fileContainer.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: fileContainer.trailingAnchor),
            pathBar.heightAnchor.constraint(equalToConstant: 32),

            pathBox.leadingAnchor.constraint(equalTo: pathBar.leadingAnchor, constant: 8),
            pathBox.centerYAnchor.constraint(equalTo: pathBar.centerYAnchor),
            pathBox.heightAnchor.constraint(equalToConstant: 24),
            pathBox.trailingAnchor.constraint(equalTo: searchButton.leadingAnchor, constant: -8),

            searchButton.centerYAnchor.constraint(equalTo: pathBar.centerYAnchor),
            searchButton.trailingAnchor.constraint(equalTo: pathButtons.leadingAnchor, constant: -8),

            crumbStack.leadingAnchor.constraint(equalTo: pathBox.leadingAnchor, constant: 8),
            crumbStack.centerYAnchor.constraint(equalTo: pathBox.centerYAnchor),
            crumbStack.trailingAnchor.constraint(lessThanOrEqualTo: pathBox.trailingAnchor, constant: -8),

            // 编辑态输入框整栏覆盖分段
            pathField.leadingAnchor.constraint(equalTo: pathBox.leadingAnchor, constant: 8),
            pathField.centerYAnchor.constraint(equalTo: pathBox.centerYAnchor),
            pathField.heightAnchor.constraint(equalToConstant: 20),
            pathField.trailingAnchor.constraint(equalTo: pathBox.trailingAnchor, constant: -8),

            // 搜索输入态同样覆盖分段
            searchEditField.leadingAnchor.constraint(equalTo: pathBox.leadingAnchor, constant: 8),
            searchEditField.centerYAnchor.constraint(equalTo: pathBox.centerYAnchor),
            searchEditField.heightAnchor.constraint(equalToConstant: 20),
            searchEditField.trailingAnchor.constraint(equalTo: pathBox.trailingAnchor, constant: -8),

            pathButtons.trailingAnchor.constraint(equalTo: pathBar.trailingAnchor, constant: -8),
            pathButtons.centerYAnchor.constraint(equalTo: pathBar.centerYAnchor),
            pathButtons.heightAnchor.constraint(equalToConstant: 24),

            scroll.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: fileContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: fileContainer.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: fileContainer.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: fileContainer.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: fileContainer.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 26),

            summaryLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
            summaryLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: footer.trailingAnchor, constant: -12),
        ])
    }

    // MARK: 拖拽上传（Finder → 当前面板目录）

    /// 仅在文件页签激活且 SFTP 已连接时接收；拖拽目标是整个面板（含列表/路径栏），
    /// 未注册的子视图命中时会沿视图链上溯到这里的实现
    private func canAcceptFileDrop() -> Bool {
        !fileContainer.isHidden && SFTPService.shared.connectedTo != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAcceptFileDrop() ? [.copy] : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAcceptFileDrop() ? [.copy] : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard canAcceptFileDrop(),
              let urls = sender.draggingPasteboard.readObjects(
                  forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        for url in urls {
            SFTPService.shared.upload(local: url, name: url.lastPathComponent)
        }
        return true
    }

    // MARK: 页签切换

    private enum PanelTab { case file, snippet }
    private func switchTab(_ tab: PanelTab) {
        fileTab?.setOn(tab == .file)
        snippetTab?.setOn(tab == .snippet)
        fileContainer.isHidden = tab != .file
        snippetContainer.isHidden = tab != .snippet
    }

    // MARK: 脚本主机来源（树选中优先，回退到选中会话）

    private var pickedHost: (id: UUID, label: String)?
    private var sessionHost: (id: UUID, label: String)?

    /// 会话树单击选中主机（未连接也可查看/编辑脚本）；nil = 选中了非主机节点
    func handleHostPicked(_ id: UUID?, label: String) {
        pickedHost = id.map { ($0, label) }
        refreshSnippetHost()
    }

    private func refreshSnippetHost() {
        let active = pickedHost ?? sessionHost
        snippetPanel.setHost(active?.id, label: active?.label ?? "")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        let service = SFTPService.shared
        service.onChanged = { [weak self] in self?.reloadFromService() }
        BookmarkStore.shared.observe { [weak self] in self?.updateFavoriteButton() }
        service.onStatus = { [weak self] text in
            self?.summaryLabel.stringValue = text
        }
        reloadFromService()
        // 脚本面板跟随选中会话的主机（树无手动选中时生效）
        SessionManager.shared.observeSelected { [weak self] in
            guard let self else { return }
            if let ssh = SessionManager.shared.selected as? SSHSession,
               let hostId = ssh.hostEntryId,
               let entry = HostStore.shared.hosts.first(where: { $0.id == hostId }) {
                self.pickedHost = nil // 切会话优先于树的旧选中
                self.sessionHost = (hostId, entry.label)
            } else {
                self.sessionHost = nil
            }
            self.refreshSnippetHost()
        }
    }

    // MARK: 当前目录搜索（按钮 → 输入框 → 回车筛选）

    /// 点击搜索按钮：弹出输入框（覆盖分段栏），带入当前关键字
    @objc private func searchClicked() {
        DebugLog.write("search clicked")
        searchEditField.stringValue = searchText
        searchEditField.isHidden = false
        crumbStack.isHidden = true
        needsLayout = true
        window?.makeFirstResponder(searchEditField)
        searchEditField.currentEditor()?.selectAll(nil)
    }

    /// 失焦/取消退出搜索输入，恢复分段显示（不改已生效的筛选）
    private func exitSearchEdit() {
        guard !searchEditField.isHidden else { return }
        searchEditField.isHidden = true
        crumbStack.isHidden = false
    }

    /// 回车提交筛选：空关键字恢复全部
    @objc private func searchSubmitted() {
        searchText = searchEditField.stringValue.trimmingCharacters(in: .whitespaces)
        exitSearchEdit()
        applySearchFilter()
    }

    private func applySearchFilter() {
        searchButton?.button.contentTintColor = searchText.isEmpty ? .secondaryLabelColor : .controlAccentColor
        table.reloadData()
        updateSummary()
    }

    /// 过滤关键字（空格分词，全部命中才算匹配）
    private var searchQuery: String { searchText }

    /// 表格行数据基准的缓存：viewFor 每行都会取，原实时过滤在大目录 + 搜索时是 O(n²)
    private var filteredCache: (query: String, sourceCount: Int, result: [SFTPService.Entry])?

    /// 表格行数据基准：有关键字时为名字过滤后的列表（大小写不敏感），行为排序后的 entries 子集
    private var displayEntries: [SFTPService.Entry] {
        let tokens = searchQuery.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return entries }
        if let cache = filteredCache, cache.query == searchQuery, cache.sourceCount == entries.count {
            return cache.result
        }
        let result = entries.filter { entry in tokens.allSatisfy { entry.name.lowercased().contains($0) } }
        filteredCache = (searchQuery, entries.count, result)
        return result
    }

    /// 汇总栏：过滤时显示「命中/总数」
    private func updateSummary() {
        let service = SFTPService.shared
        guard service.connectedTo != nil else {
            summaryLabel.stringValue = service.statusText
            return
        }
        let query = searchQuery
        summaryLabel.stringValue = query.isEmpty
            ? L("%ld 项 · %@", entries.count, service.path)
            : L("%ld/%ld 项匹配「%@」 · %@", displayEntries.count, entries.count, query, service.path)
    }

    func reloadFromService() {
        let service = SFTPService.shared
        entries = service.entries
        filteredCache = nil
        resortEntries()
        // 过滤只对当前目录有效：换目录即清空（同目录刷新保留）
        if service.path != lastDirectory {
            lastDirectory = service.path
            if !searchText.isEmpty {
                searchText = ""
                applySearchFilter()
            }
        }
        rebuildCrumbs()
        updateSummary()
        updateFavoriteButton()
        table.reloadData()
        // 终端链接点击跳转到文件：进入父目录后选中并滚到该文件（被隐藏文件过滤掉时静默）
        if let name = service.takePendingRevealName(),
           let row = displayEntries.firstIndex(where: { $0.name == name }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
    }

    // MARK: 面包屑（地址栏内 Finder 式路径分段）

    private func rebuildCrumbs() {
        crumbStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // 完整段：root 起 [(title, path)]
        var segments: [(title: String, path: String)] = [("/", "/")]
        var acc = ""
        for component in SFTPService.shared.path.split(separator: "/", omittingEmptySubsequences: true) {
            acc += "/" + component
            segments.append((String(component), acc))
        }
        // 右侧常驻输入框占宽，分段预算有限：超宽时从中段逐层折叠为 …，
        // … 指向最早被折叠的那层目录（Finder 式保头保尾：折到「根/…/当前」三段为止，
        // 只有连三段都放不下才退化为「根/…」——当前目录名不能先消失）
        let fontAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11)]
        func stackWidth(_ segs: [(title: String, path: String)]) -> CGFloat {
            segs.reduce(CGFloat(14 + 12 * max(segs.count - 1, 0))) {
                $0 + (($1.title as NSString).size(withAttributes: fontAttributes).width + 18)
            }
        }
        let budget = max(160, pathBox.bounds.width - 24)
        while segments.count > 3, stackWidth(segments) > budget {
            let foldedPath = segments[1].path
            segments.remove(at: 1)
            segments[1] = ("…", foldedPath)
        }
        if segments.count == 3, stackWidth(segments) > budget {
            let foldedPath = segments[1].path
            segments.remove(at: 1)
            segments[1] = ("…", foldedPath)
        }
        for (index, segment) in segments.enumerated() {
            if index > 0 { crumbStack.addArrangedSubview(crumbSeparator()) }
            crumbStack.addArrangedSubview(crumbButton(title: segment.title,
                                                       path: segment.path,
                                                       isCurrent: index == segments.count - 1))
        }
    }

    private func crumbButton(title: String, path: String, isCurrent: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(crumbClicked(_:)))
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.font = NSFont.systemFont(ofSize: 11)
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: isCurrent ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 11),
        ])
        button.identifier = NSUserInterfaceItemIdentifier(path)
        button.toolTip = path
        return button
    }

    private func crumbSeparator() -> NSTextField {
        let label = NSTextField(labelWithString: "›")
        label.font = NSFont.systemFont(ofSize: 10)
        label.textColor = .tertiaryLabelColor
        return label
    }

    @objc private func crumbClicked(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        if path == SFTPService.shared.path {
            enterPathEdit()
        } else {
            SFTPService.shared.list(path)
        }
    }

    @objc private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SFTPService.shared.path, forType: .string)
    }

    // MARK: 右键菜单新增动作（参考 WindTerm）

    /// 目录「打开」= 进入
    @objc private func openClicked() {
        guard let entry = clickedEntry(), entry.isDir else { return }
        SFTPService.shared.list(SFTPService.shared.path + entry.name + "/")
    }

    /// 复制目录路径（当前浏览目录）
    @objc private func copyDirPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SFTPService.shared.path, forType: .string)
    }

    /// 引用后的 shell 单引号包裹
    private func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 把文本作为输入发到当前选中的终端（名称/路径粘贴场景）
    private func sendToTerminal(_ text: String) {
        sendRawToTerminal(shellQuoted(text))
    }

    /// 原样注入（调用方自行负责引用），多选逐项引用后拼空格时用
    private func sendRawToTerminal(_ text: String) {
        guard let session = SessionManager.shared.selected else { return }
        session.injectInput(Array((text + " ").utf8))
    }

    /// 在终端打开当前目录（Termind「同一路径切换 SSH」反向联动）：
    /// 用户主动触发才注入 cd（不违反「不自动注入」口径）；SSH 会话的
    /// injectInput 内部已按主机字符集转码（GBK 下中文路径不乱码）
    @objc private func cdHereInTerminal() {
        let path = SFTPService.shared.path
        guard path.hasPrefix("/") else { return }
        sendRawToTerminal("cd \(shellQuoted(path))\r")
    }

    @objc private func copyDirPathToTerminal() { sendToTerminal(SFTPService.shared.path) }
    @objc private func copyName() {
        let names = selectedEntries.map(\.name)
        guard !names.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
    }
    @objc private func copyEntryPath() {
        let paths = selectedEntries.map { SFTPService.shared.path + $0.name }
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }
    @objc private func copyNameToTerminal() {
        let names = selectedEntries.map { shellQuoted($0.name) }
        guard !names.isEmpty else { return }
        sendRawToTerminal(names.joined(separator: " "))
    }
    @objc private func copyPathToTerminal() {
        let paths = selectedEntries.map { shellQuoted(SFTPService.shared.path + $0.name) }
        guard !paths.isEmpty else { return }
        sendRawToTerminal(paths.joined(separator: " "))
    }

    /// 移动到…：输入目标目录，不覆盖同名；多选逐项移动
    @objc private func moveToClicked() {
        let targets = selectedEntries
        guard !targets.isEmpty else { return }
        promptText(title: L("移动到…"), placeholder: L("目标目录（默认当前目录）")) { [weak self] target in
            let dir = target?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !dir.isEmpty else { return }
            for entry in targets {
                SFTPService.shared.move(entry: entry, toDirectory: dir) { ok in
                    if !ok, let self {
                        self.summaryLabel.stringValue = L("移动失败：目标目录不存在或已有同名条目（%@）", entry.name)
                    }
                }
            }
        }
    }

    /// 属性…：条目或当前目录
    @objc private func propertiesClicked() {
        if let entry = clickedEntry() {
            showProperties(path: SFTPService.shared.path + entry.name, name: entry.name)
        } else {
            showProperties(path: SFTPService.shared.path,
                           name: SFTPService.shared.path.hasSuffix("/")
                               ? String(SFTPService.shared.path.dropLast().split(separator: "/").last ?? "/")
                               : SFTPService.shared.path)
        }
    }

    private func showProperties(path: String, name: String) {
        SFTPService.shared.stat(fullPath: path) { [weak self] stat, owner, group in
            guard let self else { return }
            guard let stat else {
                self.summaryLabel.stringValue = L("读取属性失败：%@", path)
                return
            }
            let accessory = FilePropertiesView(stat: stat, name: name,
                                               location: SFTPService.shared.path,
                                               owner: owner, group: group)
            let response = PicotermDialog.run(title: L("属性"), content: accessory,
                                              primaryTitle: L("确定"), contentWidth: 500,
                                              parent: window)
            if response == .OK,
               let octal = accessory.changedOctal() {
                SFTPService.shared.chmod(fullPath: path, octal: octal) { [weak self] ok in
                    if !ok { self?.summaryLabel.stringValue = L("修改权限失败：%@", path) }
                }
            }
        }
    }

    /// 「…」下拉：新建文件 / 新建文件夹 / 输入路径跳转（弹在按钮正下方）
    @objc private func moreClicked() {
        DebugLog.write("more clicked")
        guard let button = moreButton?.button else { return }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L("新建文件"), action: #selector(newFile), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L("新建文件夹"), action: #selector(newFolder), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("输入路径跳转…"), action: #selector(editPath), keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    // MARK: 目录收藏（2026-10-26 用户指定：按主机保存，可收藏多个目录）

    /// 当前连接的收藏键（未连接为 nil）
    private var bookmarkIdentity: String? { SFTPService.shared.connectedTo }

    /// 当前目录（规范形态，无尾斜杠）
    private var currentDirectory: String { BookmarkStore.normalize(SFTPService.shared.path) }

    /// 收藏项显示名：home 下的路径缩成 ~
    private func bookmarkTitle(_ path: String) -> String {
        if let home = SFTPService.shared.homePath.map(BookmarkStore.normalize) {
            if path == home { return "~" }
            if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        }
        return path
    }

    /// 星形按钮：当前目录已收藏实心、未收藏空心；未连接时禁用
    private func updateFavoriteButton() {
        guard let favoriteButton else { return }
        let connected = bookmarkIdentity != nil
        let marked = bookmarkIdentity.map { BookmarkStore.shared.isBookmarked(currentDirectory, for: $0) } ?? false
        favoriteButton.button.isEnabled = connected
        favoriteButton.alphaValue = connected ? 1 : 0.4
        favoriteButton.button.image = NSImage(systemSymbolName: marked ? "star.fill" : "star",
                                              accessibilityDescription: L("收藏目录"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        favoriteButton.button.contentTintColor = marked ? .systemYellow : .secondaryLabelColor
    }

    /// 星形按钮下拉：收藏列表（点击跳转）/ 收藏或取消收藏当前目录 / 移除收藏子菜单
    @objc private func favoriteClicked() {
        guard let button = favoriteButton?.button, let identity = bookmarkIdentity else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let list = BookmarkStore.shared.bookmarks(for: identity)
        if list.isEmpty {
            let empty = NSMenuItem(title: L("暂无收藏目录"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for path in list {
                let item = NSMenuItem(title: bookmarkTitle(path), action: #selector(jumpToBookmark(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = path
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                item.state = path == currentDirectory ? .on : .off
                item.toolTip = path
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let marked = BookmarkStore.shared.isBookmarked(currentDirectory, for: identity)
        let toggle = NSMenuItem(title: marked ? L("取消收藏当前目录") : L("收藏当前目录"),
                                action: #selector(toggleBookmarkCurrent), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        if !list.isEmpty {
            let removeItem = NSMenuItem(title: L("移除收藏"), action: nil, keyEquivalent: "")
            let removeMenu = NSMenu()
            removeMenu.autoenablesItems = false
            for path in list {
                let item = NSMenuItem(title: bookmarkTitle(path), action: #selector(removeBookmark(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = path
                removeMenu.addItem(item)
            }
            removeItem.submenu = removeMenu
            menu.addItem(removeItem)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func jumpToBookmark(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        SFTPService.shared.list(path)
    }

    @objc private func removeBookmark(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, let identity = bookmarkIdentity else { return }
        BookmarkStore.shared.remove(path, for: identity)
    }

    @objc private func toggleBookmarkCurrent() {
        guard let identity = bookmarkIdentity else { return }
        BookmarkStore.shared.toggle(currentDirectory, for: identity)
    }

    /// 右键目录条目：收藏 / 取消收藏该目录
    @objc private func toggleBookmarkEntry() {
        guard let identity = bookmarkIdentity, let entry = clickedEntry(), entry.isDir else { return }
        BookmarkStore.shared.toggle(SFTPService.shared.path + entry.name, for: identity)
    }

    @objc private func editPath() {
        // 菜单项触发时正处于菜单收尾的响应链里，同步 makeFirstResponder 会被吞；
        // 跳一拍进入编辑态（TODO 80「点击无反应」根因）
        MainThread.perform { [weak self] in self?.enterPathEdit() }
    }

    // MARK: 路径输入（… 按钮或点空白进入；回车跳转 / Esc 或失焦退出）

    private func enterPathEdit() {
        DebugLog.write("enterPathEdit connected=\(SFTPService.shared.connectedTo != nil) hidden=\(pathField.isHidden)")
        pathField.stringValue = SFTPService.shared.connectedTo != nil ? SFTPService.shared.path : "/"
        pathField.isHidden = false
        crumbStack.isHidden = true
        needsLayout = true
        let became = window?.makeFirstResponder(pathField) ?? false
        DebugLog.write("enterPathEdit makeFirstResponder=\(became) frame=\(pathField.frame)")
        // 不能用 selectText(nil)：它会先结束编辑再全选，结束通知立刻把输入框收回去
        // （所有「切换进入编辑态」版本点了没反应的真因）；经字段编辑器全选不触发结束
        pathField.currentEditor()?.selectAll(nil)
    }

    private func exitPathEdit(reason: String = #function) {
        guard !pathField.isHidden else { return }
        DebugLog.write("exitPathEdit reason=\(reason) firstResponder=\(String(describing: type(of: window?.firstResponder)))")
        pathField.isHidden = true
        crumbStack.isHidden = false
    }

    @objc private func pathSubmitted() {
        guard SFTPService.shared.connectedTo != nil else { return }
        var target = pathField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        if !target.hasSuffix("/") { target += "/" }
        SFTPService.shared.list(target)
        exitPathEdit()
    }

    /// 当前多选集（行号即展示列表下标）；空选时回退到点击行，与 Finder 右键口径一致
    private var selectedEntries: [SFTPService.Entry] {
        var indexes = table.selectedRowIndexes
        if indexes.isEmpty, table.clickedRow >= 0 { indexes.insert(table.clickedRow) }
        return indexes.compactMap { displayEntries[safe: $0] }
    }

    // MARK: 右键菜单（参考 WindTerm）

    private func clickedEntry() -> SFTPService.Entry? {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < displayEntries.count else { return nil }
        return displayEntries[row]
    }

    @objc private func openInEditor() {
        guard let entry = clickedEntry(), !entry.isDir else { return }
        SFTPService.shared.openInLocalEditor(entry: entry)
    }

    /// 预览：文本弹窗显示头部内容 / 图片弹窗显示（Termind「预览」口径，不落编辑器）；
    /// 不支持的情况弹信息框提示，不写进文件面板状态栏（2026-10-26 用户指定）
    @objc private func previewClicked() {
        guard let entry = clickedEntry() else { return }
        preview(entry)
    }

    /// 空格：预览当前选中行（多选取首个）
    private func previewSelected() {
        let row = table.selectedRow
        guard row >= 0, row < displayEntries.count else { return }
        preview(displayEntries[row])
    }

    private func preview(_ entry: SFTPService.Entry) {
        guard !entry.isDir else {
            PicotermDialog.info(title: L("无法预览"), L("「%@」是目录，双击进入查看。", entry.name), parent: window)
            return
        }
        SFTPService.shared.preview(entry: entry) { [weak self] payload in
            guard let self else { return }
            switch payload {
            case .text(let preview):
                self.showTextPreview(name: entry.name, preview: preview)
            case .image(let data):
                self.showImagePreview(name: entry.name, data: data)
            case .tooLarge:
                PicotermDialog.info(title: L("无法预览"),
                                    L("「%@」超过图片预览上限（8MB），请下载后查看。", entry.name),
                                    parent: self.window)
            case nil:
                PicotermDialog.info(title: L("无法预览"),
                                    L("「%@」不是文本或图片（二进制文件），或读取失败。", entry.name),
                                    parent: self.window)
            }
        }
    }

    /// 文本预览：≤512KB 全文；更大为前 256KB + 省略标记（次要色居中）+ 后 256KB
    private func showTextPreview(name: String, preview: TextPreviewAssembler.Result) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
        textView.isEditable = false
        textView.isRichText = false
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        let attributed = NSMutableAttributedString(string: preview.text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ])
        if let range = preview.markerRange {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.paragraphSpacingBefore = 6
            paragraph.paragraphSpacing = 6
            attributed.addAttributes([
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ], range: NSRange(range, in: preview.text))
        }
        textView.textStorage?.setAttributedString(attributed)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 580).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 380).isActive = true
        let title = preview.omittedBytes > 0 ? L("预览（前 256KB + 后 256KB）· %@", name) : L("预览 · %@", name)
        PicotermDialog.run(title: title,
                           content: scroll, primaryTitle: L("关闭"), cancelTitle: nil,
                           contentWidth: 580, parent: window)
    }

    private func showImagePreview(name: String, data: Data) {
        guard let image = NSImage(data: data) else {
            PicotermDialog.info(title: L("无法预览"), L("「%@」图片解码失败，文件可能已损坏或格式不受支持。", name), parent: window)
            return
        }
        let icon = NSImageView(image: image)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let side = min(max(image.size.width, 160), 640)
        let height = min(max(image.size.height, 120), 480)
        icon.widthAnchor.constraint(lessThanOrEqualToConstant: side).isActive = true
        icon.heightAnchor.constraint(lessThanOrEqualToConstant: height).isActive = true
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentHuggingPriority(.required, for: .vertical)
        PicotermDialog.run(title: L("预览 · %@（%ld×%ld）", name, Int(image.size.width), Int(image.size.height)),
                           content: icon, primaryTitle: L("关闭"), cancelTitle: nil,
                           contentWidth: min(side + 40, 680), parent: window)
    }

    @objc private func downloadClicked() {
        let targets = selectedEntries
        guard let first = targets.first else { return }
        guard targets.count > 1 else {
            download(first)
            return
        }
        // 多选下载：选目标文件夹，全部下到里面（逐项弹保存面板太繁琐）
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = L("选择保存 %ld 个文件的目标文件夹", targets.count)
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        for entry in targets where !entry.isDir {
            SFTPService.shared.download(entry: entry, to: dir.appendingPathComponent(entry.name))
        }
    }

    @objc private func compressClicked() {
        let targets = selectedEntries
        guard let first = targets.first else { return }
        let base: String
        if targets.count == 1 {
            base = first.name.hasSuffix("/") ? String(first.name.dropLast()) : first.name
        } else {
            base = "archive"
        }
        SFTPService.shared.compress(entries: targets, archiveName: "\(base).tar.gz")
    }

    @objc private func renameClicked() {
        guard let entry = clickedEntry() else { return }
        // 输入框带全「文件名+后缀」（2026-10-24 用户指定），光标在尾部可直接改
        promptText(title: L("重命名"), placeholder: L("新名称"), initial: entry.name) { name in
            guard let name = name?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty, name != entry.name else { return }
            SFTPService.shared.rename(entry: entry, to: name)
        }
    }

    @objc private func deleteClicked() {
        let targets = selectedEntries
        guard let first = targets.first else { return }
        let text: String
        if targets.count == 1 {
            text = first.isDir
                ? L("确定递归删除目录「%@」及其全部内容？", first.name)
                : L("确定删除「%@」？", first.name)
        } else {
            text = L("确定删除选中的 %ld 项？（目录将递归删除其全部内容）", targets.count)
        }
        let response = PicotermDialog.run(title: L("删除"), content: PicotermDialog.message(text),
                                          primaryTitle: L("删除"), destructive: true, parent: window)
        guard response == .OK else { return }
        for entry in targets {
            SFTPService.shared.remove(entry: entry)
        }
    }

    @objc private func newFile() {
        promptText(title: L("新建文件"), placeholder: L("文件名")) { name in
            guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            SFTPService.shared.createFile(named: name.trimmingCharacters(in: .whitespaces))
        }
    }

    @objc private func newFolder() {
        promptText(title: L("新建文件夹"), placeholder: L("名称")) { name in
            guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            SFTPService.shared.makeDirectory(named: name.trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: 动作

    @objc private func goUp() {
        var path = SFTPService.shared.path
        if path.count > 1 { path = String(path.dropLast()) }
        if let slash = path.lastIndex(of: "/") {
            path = String(path[...slash])
        }
        SFTPService.shared.list(path)
    }

    @objc private func refreshList() {
        SFTPService.shared.refresh()
    }

    @objc private func rowDoubleClicked() {
        guard let entry = clickedEntry() else { return }
        if entry.isDir {
            SFTPService.shared.list(SFTPService.shared.path + entry.name + "/")
        } else {
            download(entry)
        }
    }

    /// 下载：保存面板（默认目录 ~/Downloads，TODO 63 调整——61 的免面板直下取消）
    private func download(_ entry: SFTPService.Entry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SFTPService.shared.download(entry: entry, to: url)
    }

    @objc private func uploadFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SFTPService.shared.upload(local: url, name: url.lastPathComponent)
    }

    private func promptText(title: String, placeholder: String, initial: String = "",
                            completion: @escaping (String?) -> Void) {
        let input = NSTextField(string: initial)
        input.placeholderString = placeholder
        let response = PicotermDialog.run(title: title, content: input, primaryTitle: L("确定"),
                                          parent: window)
        completion(response == .OK ? input.stringValue : nil)
    }
}

// 路径输入框与搜索输入框共用一份 delegate（NSSearchFieldDelegate 继承 NSTextFieldDelegate）
extension FilePanelView: NSTextFieldDelegate {
    // 失焦（回车提交后 / 点击别处）退出对应输入态，恢复分段显示
    func controlTextDidEndEditing(_ obj: Notification) {
        // 跳一拍再判：若字段仍在编辑（内部操作引发的假结束）则忽略，真正失焦才退出
        MainThread.perform { [weak self] in
            guard let self else { return }
            if self.pathField.currentEditor() == nil {
                self.exitPathEdit(reason: "endEditing")
            }
            if !self.searchEditField.isHidden, self.searchEditField.currentEditor() == nil {
                self.exitSearchEdit()
            }
        }
    }
}

extension FilePanelView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if let entry = clickedEntry() {
            if entry.isDir {
                add(L("打开"), #selector(openClicked))
                if let identity = bookmarkIdentity {
                    let marked = BookmarkStore.shared.isBookmarked(SFTPService.shared.path + entry.name, for: identity)
                    add(marked ? L("取消收藏此目录") : L("收藏此目录"), #selector(toggleBookmarkEntry))
                }
            } else {
                add(L("预览"), #selector(previewClicked))
                add(L("用默认编辑器打开"), #selector(openInEditor))
            }
            menu.addItem(.separator())
            add(L("删除"), #selector(deleteClicked))
            add(L("重命名…"), #selector(renameClicked))
            add(L("移动到…"), #selector(moveToClicked))
            if !entry.isDir {
                menu.addItem(.separator())
                add(L("下载…"), #selector(downloadClicked))
            }
            add(L("压缩为 .tar.gz"), #selector(compressClicked))
            menu.addItem(.separator())
            add(L("上传到当前文件夹…"), #selector(uploadFile))
            menu.addItem(.separator())
            add(L("复制目录路径"), #selector(copyDirPath))
            add(L("将目录路径复制到终端"), #selector(copyDirPathToTerminal))
            add(L("在终端打开此目录"), #selector(cdHereInTerminal))
            menu.addItem(.separator())
            add(L("复制名称"), #selector(copyName))
            add(L("复制路径"), #selector(copyEntryPath))
            add(L("复制名称到终端"), #selector(copyNameToTerminal))
            add(L("复制路径到终端"), #selector(copyPathToTerminal))
            menu.addItem(.separator())
            add(L("属性…"), #selector(propertiesClicked))
        } else {
            add(L("新建文件"), #selector(newFile))
            add(L("新建文件夹"), #selector(newFolder))
            add(L("上传到当前文件夹…"), #selector(uploadFile))
            menu.addItem(.separator())
            if let identity = bookmarkIdentity {
                let marked = BookmarkStore.shared.isBookmarked(currentDirectory, for: identity)
                add(marked ? L("取消收藏当前目录") : L("收藏当前目录"), #selector(toggleBookmarkCurrent))
            }
            add(L("在终端打开此目录"), #selector(cdHereInTerminal))
            add(L("复制目录路径"), #selector(copyDirPath))
            add(L("将目录路径复制到终端"), #selector(copyDirPathToTerminal))
            add(L("刷新"), #selector(refreshList))
            menu.addItem(.separator())
            add(L("属性…（当前目录）"), #selector(propertiesClicked))
        }
    }
}

extension FilePanelView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { displayEntries.count }

    // MARK: 拖出下载（文件承诺：拖到 Finder 后按目标路径异步下载，进度走传输条）
    // NSFilePromiseProvider 对 delegate 弱引用——委托对象用关联对象挂在
    // provider 上，随 AppKit 持有的 provider 存活到拖拽结束

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let entry = displayEntries[safe: row], !entry.isDir,
              let delegate = SFTPService.shared.promiseDelegate(for: entry) else { return nil }
        delegate.onStatus = { [weak self] text in
            self?.summaryLabel.stringValue = text
        }
        let provider = delegate.makeProvider()
        objc_setAssociatedObject(provider, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        return provider
    }
}

extension FilePanelView: NSTableViewDelegate {
    /// 列头点击排序：正序→再点倒序；目录恒在文件前，同组内按所选键比较
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        resortEntries()
        table.reloadData()
    }

    private func resortEntries() {
        guard let descriptor = table.sortDescriptors.first, let key = descriptor.key else { return }
        let ascending = descriptor.ascending
        func ext(_ name: String) -> String { (name as NSString).pathExtension.lowercased() }
        entries.sort { a, b in
            if a.isDir != b.isDir { return a.isDir } // 目录恒在前
            let result: Bool
            switch key {
            case "size": result = a.size < b.size
            case "date": result = a.mtime < b.mtime
            case "kind": result = ext(a.name) < ext(b.name)
            case "perm": result = (a.permText + "/" + a.owner) < (b.permText + "/" + b.owner)
            default: result = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            return ascending ? result : !result
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let entry = displayEntries[safe: row], let column = tableColumn else { return nil }
        let kind: FileCellView.Kind
        switch column.identifier {
        case Columns.size: kind = .size
        case Columns.date: kind = .date
        case Columns.kind: kind = .kind
        case Columns.perm: kind = .perm
        default: kind = .name
        }
        let identifier = NSUserInterfaceItemIdentifier("sftpCell:" + column.identifier.rawValue)
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? FileCellView) ?? FileCellView(kind: kind)
        cell.identifier = identifier
        cell.configure(entry: entry, column: column.identifier)
        return cell
    }

    /// Finder 式行样式：隔行圆角色带 + 圆角选中带
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        FinderRowView(row: row)
    }
}

/// 文件列表：空格键预览选中项（Finder Quick Look 口径，2026-10-26 用户指定）；
/// 其余按键走 NSTableView 原生（↑↓ 移动、字母跳转）
final class FileTableView: NSTableView {
    var onSpace: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, // Space
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           let onSpace {
            onSpace()
            return
        }
        super.keyDown(with: event)
    }
}

/// Finder 列表视图行样式（2026-10-24 用户指定参考截图）：偶数行透出、奇数行浅色圆角带；
/// 选中用中性灰圆角带——单元格文字是固定 labelColor，原生蓝色高亮下会看不清。
/// 行号由构造传入（macOS 27 SDK 的 NSTableRowView 不再暴露 row 属性）
final class FinderRowView: NSTableRowView {
    private let rowIndex: Int

    init(row: Int) {
        rowIndex = row
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var band: NSRect {
        bounds.insetBy(dx: 4, dy: 1)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard rowIndex >= 0, rowIndex % 2 == 1, !isSelected else { return } // 选中行只画选中带
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        NSBezierPath(roundedRect: band, xRadius: 6, yRadius: 6).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(isEmphasized ? 0.14 : 0.09).setFill()
        NSBezierPath(roundedRect: band, xRadius: 6, yRadius: 6).fill()
    }
}

// 文件表单元格
final class FileCellView: NSView {
    enum Kind { case name, size, date, kind, perm }

    /// 属性字符串默认按词换行——所有列统一挂截断段落样式保证单行
    static let truncatingParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    let kind: Kind
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.font = NSFont.systemFont(ofSize: 12)
        label.cell?.wraps = false
        if kind == .size { label.alignment = .right } // Finder 式大小列右对齐
        addSubview(icon)
        addSubview(label)
        // 名称列 label 跟在图标后；其余列（图标隐藏）直接左对齐顶格，去掉左侧空白
        let leadingToIcon = label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5)
        let leadingDirect = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        leadingToIcon.isActive = (kind == .name)
        leadingDirect.isActive = (kind != .name)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension FileCellView {
    /// 字号跟随设置：名称列=字号，权限列 -1，大小/时间/类型 -2（默认 13 → 13/12/11）
    private static var baseSize: CGFloat { CGFloat(AppSettings.shared.fileListFontSize) }

    func configure(entry: SFTPService.Entry, column: NSUserInterfaceItemIdentifier) {
        let isName = (kind == .name)
        icon.isHidden = !isName
        if kind == .perm {
            label.attributedStringValue = NSAttributedString(
                string: "\(entry.permText)/\(entry.owner)",
                attributes: [.foregroundColor: NSColor.labelColor,
                             .font: NSFont.monospacedDigitSystemFont(ofSize: Self.baseSize - 1, weight: .regular)])
            return
        }
        if isName {
            icon.image = FileIcons.image(name: entry.name, isDir: entry.isDir, size: 16)
            icon.imageScaling = .scaleProportionallyDown
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            label.attributedStringValue = NSAttributedString(
                string: entry.name,
                attributes: [
                    .foregroundColor: NSColor.labelColor,
                    .font: NSFont.systemFont(ofSize: Self.baseSize),
                    .paragraphStyle: paragraph,
                ])
        } else if kind == .size {
            // 大小列：目录不显示字节大小（与时间/类型列同款截断段落样式，保证不换行）
            label.attributedStringValue = NSAttributedString(
                string: entry.isDir ? "—" : ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file),
                attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: Self.baseSize - 2, weight: .regular),
                    .paragraphStyle: Self.truncatingParagraph,
                ])
        } else if kind == .date {
            // Finder 式相对日期：今天/昨天 + 其余完整日期
            let date = Date(timeIntervalSince1970: TimeInterval(entry.mtime))
            label.attributedStringValue = NSAttributedString(
                string: entry.mtime > 0 ? Self.relativeDateFormatter.string(from: date) : "",
                attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: Self.baseSize - 2, weight: .regular),
                    .paragraphStyle: Self.truncatingParagraph,
                ])
        } else {
            // 类型列：系统本地化种类名（GZip 归档/PNG 图像…），认不出回退后缀（目录=文件夹）
            let ext = (entry.name as NSString).pathExtension
            let text: String
            if entry.isDir {
                text = L("文件夹")
            } else if ext.isEmpty {
                text = "—"
            } else {
                text = UTType(filenameExtension: ext)?.localizedDescription ?? ext
            }
            label.attributedStringValue = NSAttributedString(
                string: text,
                attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.systemFont(ofSize: Self.baseSize - 2),
                    .paragraphStyle: Self.truncatingParagraph,
                ])
        }
    }

    /// 相对日期（静态实例：DateFormatter 创建开销大，且 doesRelativeDateFormatting 按当前时刻解析）
    private static let relativeDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

// 地址栏容器：点击空白处（非路径分段）进入编辑模式
final class PathBoxView: NSView {
    var onClicked: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClicked?()
    }
}

// 分段栈：AppKit 鼠标事件不冒泡，NSStackView 会把空白处的点击整块吞掉，
// 导致「点空白进编辑」只剩地址框边缘几像素可点（TODO 76）。这里只让分段按钮
// 参与命中，空白与分隔符位置透传给底下的 PathBoxView（点击即切换为路径输入框）
final class CrumbStackView: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let view = super.hitTest(point) else { return nil }
        return view is NSButton ? view : nil
    }
}

// 可拖动列宽的表头：macOS 26/27 上 NSTableView 原生列边界拖动失效
// （同 NSSplitView divider 失效一类问题），这里自算边界命中并自跑拖动循环；
// 非边界点击走 super（列头排序/选中不受影响）。
// 表头底色 = 原生毛玻璃材质（.headerView + withinWindow）：模糊透出下方滚动内容、
// 颜色与面板玻璃同源（2026-10-24 用户指定：实色铺底颜色不统一且毫无透明感）；
// 列标题/排序指示/发丝线画在玻璃上层的 HeaderContentView，两层命中测试全部
// 穿透给表头本体（列排序、列宽拖动都在表头上处理）
final class ResizableTableHeaderView: NSTableHeaderView {
    private let titleLayer = HeaderContentView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        let backdrop = PassThroughVisualEffectView()
        // 与 RootView 整窗毛玻璃完全同款（材质+混合模式都一致）→ 色调必然统一；
        // behindWindow 不含窗口内容模糊，滚动行滑到列头下会被盖住（标准表格行为）
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        titleLayer.onDraw = { [weak self] rect in self?.drawHeaderContent(rect) }
        titleLayer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLayer)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLayer.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLayer.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLayer.topAnchor.constraint(equalTo: topAnchor),
            titleLayer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {} // 背景与列标题都由子视图承担

    /// 排序指示等会标记表头重绘——镜像到真正画字的 titleLayer
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        titleLayer.needsDisplay = true
    }

    private func drawHeaderContent(_ dirtyRect: NSRect) {
        guard let table = tableView else { return }
        let sortedKey = table.sortDescriptors.first?.key
        let ascending = table.sortDescriptors.first?.ascending ?? true
        // 列头文字完全手绘（2026-10-24 用户指定：居中 + 加大一号 + 粗体深色）——
        // headerCell.drawInterior 的字号/竖直定位/字重都不可控。13pt bold、labelColor、
        // 垂直数学居中、按列矩形裁剪
        let font = NSFont.systemFont(ofSize: 13, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        for index in 0..<table.numberOfColumns {
            let column = table.tableColumns[index]
            // macOS 27 SDK 无 columnRect(withIdentifier:)：用 table.rect(ofColumn:) 取 x，
            // y/高度换成表头自身 bounds（列矩形是表坐标、直接用会把标题画到表头外）
            let columnRect = table.rect(ofColumn: index)
            let rect = NSRect(x: columnRect.minX, y: 0, width: columnRect.width, height: bounds.height)
            guard rect.intersects(dirtyRect) else { continue }

            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            let title = column.title as NSString
            let textSize = title.size(withAttributes: attributes)
            title.draw(
                in: NSRect(x: rect.minX + 4,
                           y: (bounds.height - textSize.height) / 2,
                           width: min(rect.width - 8, ceil(textSize.width) + 2),
                           height: ceil(textSize.height)),
                withAttributes: attributes)
            // 排序指示：当前排序列右缘画小箭头
            if let key = column.sortDescriptorPrototype?.key, key == sortedKey {
                let symbolName = ascending ? "chevron.up" : "chevron.down"
                if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: L("排序"))?
                    .withSymbolConfiguration(.init(pointSize: 9, weight: .medium)) {
                    let side: CGFloat = 11
                    image.draw(in: NSRect(x: rect.maxX - side - 6,
                                          y: (bounds.height - side) / 2,
                                          width: side, height: side),
                               from: .zero, operation: .sourceOver, fraction: 1,
                               respectFlipped: true, hints: nil)
                }
            }
            NSGraphicsContext.current?.restoreGraphicsState()

            if rect.maxX < bounds.maxX - 2 {
                NSColor.separatorColor.setStroke()
                NSBezierPath(rect: NSRect(x: rect.maxX - 0.5, y: 6,
                                          width: 0.5, height: bounds.height - 12)).stroke()
            }
        }
        // 底部发丝线（与列表区分隔）；titleLayer 是 flipped 坐标，底边 = maxY
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    private func resizeBoundary(at point: NSPoint) -> (column: Int, maxX: CGFloat)? {
        guard let table = tableView else { return nil }
        for index in 0..<table.numberOfColumns {
            let rect = table.rect(ofColumn: index)
            if abs(point.x - rect.maxX) <= 4, rect.maxX < bounds.maxX - 2 {
                return (index, rect.maxX)
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let startPoint = convert(event.locationInWindow, from: nil)
        guard let (column, _) = resizeBoundary(at: startPoint), let table = tableView else {
            super.mouseDown(with: event)
            return
        }
        let originalWidth = table.tableColumns[column].width
        let minWidth = table.tableColumns[column].minWidth
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let point = convert(next.locationInWindow, from: nil)
            let newWidth = max(minWidth, originalWidth + point.x - startPoint.x)
            if table.tableColumns[column].width != newWidth {
                table.tableColumns[column].width = newWidth
                table.needsLayout = true
            }
        }
    }

    override func resetCursorRects() {
        guard let window else { return }
        let mouse = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if resizeBoundary(at: mouse) != nil {
            addCursorRect(visibleRect, cursor: .resizeLeftRight)
        } else {
            super.resetCursorRects()
        }
    }
}

// 表头玻璃背景：命中测试穿透（点击/拖动都交给表头本体）
final class PassThroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// 表头列标题绘制层：画字交给表头的 drawHeaderContent，命中测试穿透。
// flipped 与 NSTableHeaderView 一致——headerCell.drawInterior 按 flipped 坐标
// 竖直居中绘制，非 flipped 层会把文字顶到上沿
final class HeaderContentView: NSView {
    var onDraw: ((NSRect) -> Void)?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        onDraw?(dirtyRect)
    }
}

// 地址栏输入框：Esc 退出编辑（不跳转）
final class PathEditField: NSTextField {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}


// MARK: - 文件/目录属性弹窗（参考 WindTerm 属性框；权限勾选 ↔ 八进制双向同步，OK 提交 chmod）

private final class FilePropertiesView: NSView {
    private var mode: UInt32 = 0
    private let initialOctal: String
    private var boxes: [[NSButton]] = []   // 3 行 × R/W/X
    private var special: [NSButton] = []   // setUID / setGID / 粘性
    private let octalField = NSTextField(string: "")

    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter
    }()

    init(stat: SSHClient.SFTPStat, name: String, location: String, owner: String, group: String) {
        mode = stat.permissions & 0o7777
        initialOctal = String(format: "%04o", mode)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 460).isActive = true

        let typeText: String
        switch stat.permissions & 0o170000 {
        case 0o040000: typeText = "文件夹"
        case 0o120000: typeText = "符号链接"
        case 0o100000: typeText = "文件"
        default: typeText = "特别的"
        }
        let icon = NSImageView(image: FileIcons.image(name: name, isDir: typeText == "文件夹", size: 64))
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        func infoRow(_ key: String, _ value: String) -> NSView {
            let keyLabel = NSTextField(labelWithString: key)
            keyLabel.font = .systemFont(ofSize: 12)
            keyLabel.textColor = .secondaryLabelColor
            keyLabel.translatesAutoresizingMaskIntoConstraints = false
            let valueLabel = NSTextField(labelWithString: value)
            valueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            valueLabel.lineBreakMode = .byTruncatingMiddle
            valueLabel.translatesAutoresizingMaskIntoConstraints = false
            let row = NSStackView(views: [keyLabel, valueLabel])
            row.orientation = .horizontal
            row.translatesAutoresizingMaskIntoConstraints = false
            keyLabel.widthAnchor.constraint(equalToConstant: 92).isActive = true
            return row
        }

        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(stat.size), countStyle: .file)
        let infoStack = NSStackView(views: [
            infoRow(L("类型："), L(typeText)),
            infoRow(L("位置："), location),
            infoRow(L("大小："), sizeText),
            infoRow(L("修改时间："), Self.dateFormat.string(from: Date(timeIntervalSince1970: TimeInterval(stat.mtime)))),
            infoRow(L("最后访问时间："), Self.dateFormat.string(from: Date(timeIntervalSince1970: TimeInterval(stat.atime)))),
            infoRow(L("所有者："), owner.isEmpty ? "[\(stat.uid)]" : "\(owner) [\(stat.uid)]"),
            infoRow(L("分组："), group.isEmpty ? "[\(stat.gid)]" : "\(group) [\(stat.gid)]"),
        ])
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 5
        infoStack.translatesAutoresizingMaskIntoConstraints = false

        // 权限网格：行 = 用户/分组/其他，列 = R W X + 特殊位
        let rowNames = [L("用户"), L("分组"), L("其他")]
        let specialNames = ["UID", "GID", L("粘性(S)")]
        boxes = []
        let permStack = NSStackView(views: [NSTextField(labelWithString: L("权限："))])
        permStack.orientation = .vertical
        permStack.alignment = .leading
        permStack.spacing = 4
        permStack.translatesAutoresizingMaskIntoConstraints = false
        for row in 0..<3 {
            let line = NSStackView()
            line.orientation = .horizontal
            line.spacing = 10
            line.translatesAutoresizingMaskIntoConstraints = false
            let rowLabel = NSTextField(labelWithString: rowNames[row])
            rowLabel.font = .systemFont(ofSize: 12)
            rowLabel.translatesAutoresizingMaskIntoConstraints = false
            rowLabel.widthAnchor.constraint(equalToConstant: 92).isActive = true
            line.addArrangedSubview(rowLabel)
            var lineBoxes: [NSButton] = []
            for col in 0..<3 {
                // 位掩码：用户 rwx = 0o400/0o200/0o100，分组/其他依次右移 3 位；
                // 特殊位：UID=0o4000、GID=0o2000、粘性=0o1000
                let mask: UInt32 = UInt32(0o400) >> (row * 3 + col)
                let box = NSButton(checkboxWithTitle: ["R", "W", "X"][col], target: self, action: #selector(boxesChanged))
                box.state = (mode & mask) != 0 ? .on : .off
                box.font = .systemFont(ofSize: 12)
                box.translatesAutoresizingMaskIntoConstraints = false
                line.addArrangedSubview(box)
                lineBoxes.append(box)
            }
            let specialBox = NSButton(checkboxWithTitle: specialNames[row], target: self, action: #selector(boxesChanged))
            let specialMask: UInt32 = UInt32(0o4000) >> row
            specialBox.state = (mode & specialMask) != 0 ? .on : .off
            specialBox.font = .systemFont(ofSize: 12)
            specialBox.translatesAutoresizingMaskIntoConstraints = false
            line.addArrangedSubview(specialBox)
            special.append(specialBox)
            boxes.append(lineBoxes)
            permStack.addArrangedSubview(line)
        }

        let octalLabel = NSTextField(labelWithString: L("八进制(C)"))
        octalLabel.font = .systemFont(ofSize: 12)
        octalLabel.translatesAutoresizingMaskIntoConstraints = false
        octalLabel.widthAnchor.constraint(equalToConstant: 92).isActive = true
        octalField.stringValue = initialOctal
        octalField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        octalField.target = self
        octalField.action = #selector(octalSubmitted)
        octalField.translatesAutoresizingMaskIntoConstraints = false

        let bottom = NSStackView(views: [octalLabel, octalField])
        bottom.orientation = .horizontal
        bottom.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(nameLabel)
        addSubview(infoStack)
        addSubview(permStack)
        addSubview(bottom)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.topAnchor.constraint(equalTo: topAnchor),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            nameLabel.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            infoStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            infoStack.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 10),
            permStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            permStack.topAnchor.constraint(equalTo: infoStack.bottomAnchor, constant: 12),
            bottom.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottom.topAnchor.constraint(equalTo: permStack.bottomAnchor, constant: 12),
            bottom.trailingAnchor.constraint(equalTo: trailingAnchor),
            octalField.widthAnchor.constraint(equalToConstant: 120),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func computedMode() -> UInt32 {
        var value: UInt32 = 0
        for row in 0..<3 {
            for col in 0..<3 {
                if boxes[row][col].state == .on { value |= UInt32(0o400) >> (row * 3 + col) }
            }
            if special[row].state == .on { value |= UInt32(0o4000) >> row }
        }
        return value
    }

    /// OK 时调用：勾选与初始八进制不一致才返回待 chmod 的值
    func changedOctal() -> String? {
        let current = String(format: "%04o", computedMode())
        return current == initialOctal ? nil : current
    }

    @objc private func boxesChanged() {
        octalField.stringValue = String(format: "%04o", computedMode())
    }

    @objc private func octalSubmitted() {
        guard let value = UInt32(octalField.stringValue, radix: 8), value <= 0o7777 else {
            octalField.stringValue = String(format: "%04o", computedMode())
            return
        }
        mode = value
        for row in 0..<3 {
            for col in 0..<3 {
                boxes[row][col].state = (value & UInt32(0o400) >> (row * 3 + col)) != 0 ? .on : .off
            }
            special[row].state = (value & UInt32(0o4000) >> row) != 0 ? .on : .off
        }
    }
}

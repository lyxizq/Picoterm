import AppKit
import PicotermCore

struct PaletteItem {
    let title: String
    let symbol: String
    let action: () -> Void
}

// 命令面板：玻璃浮层 + 过滤列表（回车/双击执行，Esc 或点击面板外空白处关闭）
final class CommandPaletteView: NSVisualEffectView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var allItems: [PaletteItem] = []
    private var visible: [PaletteItem] = []
    private var monitor: Any?
    private var globalMonitor: Any?
    var onClose: (() -> Void)?

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        searchField.placeholderString = L("输入命令、会话或主机…")
        searchField.font = NSFont.systemFont(ofSize: 13)
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(executeSelected)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cmd"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 30
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(executeSelected)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(searchField)
        addSubview(scroll)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(items: [PaletteItem]) {
        allItems = items
        applyFilter(searchField.stringValue)
        isHidden = false
        installMonitor()
        window?.makeFirstResponder(searchField)
    }

    func dismiss() {
        isHidden = true
        searchField.stringValue = ""
        removeMonitor()
        onClose?()
    }

    /// 焦点在搜索框内时 keyDown 不会到达本视图，Esc/↑↓ 必须经本地监听接管；
    /// 只在面板可见时消费按键，其余一律透传。
    /// 点击面板外任意位置（本窗口内经 local，其他 app 经 global）自动关闭。
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, !self.isHidden, event.window === self.window else { return event }
            if event.type == .keyDown {
                switch event.keyCode {
                case 53: // Esc
                    self.dismiss()
                    return nil
                case 125: // ↓
                    self.moveSelection(1)
                    return nil
                case 126: // ↑
                    self.moveSelection(-1)
                    return nil
                default:
                    return event
                }
            }
            // 鼠标按下：点在本面板内交给面板正常处理，点在外面即关闭
            let point = self.convert(event.locationInWindow, from: nil)
            if !self.bounds.contains(point) {
                self.dismiss()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // 点击发生在其他 app 的窗口：同样关闭
            self?.dismiss()
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }

    private func applyFilter(_ keyword: String) {
        let kw = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        visible = kw.isEmpty ? allItems : allItems.filter { $0.title.lowercased().contains(kw) }
        table.reloadData()
        if !visible.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    @objc private func executeSelected() {
        guard !visible.isEmpty else { return }
        let row = table.selectedRow >= 0 ? table.selectedRow : 0
        let item = visible[min(row, visible.count - 1)]
        dismiss()
        item.action()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss() } // Esc
        else if event.keyCode == 125 { moveSelection(1) }
        else if event.keyCode == 126 { moveSelection(-1) }
        else { super.keyDown(with: event) }
    }

    private func moveSelection(_ delta: Int) {
        guard !visible.isEmpty else { return }
        let current = max(table.selectedRow, 0)
        let next = min(max(current + delta, 0), visible.count - 1)
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let item = visible[safe: row] else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("paletteCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NodeCellView)
            ?? NodeCellView()
        cell.identifier = identifier
        cell.configure(node: Node(title: item.title, symbol: item.symbol))
        return cell
    }

    // MARK: NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(searchField.stringValue)
    }

    /// 焦点在搜索框时按键走 field editor 的命令路径（不经 keyDown/monitor），在此接 Esc/↑↓
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss()
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            moveSelection(-1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            moveSelection(1)
            return true
        }
        return false
    }
}

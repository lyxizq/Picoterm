import AppKit
import SwiftTerm
import PicotermCore

/// 终端主题选择器（2026-10-26 用户指定）：搜索框 + 列表（名称 + 色板预览），内置 5 套在前、
/// Tabby 社区 190 套在后；选中即预览到全部已开终端，取消回滚到打开前的主题，双击/「使用」确认。
/// 下拉框装不下近 200 项，故独立成弹窗；走 PicotermDialog 模态。
@MainActor
enum ThemePickerDialog {
    /// 返回选定主题（已预览但未写设置，由调用方落盘）；取消返回 nil 并已回滚预览
    static func run(parent: NSWindow?) -> TerminalTheme? {
        let content = ThemePickerContent(selectedId: AppSettings.shared.terminalThemeId)
        let response = PicotermDialog.run(title: L("选择终端主题"), content: content, primaryTitle: L("使用"),
                                          contentWidth: 520, parent: parent)
        if response == .OK, let theme = content.selectedTheme {
            return theme
        }
        SessionManager.shared.applyAppearanceToAll()
        return nil
    }

    /// 预览：直接套到终端视图，不动设置
    static func preview(_ theme: TerminalTheme) {
        for session in SessionManager.shared.sessions {
            if let tv = session.terminalView as? TerminalView {
                ThemeApplier.apply(theme, to: tv)
            }
        }
    }
}

final class ThemePickerContent: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let countLabel = NSTextField(labelWithString: "")
    private var visible: [TerminalTheme] = TerminalThemes.all
    private(set) var selectedTheme: TerminalTheme?

    init(selectedId: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        selectedTheme = TerminalThemes.theme(id: selectedId)

        searchField.placeholderString = L("搜索主题（如 solarized、dark、light）")
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("theme"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 34
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(searchField)
        addSubview(scroll)
        addSubview(countLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 420),
            searchField.topAnchor.constraint(equalTo: topAnchor),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            countLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            countLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        table.reloadData()
        updateCount()
        if let index = visible.firstIndex(where: { $0.id == selectedId }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(searchField)
    }

    private func updateCount() {
        countLabel.stringValue = L("%ld 套（内置 %ld + 社区 %ld）", visible.count, TerminalThemes.builtIn.count, TerminalThemes.community.count)
    }

    // MARK: 搜索

    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let keep = selectedTheme
        visible = query.isEmpty ? TerminalThemes.all : TerminalThemes.all.filter {
            $0.name.lowercased().contains(query) || $0.id.lowercased().contains(query)
        }
        table.reloadData()
        updateCount()
        if let keep, let index = visible.firstIndex(where: { $0.id == keep.id }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        }
    }

    /// 搜索框里 ↑↓ 移动列表选中，回车交给弹窗主按钮
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let delta: Int
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): delta = 1
        case #selector(NSResponder.moveUp(_:)): delta = -1
        default: return false
        }
        guard !visible.isEmpty else { return true }
        let current = table.selectedRow
        let next = current < 0 ? (delta > 0 ? 0 : visible.count - 1) : min(max(current + delta, 0), visible.count - 1)
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
        return true
    }

    // MARK: 列表

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ThemeRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? ThemeRowView) ?? ThemeRowView(identifier: id)
        cell.configure(visible[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, table.selectedRow < visible.count else { return }
        let theme = visible[table.selectedRow]
        selectedTheme = theme
        ThemePickerDialog.preview(theme)
    }

    @objc private func rowDoubleClicked() {
        guard table.clickedRow >= 0 else { return }
        NSApp.stopModal(withCode: .OK)
    }
}

/// 列表行：名称（内置标记）+ 色板预览
final class ThemeRowView: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let swatch = ThemeSwatchView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        nameLabel.font = NSFont.systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        swatch.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)
        addSubview(swatch)
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.widthAnchor.constraint(equalToConstant: 200),
            swatch.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            swatch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            swatch.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            swatch.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ theme: TerminalTheme) {
        nameLabel.stringValue = theme.id.hasPrefix("tabby:") ? theme.name : L("%@（内置）", theme.name)
        swatch.theme = theme
    }
}

/// 色板：主题底色上画 "Aa" 前景字样 + 光标条 + ANSI 0–7 八个色块
final class ThemeSwatchView: NSView {
    var theme: TerminalTheme? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
        NSColor(hex: theme.background).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let text = NSAttributedString(string: "Aa $ ls", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor(hex: theme.foreground),
        ])
        let textSize = text.size()
        text.draw(at: NSPoint(x: 10, y: (bounds.height - textSize.height) / 2))

        let cursor = NSRect(x: 10 + textSize.width + 3, y: (bounds.height - 14) / 2, width: 2, height: 14)
        NSColor(hex: theme.cursor).setFill()
        cursor.fill()

        let square: CGFloat = 12
        let gap: CGFloat = 3
        var x = bounds.width - 8 - (square * 8 + gap * 7)
        let y = (bounds.height - square) / 2
        for hex in theme.ansi.prefix(8) {
            NSColor(hex: hex).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: square, height: square), xRadius: 2, yRadius: 2).fill()
            x += square + gap
        }
    }
}

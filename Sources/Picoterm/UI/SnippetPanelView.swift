import AppKit
import PicotermCore

// 脚本片段面板（TODO 23）：展示当前主机的专属脚本，语法高亮预览，
// 新增/编辑/复制/删除；UI 形态参考 Berth Snippets（列表 + 预览 + 管理动作）
final class SnippetPanelView: NSView {
    /// 当前主机（由外层跟随选中会话喂入）
    private(set) var hostId: UUID?
    private var hostLabel = ""

    private let hostPopUp = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let listStack = NSStackView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: L("在左侧选中主机即可管理其脚本"))

    private let codeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 由外层容器钉边布局；不关掉 autoresizing 转换会以 0×0 frame 参与约束冲突，
        // 布局引擎折衷后把工具行顶出可视区（表现为整个面板"空白"、+ 不可点）
        translatesAutoresizingMaskIntoConstraints = false

        // 工具行：主机下拉（可手动切换，未选主机时也可经此定位后新增）+ 状态提示 + 新增
        hostPopUp.controlSize = .regular
        hostPopUp.font = .systemFont(ofSize: 13)
        hostPopUp.menu?.font = .systemFont(ofSize: 13)
        hostPopUp.bezelStyle = .texturedSquare
        hostPopUp.translatesAutoresizingMaskIntoConstraints = false
        hostPopUp.target = self
        hostPopUp.action = #selector(hostPopUpChanged)
        rebuildHostPopUp()

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let addButton = GlassIconButton(symbol: "plus", size: 22, pointSize: 10, tooltip: L("新增脚本"))
        addButton.button.target = self
        addButton.button.action = #selector(addClicked)

        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(hostPopUp)
        toolbar.addSubview(statusLabel)
        toolbar.addSubview(addButton)

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 8
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listStack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 8, right: 8)

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(listStack)
        document.wantsLayer = true

        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(toolbar)
        addSubview(scroll)
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 34),

            hostPopUp.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            hostPopUp.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            hostPopUp.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            statusLabel.leadingAnchor.constraint(equalTo: hostPopUp.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: addButton.leadingAnchor, constant: -8),
            addButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
            addButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: document.topAnchor),
            listStack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -8),
        ])

        SnippetStore.shared.onChanged = { [weak self] in self?.reload() }
        HostStore.shared.observe { [weak self] in self?.rebuildHostPopUp() }
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // init 时 HostStore 尚未 load（下拉为空导致新增兜底失效），挂上窗口后重建一次
        rebuildHostPopUp()
        // 尚未跟随任何主机时自动落到第一台，面板开箱即用（查看/新增都不用先点树）
        if hostId == nil, let first = HostStore.shared.hosts.first {
            hostId = first.id
            hostLabel = first.label
            syncPopUpSelection()
        }
        reload()
    }

    // MARK: 数据

    /// 跟随选中会话/树选中切换主机
    func setHost(_ id: UUID?, label: String) {
        hostId = id
        hostLabel = label
        syncPopUpSelection()
        reload()
    }

    private func reload() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let snippets = hostId.map { SnippetStore.shared.snippets(for: $0) } ?? []
        statusLabel.stringValue = ""
        scroll.isHidden = snippets.isEmpty
        emptyLabel.isHidden = !snippets.isEmpty
        emptyLabel.stringValue = hostId == nil
            ? (hostPopUp.numberOfItems > 0 ? L("在左侧选中主机，或用上方下拉选择") : L("先在左侧添加主机，再管理其脚本"))
            : L("还没有脚本，点右上 + 新增")

        for snippet in snippets {
            let card = SnippetCardView(snippet: snippet, font: codeFont)
            card.onCopy = { [weak self] in self?.copySnippet(snippet) }
            card.onEdit = { [weak self] in self?.editSnippet(snippet) }
            card.onDelete = { [weak self] in self?.deleteSnippet(snippet) }
            listStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -16).isActive = true
        }
    }

    // MARK: 主机下拉

    private func rebuildHostPopUp() {
        hostPopUp.removeAllItems()
        for entry in HostStore.shared.hosts {
            hostPopUp.addItem(withTitle: entry.label)
            hostPopUp.lastItem?.representedObject = entry.id
        }
        syncPopUpSelection()
        // 下拉就绪后刷新一次：init 早期的 reload 跑在主机库 load 之前，空态文案会停在旧分支
        if window != nil {
            reload()
        }
    }

    private func syncPopUpSelection() {
        guard let hostId else { return }
        for item in hostPopUp.itemArray where item.representedObject as? UUID == hostId {
            hostPopUp.select(item)
            return
        }
    }

    @objc private func hostPopUpChanged() {
        guard let id = hostPopUp.selectedItem?.representedObject as? UUID,
              let entry = HostStore.shared.hosts.first(where: { $0.id == id }) else { return }
        hostId = id
        hostLabel = entry.label
        reload()
    }

    // MARK: 动作

    @objc private func addClicked() {
        // 未跟随到主机时，用下拉当前选中（默认第一台）兜底，新增始终可用
        let target = hostId
            ?? hostPopUp.selectedItem?.representedObject as? UUID
        guard let hostId = target else {
            PicotermDialog.run(title: L("还没有主机"),
                               content: PicotermDialog.message(L("先在左侧会话树中添加一台主机，再为其配置脚本。")),
                               primaryTitle: L("好"), cancelTitle: "", parent: window)
            return
        }
        if self.hostId == nil {
            // 把面板切到兜底选中的主机，新增后立即可见
            setHost(hostId, label: HostStore.shared.hosts.first(where: { $0.id == hostId })?.label ?? "")
        }
        presentEditor(title: L("新增脚本"), name: "", script: "") { name, script in
            SnippetStore.shared.add(hostId: hostId, name: name, script: script)
        }
    }

    private func editSnippet(_ snippet: HostSnippet) {
        guard let hostId else { return }
        presentEditor(title: L("编辑脚本"), name: snippet.name, script: snippet.script) { name, script in
            SnippetStore.shared.update(hostId: hostId, snippetId: snippet.id, name: name, script: script)
        }
    }

    private func copySnippet(_ snippet: HostSnippet) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet.script, forType: .string)
        flashStatus(L("已复制「%@」", snippet.name))
    }

    private func deleteSnippet(_ snippet: HostSnippet) {
        guard let hostId else { return }
        guard PicotermDialog.run(title: L("删除脚本"),
                                 content: PicotermDialog.message(L("确定删除「%@」？", snippet.name)),
                                 primaryTitle: L("删除"), destructive: true,
                                 parent: window) == .OK else { return }
        SnippetStore.shared.remove(hostId: hostId, snippetId: snippet.id)
    }

    private func flashStatus(_ text: String) {
        statusLabel.stringValue = text
        MainThread.perform(after: 1.6) { [weak self] in
            self?.statusLabel.stringValue = ""
        }
    }

    /// 名称 + 脚本编辑弹窗（自建模态窗口，样式对齐新建/编辑连接对话框，无 App 图标）
    private func presentEditor(title: String, name: String, script: String,
                               completion: @escaping (String, String) -> Void) {
        let controller = SnippetEditorWindowController(title: title, name: name, script: script)
        controller.runModal()
        guard let result = controller.result else { return }
        completion(result.name, result.script)
    }
}

// 新增/编辑脚本表单：右字段左标签行式布局，复用 ConnectionDialogView.rowLabel 保持口径一致
final class SnippetEditorView: NSView {
    let nameField = NSTextField(string: "")
    private let textView = NSTextView()
    private let hintLabel = NSTextField(labelWithString: L("名称不能为空"))

    init(frame: NSRect, name: String, script: String) {
        super.init(frame: frame)

        nameField.placeholderString = L("如：重启 nginx")
        nameField.stringValue = name

        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = script
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.autoresizingMask = [.width]

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .systemRed
        hintLabel.isHidden = true

        let textScroll = NSScrollView()
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder

        let nameRowY = frame.height - 28
        let nameLabel = ConnectionDialogView.rowLabel(L("名称"))
        nameLabel.frame = NSRect(x: 0, y: nameRowY + 3, width: 84, height: 20)
        nameField.frame = NSRect(x: 92, y: nameRowY, width: frame.width - 92 - 16, height: 24)
        hintLabel.frame = NSRect(x: 92, y: nameRowY - 21, width: 180, height: 15)
        let scriptLabel = ConnectionDialogView.rowLabel(L("脚本"))
        scriptLabel.frame = NSRect(x: 0, y: nameRowY - 41, width: 84, height: 20)
        textScroll.frame = NSRect(x: 92, y: 12, width: frame.width - 92 - 16, height: nameRowY - 56)
        textView.frame = NSRect(x: 0, y: 0, width: textScroll.bounds.width, height: 100)

        addSubview(nameLabel)
        addSubview(nameField)
        addSubview(hintLabel)
        addSubview(scriptLabel)
        addSubview(textScroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 保存结果；名称为空时亮提示并返回 nil（留在窗口里改）
    func makeResult() -> (name: String, script: String)? {
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            hintLabel.isHidden = false
            return nil
        }
        return (trimmed, textView.string)
    }
}

// 新增/编辑脚本模态窗口：无图标、标题入标题栏、底部取消/保存（回车=保存/Esc=取消），样式对齐 ConnectionDialogWindowController
final class SnippetEditorWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let editor: SnippetEditorView
    private(set) var result: (name: String, script: String)?

    init(title: String, name: String, script: String) {
        let formSize = NSSize(width: 460, height: 340)
        editor = SnippetEditorView(frame: NSRect(origin: .zero, size: formSize), name: name, script: script)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: formSize.width, height: formSize.height + 64),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self

        let save = GlassTextButton(title: L("保存"), emphasized: true)
        save.button.target = self
        save.button.action = #selector(saveClicked)
        save.button.keyEquivalent = "\r"
        let cancel = GlassTextButton(title: L("取消"))
        cancel.button.target = self
        cancel.button.action = #selector(cancelClicked)
        cancel.button.keyEquivalent = "\u{1b}"

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        editor.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(editor)
        contentView.addSubview(save)
        contentView.addSubview(cancel)
        window.contentView = contentView
        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(equalToConstant: formSize.width),
            contentView.heightAnchor.constraint(equalToConstant: formSize.height + 64),
            editor.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            editor.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            save.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            save.topAnchor.constraint(equalTo: editor.bottomAnchor, constant: 14),
            save.widthAnchor.constraint(equalToConstant: 96),
            cancel.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -10),
            cancel.centerYAnchor.constraint(equalTo: save.centerYAnchor),
            cancel.widthAnchor.constraint(equalToConstant: 96),
            contentView.bottomAnchor.constraint(equalTo: save.bottomAnchor, constant: 14),
        ])
        window.initialFirstResponder = editor.nameField
    }

    /// 阻塞运行；结束后从 result 取保存结果（nil = 取消）
    func runModal() {
        window.center()
        NSApp.runModal(for: window)
        window.orderOut(nil)
    }

    @objc private func saveClicked() {
        guard let value = editor.makeResult() else { return } // 名称空：留在窗口里改
        result = value
        NSApp.stopModal(withCode: .OK)
    }

    @objc private func cancelClicked() {
        NSApp.stopModal(withCode: .cancel)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.stopModal(withCode: .cancel)
        return true
    }
}

/// 单条脚本卡片：名称行（名称 + 复制/编辑/删除按钮）+ 深色高亮预览块
private final class SnippetCardView: NSView {
    var onCopy: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    init(snippet: HostSnippet, font: NSFont) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: snippet.name)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleRow.addArrangedSubview(name)

        let copy = GlassIconButton(symbol: "doc.on.doc", size: 20, pointSize: 9, tooltip: L("复制内容"))
        let edit = GlassIconButton(symbol: "pencil", size: 20, pointSize: 9, tooltip: L("编辑"))
        let remove = GlassIconButton(symbol: "trash", size: 20, pointSize: 9, tooltip: L("删除"))
        copy.button.target = self
        copy.button.action = #selector(copyClicked)
        edit.button.target = self
        edit.button.action = #selector(editClicked)
        remove.button.target = self
        remove.button.action = #selector(removeClicked)
        for button in [copy, edit, remove] {
            button.widthAnchor.constraint(equalToConstant: 20).isActive = true
            button.heightAnchor.constraint(equalToConstant: 20).isActive = true
            titleRow.addArrangedSubview(button)
        }

        // 高亮预览：深色圆角块，最多显示 8 行
        let preview = NSTextField(labelWithString: "")
        preview.allowsEditingTextAttributes = false
        preview.isSelectable = true
        preview.preferredMaxLayoutWidth = 320
        var script = snippet.script
        var truncated = false
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 8 {
            script = lines.prefix(8).joined(separator: "\n") + "\n…"
            truncated = true
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        let highlighted = ShellHighlighter.highlight(script, font: font).mutableCopy() as! NSMutableAttributedString
        highlighted.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: highlighted.length))
        preview.attributedStringValue = highlighted
        preview.translatesAutoresizingMaskIntoConstraints = false

        let previewBox = NSView()
        previewBox.translatesAutoresizingMaskIntoConstraints = false
        previewBox.wantsLayer = true
        previewBox.layer?.cornerRadius = 6
        previewBox.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        previewBox.addSubview(preview)

        addSubview(titleRow)
        addSubview(previewBox)
        NSLayoutConstraint.activate([
            titleRow.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            previewBox.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 6),
            previewBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            previewBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            previewBox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            preview.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 8),
            preview.trailingAnchor.constraint(lessThanOrEqualTo: previewBox.trailingAnchor, constant: -8),
            preview.topAnchor.constraint(equalTo: previewBox.topAnchor, constant: 6),
            preview.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: -6),
        ])
        _ = truncated
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func copyClicked() { onCopy?() }
    @objc private func editClicked() { onEdit?() }
    @objc private func removeClicked() { onDelete?() }
}

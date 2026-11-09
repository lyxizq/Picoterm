import AppKit
import PicotermCore

// 终端搜索条（参考 WindTerm 查找功能）：悬浮在终端卡片右上角。
// 输入即对缓冲区全部匹配打黄色底标；回车/↑↓ 切换当前匹配（选区色 + 滚动跟随），
// 计数标签显示「第几个/共几个」；Esc（清空后）/× 关闭并清除高亮
final class TerminalSearchBarView: NSVisualEffectView, NSSearchFieldDelegate {
    var onSearchChanged: ((String) -> Void)?
    var onFindNext: (() -> Void)?
    var onFindPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    private let field = TerminalSearchField()
    private let countLabel = NSTextField(labelWithString: "")

    var searchText: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        field.placeholderString = L("搜索终端输出")
        field.controlSize = .small
        field.font = .systemFont(ofSize: 12)
        field.delegate = self
        field.target = self
        field.action = #selector(fieldAction)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.onEmptyCancel = { [weak self] in self?.onClose?() }

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let previous = GlassIconButton(symbol: "chevron.up", size: 22, pointSize: 10, tooltip: L("上一个 (⇧↩)"))
        let next = GlassIconButton(symbol: "chevron.down", size: 22, pointSize: 10, tooltip: L("下一个 (↩)"))
        let close = GlassIconButton(symbol: "xmark", size: 22, pointSize: 9, tooltip: L("关闭 (Esc)"))
        previous.button.target = self
        previous.button.action = #selector(previousClicked)
        next.button.target = self
        next.button.action = #selector(nextClicked)
        close.button.target = self
        close.button.action = #selector(closeClicked)

        let stack = NSStackView(views: [field, countLabel, previous, next, close])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            field.widthAnchor.constraint(equalToConstant: 190),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setCount(_ text: String) {
        countLabel.stringValue = text
    }

    func focus() {
        window?.makeFirstResponder(field)
    }

    // MARK: NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        onSearchChanged?(field.stringValue)
    }

    // MARK: 动作

    @objc private func fieldAction() {
        // 回车 = 下一个；Shift+回车 = 上一个（与系统查找条一致）
        if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
            onFindPrevious?()
        } else {
            onFindNext?()
        }
    }

    @objc private func previousClicked() { onFindPrevious?() }
    @objc private func nextClicked() { onFindNext?() }
    @objc private func closeClicked() { onClose?() }
}

// 搜索框：Esc 先清空（NSSearchField 默认），已空再 Esc 关闭整条
final class TerminalSearchField: NSSearchField {
    var onEmptyCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        if stringValue.isEmpty {
            onEmptyCancel?()
        } else {
            super.cancelOperation(sender)
        }
    }
}

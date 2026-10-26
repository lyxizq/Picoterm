import AppKit
import SwiftTerm

// 终端补全容器：盖在终端卡片上，⇥ 触发历史/关键词补全浮层
// （TODO 18；交互口径参考 Berth：事件 monitor 精确消费，无候选时按键透传不打扰 shell）
// 浮层为自绘固定样式（半透明深底+白字+选中高亮）——不依赖 NSVisualEffectView 材质，
// 在深色/浅色窗口下所见即所得（hudWindow 材质在本工程窗口下渲染成无字灰块）
final class CompletionTerminalContainer: NSView {
    let terminalView: TerminalView
    private let overlay = NSView()
    private var rowViews: [NSView & CompletionRow] = []
    private var candidates: [String] = []
    private var selectedIndex = 0

    private let rowHeight: CGFloat = 22
    private let maxVisibleRows = 8

    var onCompleted: ((String) -> Void)?

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        onCompleted = { [weak terminalView] candidate in
            (terminalView as? CompletionTerminalView)?.complete(with: candidate)
        }

        overlay.isHidden = true
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = 8
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        overlay.layer?.borderWidth = 0.5
        overlay.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var isVisible: Bool { !overlay.isHidden }

    /// 隐藏时不参与命中测试，终端鼠标操作（选择/滚动）不被遮挡
    override func hitTest(_ point: NSPoint) -> NSView? {
        overlay.isHidden ? nil : super.hitTest(point)
    }

    /// 行点击：选中并应用
    func rowClicked(_ row: NSView) {
        guard let index = rowViews.firstIndex(where: { $0 === row }) else { return }
        setSelected(index)
        applySelected()
    }

    /// 浮层跟随终端光标：弹窗顶边贴光标下缘（光标右下方），底部放不下时翻到光标上方
    override func layout() {
        super.layout()
        guard !overlay.isHidden, !candidates.isEmpty else { return }
        let shown = min(candidates.count, maxVisibleRows)
        let width: CGFloat = 280
        let height = CGFloat(shown) * rowHeight + 10

        // caretFrame 由 SwiftTerm 以 AppKit 底左原点维护（updateCursorPosition:
        // y = frame.height - 行偏移），并非翻转坐标——x 与光标列对齐、微右移，
        // y 直接用光标下缘往下摆（此前误当翻转坐标二次换算，弹窗跑到了屏幕底部）
        let caret = terminalView.caretFrame
        let x = min(max(caret.minX + 4, 8), max(bounds.width - width - 8, 8))
        var y = caret.minY - height - 2
        if y < 8 {
            y = min(caret.maxY + 2, max(bounds.height - height - 8, 8))
        }
        overlay.frame = NSRect(x: x, y: y, width: width, height: height)

        for (index, row) in rowViews.enumerated() {
            row.frame = NSRect(x: 1, y: height - 5 - CGFloat(index + 1) * rowHeight,
                               width: width - 2, height: rowHeight)
        }
    }

    /// ⇥ 处理：返回 true 表示已消费；无候选返回 false（Tab 透传给 shell 原生补全）
    @discardableResult
    func handleTab(shift: Bool) -> Bool {
        if overlay.isHidden {
            return showCompletions()
        }
        moveSelection(shift ? -1 : 1)
        return true
    }

    /// 弹层显示时的方向键移动；返回是否已消费
    @discardableResult
    func handleArrow(_ delta: Int) -> Bool {
        guard isVisible else { return false }
        moveSelection(delta)
        return true
    }

    /// Esc / 输入新字符时关闭
    func dismiss() {
        overlay.isHidden = true
        candidates = []
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = []
    }

    func applySelected() {
        let row = min(max(selectedIndex, 0), candidates.count - 1)
        guard row >= 0, row < candidates.count else { return }
        let completion = candidates[row]
        dismiss()
        onCompleted?(completion)
    }

    private func moveSelection(_ delta: Int) {
        guard !candidates.isEmpty else { return }
        var row = selectedIndex + delta
        if row < 0 { row = candidates.count - 1 }
        if row >= candidates.count { row = 0 }
        setSelected(row)
    }

    private func setSelected(_ row: Int) {
        selectedIndex = row
        for (index, rowView) in rowViews.enumerated() {
            rowView.setHighlighted(index == row)
        }
    }

    private func showCompletions() -> Bool {
        guard let info = CompletionInputTracker.shared.currentWordInfo(),
              info.isCommandPosition, !info.word.isEmpty else {
            return false
        }
        let matched = CommandHistory.shared.completions(prefix: info.word)
        guard !matched.isEmpty else { return false }

        dismiss()
        candidates = matched
        for candidate in matched.prefix(maxVisibleRows) {
            let row = CompletionRowView(text: candidate)
            overlay.addSubview(row)
            rowViews.append(row)
        }
        setSelected(0)
        overlay.isHidden = false
        needsLayout = true
        return true
    }
}

/// 补全行：白字等宽，选中行强调色高亮
private protocol CompletionRow: NSView {
    func setHighlighted(_ on: Bool)
}

private final class CompletionRowView: NSView, CompletionRow {
    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        label.stringValue = text
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setHighlighted(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setHighlighted(_ on: Bool) {
        layer?.backgroundColor = on
            ? NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            : NSColor.clear.cgColor
        label.textColor = on ? .white : NSColor.white.withAlphaComponent(0.88)
    }

    override func mouseDown(with event: NSEvent) {
        (superview?.superview as? CompletionTerminalContainer)?.rowClicked(self)
    }
}

/// TerminalView 的 ⇥ 补全能力：本地事件监听器方案（performKeyEquivalent 非 open，不能子类化覆盖）
final class CompletionTerminalView: TerminalView {
    var completionContainer: CompletionTerminalContainer?
    /// 选中补全项后：把「补全词 - 已输入前缀」作为剩余键入发回远端
    var sendCompletion: ((String) -> Void)?
    private var monitor: Any?

    /// 挂到窗口的 ⇥/Esc 本地监听（窗口关闭时 removeMonitor）
    func installMonitor(in window: NSWindow) {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === window else { return event }
            // 只在 本终端持有键盘焦点 时处理，多窗格互不抢键
            guard let responder = window.firstResponder as? NSView,
                  responder === self || responder.isDescendant(of: self) else { return event }
            guard let container = self.completionContainer else { return event }

            if event.keyCode == 48 { // Tab
                if container.handleTab(shift: event.modifierFlags.contains(.shift)) {
                    return nil
                }
                return event
            }
            guard container.isVisible else { return event }
            switch event.keyCode {
            case 36, 76: // Return / 小键盘 Enter：应用选中项，回车不进 shell
                container.applySelected()
                return nil
            case 53: // Esc
                container.dismiss()
                return nil
            case 125: // ↓
                container.handleArrow(1)
                return nil
            case 126: // ↑
                container.handleArrow(-1)
                return nil
            default: // 其余按键：关浮层并透传给终端
                container.dismiss()
                return event
            }
        }
    }

    func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func complete(with candidate: String) {
        let remaining: String
        if let typed = CompletionInputTracker.shared.currentWordInfo()?.word,
           candidate.hasPrefix(typed), candidate.count > typed.count {
            remaining = String(candidate.dropFirst(typed.count))
        } else {
            remaining = candidate
        }
        sendCompletion?(remaining)
        // 同步行缓冲，避免二次补全重复
        CompletionInputTracker.shared.feed(Array(remaining.utf8))
        completionContainer?.dismiss()
    }
}

/// 追踪用户键入的当前行/当前词（send 拦截路径喂进来）
final class CompletionInputTracker {
    static let shared = CompletionInputTracker()
    private var currentLine = ""

    /// 键盘字节流喂入：维护行缓冲
    func feed(_ bytes: [UInt8]) {
        var utf8Run: [UInt8] = []
        // ESC 转义序列状态机：none → sawEsc → sawCSI('[')/sawSS3('O') → 终结
        enum EscState { case none, sawEsc, sawCSI, sawSS3 }
        var escState: EscState = .none
        var escapeBytes: [UInt8] = []

        func flushUTF8() {
            guard !utf8Run.isEmpty else { return }
            currentLine += String(decoding: utf8Run, as: UTF8.self)
            utf8Run = []
        }

        func endEscape() {
            escState = .none
            // ↑/↓ 调历史会整行替换，行缓冲作废清空（Tab 时无词则透传，保守安全）
            if escapeBytes == [0x5b, 0x41] || escapeBytes == [0x5b, 0x42] {
                currentLine = ""
                utf8Run = []
            }
            escapeBytes = []
        }

        for byte in bytes {
            switch escState {
            case .sawEsc:
                escapeBytes.append(byte)
                if byte == 0x5b { // ESC [ → CSI，等终结符
                    escState = .sawCSI
                } else if byte == 0x4f { // ESC O → SS3，再吞一字符
                    escState = .sawSS3
                } else {
                    endEscape() // 单字符 ESC 序列
                }
                continue
            case .sawCSI:
                escapeBytes.append(byte)
                // 参数区 0x30–0x3F / 中间区 0x20–0x2F 之后遇 0x40–0x7E 终结
                if byte >= 0x40 && byte <= 0x7e { endEscape() }
                continue
            case .sawSS3:
                escapeBytes.append(byte)
                endEscape()
                continue
            case .none:
                break
            }
            switch byte {
            case 0x1b: // ESC：进入转义序列吞噬
                flushUTF8()
                escState = .sawEsc
                escapeBytes = []
            case 0x0d, 0x0a: // Enter：整行入历史
                flushUTF8()
                let line = currentLine.trimmingCharacters(in: .whitespaces)
                if !line.isEmpty { CommandHistory.shared.record(line) }
                currentLine = ""
            case 0x7f, 0x08: // Backspace
                flushUTF8()
                if !currentLine.isEmpty { currentLine.removeLast() }
            case 0x09: // Tab：不动行缓冲
                break
            case 0x03, 0x15, 0x17: // ^C ^U ^W：清行
                currentLine = ""
                utf8Run = []
            case 0x0c, 0x0f, 0x10, 0x12, 0x14, 0x19: // ^L ^O ^P ^R ^T ^Y 等行外控制键：忽略
                break
            default:
                if byte >= 0x80 {
                    utf8Run.append(byte) // UTF-8 多字节合并解码
                } else if byte >= 0x20 {
                    flushUTF8()
                    currentLine.append(Character(UnicodeScalar(byte)))
                } else {
                    flushUTF8()
                }
            }
        }
        flushUTF8()
    }

    /// 当前词 + 是否处于命令位（行首词）。
    /// 只有命令位才触发客户端命令补全；参数位（如 `cd d` 的 d）交回 shell 补全路径/参数。
    func currentWordInfo() -> (word: String, isCommandPosition: Bool)? {
        let word = currentLine.split(separator: " ").last.map(String.init) ?? ""
        guard !word.isEmpty else { return nil }
        let trimmed = currentLine.drop { $0 == " " }
        let isCommandPosition = !trimmed.contains(" ")
        return (word, isCommandPosition)
    }
}

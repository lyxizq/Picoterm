import AppKit
import SwiftTerm
import PicotermCore

// MARK: - 材质工具

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

enum AppTheme {
    static let terminalBackground = NSColor(calibratedRed: 0.075, green: 0.086, blue: 0.11, alpha: 1)

    static var currentTheme: TerminalTheme {
        TerminalThemes.theme(id: AppSettings.shared.terminalThemeId)
    }

    static var currentTerminalBackground: NSColor {
        NSColor(hex: currentTheme.background)
    }

    static var currentTerminalForeground: NSColor {
        NSColor(hex: currentTheme.foreground)
    }

    /// 当前外观（主题 + 字体 + 字号）套到终端视图；Ported from Berth TerminalTheme/TerminalFontPrefs
    static func apply(to terminalView: TerminalView) {
        let settings = AppSettings.shared
        let family = settings.terminalFontFamily
        let size = settings.terminalFontSize
        if let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            terminalView.font = font
        } else if !family.isEmpty, let font = NSFont(name: family, size: size) {
            terminalView.font = font
        } else {
            terminalView.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        ThemeApplier.apply(TerminalThemes.theme(id: settings.terminalThemeId), to: terminalView)
        // 链接识别为 SwiftTerm 内置（URL + 路径正则）；这里只定点击门槛：⌘悬停下划线/⌘点击 或 直接悬停/点击
        terminalView.linkHighlightMode = settings.linkClickRequiresCommand ? .hoverWithModifier : .hover
        // 光标样式经 DECSCUSR 标准序列（caretView 非公开 API）
        let styleSeq: String
        switch settings.cursorStyle {
        case "underline": styleSeq = "\u{1b}[4 q"
        case "bar": styleSeq = "\u{1b}[6 q"
        default: styleSeq = "\u{1b}[2 q"
        }
        terminalView.feed(text: styleSeq)
    }
}

// 回滚缓冲设置应用（TODO 74）：SwiftTerm 的 startupOptions 不公开，Terminal 创建时机
// 外部不可见；changeScrollback 为公开的运行时接口（保留缓冲内容）。终端创建后的首次
// sizeChanged 兜底应用一次，设置页改动时强制刷新所有存活视图。主线程调用。
extension TerminalView {
    private static var appliedScrollbackViews = Set<ObjectIdentifier>()

    func applyScrollbackSetting(force: Bool = false) {
        let id = ObjectIdentifier(self)
        guard force || !Self.appliedScrollbackViews.contains(id) else { return }
        Self.appliedScrollbackViews.insert(id)
        changeScrollback(AppSettings.shared.terminalScrollback)
    }
}

enum Materials {
    static func vibrancy(_ material: NSVisualEffectView.Material,
                         blending: NSVisualEffectView.BlendingMode = .behindWindow) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }
}

// MARK: - 面板表面（2026-10-24 用户指定：右栏会话/文件管理器/脚本底色改透明毛玻璃——
// 面板本体由 RightPaneView 的 vibrancy 材质提供模糊，header/footer 等表面只留发丝线保持透明）

enum Surfaces {
    enum Hairline { case top, bottom }

    /// 透明表面，可选一条发丝分隔线（header 底/footer 顶）
    static func glass(hairline: Hairline? = nil) -> NSView {
        GlassSurfaceView(hairline: hairline)
    }
}

/// 透明表面：无底色（透出 vibrancy 毛玻璃），只画可选的发丝分隔线。
/// 分隔线用 separatorColor 动态色，随黑白主题自动翻转
final class GlassSurfaceView: NSView {
    private let hairlineView = NSView()

    init(hairline: Surfaces.Hairline?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        if let hairline {
            hairlineView.wantsLayer = true
            hairlineView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hairlineView)
            let vertical: [NSLayoutConstraint]
            switch hairline {
            case .top:
                vertical = [hairlineView.topAnchor.constraint(equalTo: topAnchor)]
            case .bottom:
                vertical = [hairlineView.bottomAnchor.constraint(equalTo: bottomAnchor)]
            }
            NSLayoutConstraint.activate(vertical + [
                hairlineView.leadingAnchor.constraint(equalTo: leadingAnchor),
                hairlineView.trailingAnchor.constraint(equalTo: trailingAnchor),
                hairlineView.heightAnchor.constraint(equalToConstant: 1),
            ])
            hairlineView.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        hairlineView.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}

// MARK: - 可拖动分栏（接管 divider 交互）
// macOS 26/27（Liquid Glass）上 NSSplitView 内建 divider 拖动在本工程布局下失效：
// split view 不再创建 divider 子视图，mouseDown 命中后没有拖动行为。
// 这里自行实现 divider 命中 + 事件循环拖动（setPosition）+ 分隔条光标反馈。

final class InteractiveSplitView: NSSplitView {
    private let hitSlop: CGFloat = 4

    private func clampedPosition(_ position: CGFloat, for dividerIndex: Int) -> CGFloat {
        let axis = isVertical ? bounds.width : bounds.height
        var lower: CGFloat = 0
        var upper = axis
        if let delegate = delegate as? NSSplitViewDelegate {
            if let min = delegate.splitView?(self, constrainMinCoordinate: 0, ofSubviewAt: dividerIndex) {
                lower = max(lower, min)
            }
            if let max = delegate.splitView?(self, constrainMaxCoordinate: axis, ofSubviewAt: dividerIndex) {
                upper = min(upper, max)
            }
        }
        return min(max(position, lower), upper)
    }

    private func dividerRect(_ index: Int) -> NSRect {
        guard index < arrangedSubviews.count else { return .zero }
        let leading = arrangedSubviews[index].frame
        let thickness = dividerThickness
        return isVertical
            ? NSRect(x: leading.maxX, y: 0, width: thickness, height: bounds.height)
            : NSRect(x: 0, y: leading.maxY, width: bounds.width, height: thickness)
    }

    private func dividerIndex(at point: NSPoint) -> Int? {
        for index in 0..<max(arrangedSubviews.count - 1, 0) {
            if dividerRect(index).insetBy(dx: -hitSlop, dy: -hitSlop).contains(point) {
                return index
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = dividerIndex(at: point), arrangedSubviews.count > 1 else {
            super.mouseDown(with: event)
            return
        }
        let axis: (NSPoint) -> CGFloat = isVertical ? { $0.x } : { $0.y }
        var lastPoint = axis(point)
        let resizeCursor: NSCursor = isVertical ? .resizeLeftRight : .resizeUpDown
        resizeCursor.push()
        while true {
            guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            if next.type == .leftMouseUp { break }
            let position = axis(convert(next.locationInWindow, from: nil))
            let leading = arrangedSubviews[index]
            let current = axis(leading.frame.origin) + leading.bounds.width
            setPosition(clampedPosition(current + position - lastPoint, for: index),
                        ofDividerAt: index)
            needsLayout = true
            layoutSubtreeIfNeeded()
            display()
            lastPoint = position
        }
        resizeCursor.pop()
    }

    override func resetCursorRects() {
        for index in 0..<max(arrangedSubviews.count - 1, 0) {
            let rect = dividerRect(index).insetBy(dx: -hitSlop, dy: -hitSlop)
            addCursorRect(rect, cursor: isVertical ? .resizeLeftRight : .resizeUpDown)
        }
    }
}

// MARK: - 玻璃图标按钮（macOS 26+ 走 NSGlassEffectView，旧系统退化为半透明圆片）

final class GlassIconButton: NSView {
    let button: NSButton

    init(symbol: String, size: CGFloat = 27, pointSize: CGFloat = 12, tooltip: String? = nil) {
        button = NSButton(title: "", target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.title = ""
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.toolTip = tooltip ?? symbol

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = size / 2
            glass.style = .regular
            glass.contentView = button
            if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
            glass.translatesAutoresizingMaskIntoConstraints = false
            addSubview(glass)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor),
                glass.widthAnchor.constraint(equalToConstant: size),
                glass.heightAnchor.constraint(equalToConstant: size),
            ])
        } else {
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            button.layer?.cornerRadius = size / 2
            addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: leadingAnchor),
                button.trailingAnchor.constraint(equalTo: trailingAnchor),
                button.topAnchor.constraint(equalTo: topAnchor),
                button.bottomAnchor.constraint(equalTo: bottomAnchor),
                widthAnchor.constraint(equalToConstant: size),
                heightAnchor.constraint(equalToConstant: size),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - 玻璃文字按钮（2026-10-24 用户指定：全应用按钮统一玻璃质感）
// 对话框/设置页/传输条的文本按钮统一件：macOS 26+ 走 NSGlassEffectView 胶囊
// （emphasized=accent 玻璃、destructive=红玻璃），旧系统退化为半透明胶囊。
// 结构与 GlassIconButton 同构（按钮直挂玻璃 contentView），内边距烘进
// intrinsicContentSize——不要用额外包装层+低优先级约束（曾在主窗口约束求解时
// 把窗口宽度压瘪成细条，2026-10-24 实测）

/// 玻璃按钮文字层：命中穿透（点击落到下层透明按钮）
private final class GlassButtonLabel: NSTextField {
    convenience init(_ text: String) {
        self.init(labelWithString: text)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class GlassTextButton: NSView {
    /// 点击层（透明铺满，只负责命中/快捷键）；文字由 label 层绘制——
    /// macOS 27 的 NSGlassEffectView 里 NSButton 的 title/attributedTitle 都不渲染
    /// （实测空白胶囊），而 NSTextField 叠在玻璃上层正常（列头文字同证）
    let button: NSButton
    private let label = GlassButtonLabel("")
    private let textPadding: CGFloat

    init(title: String, emphasized: Bool = false, destructive: Bool = false,
         controlSize: NSControl.ControlSize = .regular, tooltip: String? = nil) {
        let height: CGFloat = controlSize == .small ? 22 : 28
        textPadding = controlSize == .small ? 10 : 14
        button = NSButton(title: "", target: nil, action: nil)
        super.init(frame: .zero)

        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.controlSize = controlSize
        button.toolTip = tooltip ?? title
        // 组件统一自管布局：外部（弹窗显式约束/stack）都按约束引用本视图，
        // 不关掉 autoresizing 转换会生成打架约束，按钮被压瘪消失（新建连接弹窗实测）
        translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = title
        label.font = NSFont.systemFont(ofSize: controlSize == .small ? 11 : 13,
                                       weight: emphasized || destructive ? .medium : .regular)
        label.textColor = emphasized || destructive ? .white : .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = height / 2
            glass.style = .regular
            if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
            if destructive { glass.tintColor = .systemRed }
            else if emphasized { glass.tintColor = .controlAccentColor }
            glass.translatesAutoresizingMaskIntoConstraints = false
            addSubview(glass)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor),
                glass.heightAnchor.constraint(equalToConstant: height),
            ])
        } else {
            wantsLayer = true
            layer?.cornerRadius = height / 2
            layer?.backgroundColor = (destructive ? NSColor.systemRed
                : emphasized ? NSColor.controlAccentColor
                : NSColor.labelColor.withAlphaComponent(0.06)).cgColor
            heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        addSubview(button)
        addSubview(label)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 运行中改按钮文字（生成中…/已复制 等瞬时反馈）
    func setText(_ text: String) {
        label.stringValue = text
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: label.fittingSize.width + textPadding * 2, height: 28)
    }
}

// MARK: - 顶栏会话标签（图标 + 标题 + 关闭，选中态强调色填充，参考图 2 风格）

final class TabButton: NSView {
    private let baseTitle: String
    private let symbolName: String
    private let showsClose: Bool
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    /// 底部 3pt 色条（Tabby 口径）：标签颜色标记，nil 隐藏
    private let colorBarView = NSView()
    private var hoverArea: NSTrackingArea?
    private(set) var isOn = false
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    /// 拖拽重排（会话 tab 用）：moved 回传鼠标窗口坐标；两回调都挂上才启用拖拽
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    var colorBar: NSColor? {
        didSet { applyColorBar() }
    }

    init(title: String, symbol: String, isOn: Bool = false, showsClose: Bool = true, height: CGFloat = 30) {
        baseTitle = title
        symbolName = symbol
        self.showsClose = showsClose
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        label.font = NSFont.systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.cell?.wraps = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 250).isActive = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var stackViews: [NSView] = [iconView, label]
        if showsClose {
            closeButton.isBordered = false
            closeButton.setButtonType(.momentaryChange)
            closeButton.title = ""
            closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("关闭标签"))?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))
            closeButton.translatesAutoresizingMaskIntoConstraints = false
            closeButton.toolTip = L("关闭标签")
            closeButton.target = self
            closeButton.action = #selector(closeClicked)
            stackViews.append(closeButton)
        }

        let stack = NSStackView(views: stackViews)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        colorBarView.wantsLayer = true
        colorBarView.layer?.cornerRadius = 1.5
        colorBarView.isHidden = true
        colorBarView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(colorBarView)

        var constraints = [
            heightAnchor.constraint(equalToConstant: height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            colorBarView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            colorBarView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            colorBarView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            colorBarView.heightAnchor.constraint(equalToConstant: 3),
        ]
        if showsClose {
            constraints.append(closeButton.widthAnchor.constraint(equalToConstant: 14))
        }
        NSLayoutConstraint.activate(constraints)
        setOn(isOn)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applyColorBar() {
        colorBarView.isHidden = colorBar == nil
        colorBarView.layer?.backgroundColor = colorBar?.cgColor
    }

    /// 系统动态色的 cgColor 在明暗切换后要重取
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColorBar()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onClose?() // 双击关闭标签（TODO 67）；右侧面板标签未挂 onClose，双击无副作用
            return
        }
        // 拖拽重排：按住后移动超阈值进入拖动循环，松手收尾；未挂回调的固定页签不受影响。
        // ⚠️ 选中动作必须延后到松手：select 会触发 rebuildTabs 在按住期间重建标签栏，
        // 实测会切断本次鼠标事件流（循环收不到任何 dragged/mouseUp，标签拖不动的根因）
        guard onDragMoved != nil, onDragEnded != nil, let window else {
            onSelect?()
            return
        }
        var dragging = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let delta = abs(next.locationInWindow.x - event.locationInWindow.x)
                + abs(next.locationInWindow.y - event.locationInWindow.y)
            if !dragging {
                guard delta > 4 else { continue } // 4pt 内视为单击
                dragging = true
            }
            onDragMoved?(next.locationInWindow)
        }
        if dragging {
            onDragEnded?()
        } else {
            onSelect?()
        }
    }

    /// 右键菜单（会话标签：关闭会话等）；子视图（图标/文字）命中时也统一走这里
    var sessionMenu: NSMenu?

    /// 悬停提示（会话标签：完整标题 + 连接信息两行）。
    /// toolTip 不沿视图树上溯，文字/图标子视图各设一份保证任意位置命中
    func setHoverTooltip(_ text: String?) {
        toolTip = text
        label.toolTip = text
        iconView.toolTip = text
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        event.type == .rightMouseDown ? sessionMenu : super.menu(for: event)
    }

    @objc private func closeClicked() { onClose?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        if !isOn { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor }
    }

    override func mouseExited(with event: NSEvent) {
        if !isOn { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor }
    }

    func setOn(_ on: Bool) {
        isOn = on
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = on
            ? NSColor.controlAccentColor.cgColor
            : NSColor.labelColor.withAlphaComponent(0.05).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = on ? 0.28 : 0
        layer?.shadowRadius = 4
        layer?.shadowOffset = NSSize(width: 0, height: -1)
        let fg = on ? NSColor.white : NSColor.secondaryLabelColor
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        iconView.contentTintColor = fg
        // 段落样式随 attributedStringValue 重设（属性串不带段落样式时会丢截断模式）
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        label.attributedStringValue = NSAttributedString(string: baseTitle, attributes: [
            .foregroundColor: on ? NSColor.white : NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 12, weight: on ? .medium : .regular),
            .paragraphStyle: paragraph,
        ])
        closeButton.contentTintColor = on ? NSColor.white.withAlphaComponent(0.85) : NSColor.tertiaryLabelColor
        CATransaction.commit()
    }
}

// MARK: - 会话树节点

struct Node {
    let title: String
    let detail: String?
    let symbol: String
    let tint: NSColor?
    var children: [Node]
    /// 业务回引："group:<uuid>" / "host:<uuid>"，无业务含义的节点为 nil
    let ref: String?

    var isGroup: Bool { !children.isEmpty }

    init(title: String, detail: String? = nil, symbol: String, tint: NSColor? = nil,
         children: [Node] = [], ref: String? = nil) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.tint = tint
        self.children = children
        self.ref = ref
    }
}

// MARK: - 会话树单元格

final class NodeCellView: NSTableCellView {
    /// 字号跟随设置（默认 13）；detail -1、图标 -2
    static var titleFontSize: CGFloat { CGFloat(AppSettings.shared.sessionListFontSize) }

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: Self.titleFontSize)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.cell?.wraps = false
        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 按渲染同款属性字符串测算完整显示所需宽度（不含表格缩进/展开钮，供会话树横向宽度计算）
    static func contentWidth(node: Node) -> CGFloat {
        let titleSize = titleFontSize
        var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: titleSize)]
        let text = NSMutableAttributedString(string: node.title, attributes: attributes)
        if let detail = node.detail {
            attributes[.font] = NSFont.monospacedDigitSystemFont(ofSize: titleSize - 1, weight: .regular)
            text.append(NSAttributedString(string: "  " + detail, attributes: attributes))
        }
        return ceil(text.size().width) + 14 /*图标*/ + 6 /*间距*/ + 2 /*文本框内边距*/
    }

    func configure(node: Node) {
        let titleSize = Self.titleFontSize
        icon.image = NSImage(systemSymbolName: node.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: titleSize - 2, weight: .regular))
        icon.contentTintColor = node.tint ?? .secondaryLabelColor

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: titleSize),
            .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString(string: node.title, attributes: attributes)
        if let detail = node.detail {
            attributes[.foregroundColor] = NSColor.tertiaryLabelColor
            attributes[.font] = NSFont.monospacedDigitSystemFont(ofSize: titleSize - 1, weight: .regular)
            text.append(NSAttributedString(string: "  " + detail, attributes: attributes))
        }
        label.attributedStringValue = text
    }
}

import AppKit
import SwiftTerm
import PicotermCore

// 设置窗口：数据保存路径（默认 ~/.picoterm，可自定义，恢复默认）
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 620),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L("设置")
        window.minSize = NSSize(width: 560, height: 360)
        window.center()
        self.init(window: window)
        // 模态弹窗口径（2026-10-26 用户指定：弹窗期间后台锁定）：红绿灯关闭 = 结束模态；窗口复用不释放
        window.isReleasedWhenClosed = false
        window.delegate = self
        // 内容装进滚动视图：窗口默认按内容高打开（封顶屏幕 85%），用户调小后内容
        // 可滚动而不是被裁——窗口尺寸与内容约束解耦（约束引擎曾把窗口「纠正」回
        // 最小解导致裁切，见 memory）
        let view = SettingsView(frame: NSRect(x: 0, y: 0, width: 660, height: 600))
        view.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = scroll
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            // 宽度跟随内容区（不横滚）。高度 = 内容高（不挂 ≥ 可视区）：可视区比内容
            // 高出的部分会被约束引擎塞给「最软」的 grid（hugging 吸收），把分组框撑出
            // 几百 pt 空白（终端页实测）——文档矮于可视区时靠 flipped 坐标贴顶显示
            view.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            view.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            view.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        view.layoutSubtreeIfNeeded()
        // fitting 上报值略小于真实渲染（popup 等 bezel 高度差），加固定余量兜底
        let contentHeight = max(360, view.pagesFittingHeight + 66)
        let maxWindowHeight = (window.screen?.visibleFrame.height ?? 900) * 0.85
        window.setContentSize(NSSize(width: 660, height: min(maxWindowHeight, contentHeight)))
        // 内容区高度 required 下界：约束引擎的窗口 frame 求解取「约束最小解」，没有
        // 下界就会在显示周期把窗口缩回最小值（实测缩到 212/45pt 裁切）。minSize/
        // contentMinSize 在约束系统无冲突时正常生效（此前失效是被页面贴底约束的
        // 冲突连带断掉的）；可拖拽调大不受影响
        window.contentMinSize = NSSize(width: 560, height: contentHeight)
        window.minSize = NSSize(width: 560, height: contentHeight + 28)
        window.contentView?.heightAnchor.constraint(greaterThanOrEqualToConstant: contentHeight).isActive = true
    }

    /// 模态打开：期间主窗口等后台窗口收不到任何事件（点不了、关不掉）；红绿灯关闭结束。
    /// 设置页里再开的弹窗（主题选择器等）是嵌套模态，stopModal 只结束最内层
    func activate() {
        guard let window else { return }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard NSApp.modalWindow == nil else { return } // 已在别的模态里（理论上到不了）：只前置不再嵌套
        NSApp.runModal(for: window)
        window.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.stopModal(withCode: .cancel)
        return true
    }
}

final class SettingsView: NSView {
    // flipped 坐标：文档矮于可视区时 NSScrollView 保持顶部对齐（非翻转会被贴底）
    override var isFlipped: Bool { true }

    private let pathLabel = NSTextField(labelWithString: "")
    private let fontSizeValue = NSTextField(labelWithString: "")
    private let scrollbackValue = NSTextField(labelWithString: "")
    /// 终端主题：当前名称 + 调色板图标打开搜索式选择器（内置 5 套 + Tabby 社区配色，下拉装不下）。
    /// 用 GlassIconButton 而非 GlassTextButton：后者放进 NSGridView 会让设置页文档高度退化成 150pt
    /// （页面伸出文档边界、控件可见但 hitTest 点不到），与「GlassTextButton 禁入主窗口」同一类病（2026-10-26 探针实测）
    private let themeNameLabel = NSTextField(labelWithString: "")
    private let themePickButton = GlassIconButton(symbol: "paintpalette", size: 22, pointSize: 11, tooltip: L("选择主题…"))
    private let toolPath = NSTextField(labelWithString: L("系统默认（未配置）"))
    private let toolReset = GlassTextButton(title: L("恢复默认"), controlSize: .small)
    /// 分类导航（侧栏 item 与对应页面，见 select(_: )）
    private var sidebarItems: [SettingsSidebarItem] = []
    private var sidebarPages: [NSView] = []
    /// 语言弹窗下标 → AppLanguage（languageChanged 用）
    private let langValues: [AppLanguage] = [.system, .zh, .en]
    /// 分组内容的高度钉（构建期 fitting，分组容器高度钉兜底，无需挂窗重算）
    private var pinnedContentHeights: [(content: NSView, pin: NSLayoutConstraint)] = []

    /// 三页内容中最高一页的必要高度（供窗口高度取值；页高 = 各分组高度钉闭合，fitting 准确）
    var pagesFittingHeight: CGFloat {
        sidebarPages.map { $0.fittingSize.height }.max() ?? 400
    }

    // MARK: - 布局（2026-10-24 重排：左侧分类导航 + 右侧分组盒子，参考 Finder/WindTerm 设置）

    override init(frame: NSRect) {
        super.init(frame: frame)

        // ---------- 控件构建（action 接线与旧版一致） ----------

        let uiThemePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        uiThemePopup.addItems(withTitles: [L("白色"), L("黑色")])
        uiThemePopup.selectItem(at: AppSettings.shared.interfaceTheme == "black" ? 1 : 0)
        uiThemePopup.target = self
        uiThemePopup.action = #selector(interfaceThemeChanged(_:))
        uiThemePopup.translatesAutoresizingMaskIntoConstraints = false

        // 界面语言（2026-10-26 用户指定：中/英切换；重启后完全生效）
        let langPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        langPopup.addItems(withTitles: [L("跟随系统"), "简体中文", "English"])
        let currentLang = AppLanguage(rawValue: AppSettings.shared.interfaceLanguage) ?? .system
        langPopup.selectItem(at: langValues.firstIndex(of: currentLang) ?? 0)
        langPopup.target = self
        langPopup.action = #selector(languageChanged(_:))
        langPopup.toolTip = L("界面显示语言；切换后重启 Picoterm 完全生效")
        langPopup.translatesAutoresizingMaskIntoConstraints = false

        // 列表字号（2026-10-24 用户指定：会话列表 / 文件管理列表，即改即生效）
        func listFontPopup(_ keyPath: KeyPath<AppSettings, Int>, _ action: Selector) -> NSPopUpButton {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: (10...18).map { "\($0) pt" })
            let current = AppSettings.shared[keyPath: keyPath]
            popup.selectItem(at: max(0, min(popup.numberOfItems - 1, current - 10)))
            popup.target = self
            popup.action = action
            popup.widthAnchor.constraint(equalToConstant: 90).isActive = true
            popup.translatesAutoresizingMaskIntoConstraints = false
            return popup
        }
        let sessionFontPopup = listFontPopup(\.sessionListFontSize, #selector(sessionListFontChanged(_:)))
        let fileFontPopup = listFontPopup(\.fileListFontSize, #selector(fileListFontChanged(_:)))

        let titleLabel = NSTextField(labelWithString: L("文件数据保存路径"))
        titleLabel.font = NSFont.systemFont(ofSize: 13)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.stringValue = AppSettings.shared.dataDirDescription
        pathLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.wantsLayer = true
        pathLabel.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        pathLabel.layer?.cornerRadius = 6

        let hint = NSTextField(labelWithString: L("主机分组与连接配置存为该目录下的 hosts.json；\n密码与私钥口令以 AES-GCM 加密存于 secrets.json（密钥为本机 .secret.key，仅本机可解）。"))
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let sizeTitle = NSTextField(labelWithString: L("终端字号"))
        sizeTitle.font = NSFont.systemFont(ofSize: 13)
        sizeTitle.translatesAutoresizingMaskIntoConstraints = false

        let slider = NSSlider(value: AppSettings.shared.terminalFontSize,
                              minValue: 10, maxValue: 20,
                              target: self, action: #selector(fontSizeChanged(_:)))
        slider.translatesAutoresizingMaskIntoConstraints = false

        fontSizeValue.stringValue = String(format: "%.1f pt", AppSettings.shared.terminalFontSize)
        fontSizeValue.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        fontSizeValue.textColor = .secondaryLabelColor
        fontSizeValue.translatesAutoresizingMaskIntoConstraints = false

        let themeTitle = NSTextField(labelWithString: L("终端主题"))
        themeTitle.font = NSFont.systemFont(ofSize: 13)
        themeTitle.translatesAutoresizingMaskIntoConstraints = false

        themeNameLabel.font = NSFont.systemFont(ofSize: 13)
        themeNameLabel.stringValue = TerminalThemes.theme(id: AppSettings.shared.terminalThemeId).name
        themeNameLabel.lineBreakMode = .byTruncatingTail
        themeNameLabel.translatesAutoresizingMaskIntoConstraints = false
        themePickButton.button.target = self
        themePickButton.button.action = #selector(themePickClicked)

        let linkPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        linkPopup.addItems(withTitles: [L("⌘ + 点击"), L("直接点击")])
        linkPopup.selectItem(at: AppSettings.shared.linkClickRequiresCommand ? 0 : 1)
        linkPopup.target = self
        linkPopup.action = #selector(linkClickChanged(_:))
        linkPopup.translatesAutoresizingMaskIntoConstraints = false
        linkPopup.toolTip = L("终端里 URL 与文件路径的打开方式；悬停时会显示下划线")

        let fontTitle = NSTextField(labelWithString: L("终端字体"))
        fontTitle.font = NSFont.systemFont(ofSize: 13)
        fontTitle.translatesAutoresizingMaskIntoConstraints = false

        let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        var monoFamilies: [String] = []
        for family in NSFontManager.shared.availableFontFamilies {
            if let font = NSFont(name: family, size: 13),
               font.isFixedPitch || family.lowercased().contains("mono") {
                monoFamilies.append(family)
            }
        }
        fontPopup.addItem(withTitle: L("系统等宽（默认）"))
        fontPopup.addItems(withTitles: monoFamilies)
        if AppSettings.shared.terminalFontFamily.isEmpty {
            fontPopup.selectItem(at: 0)
        } else {
            fontPopup.selectItem(withTitle: AppSettings.shared.terminalFontFamily)
        }
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))
        fontPopup.translatesAutoresizingMaskIntoConstraints = false

        let cursorTitle = NSTextField(labelWithString: L("光标样式"))
        cursorTitle.font = NSFont.systemFont(ofSize: 13)
        cursorTitle.translatesAutoresizingMaskIntoConstraints = false

        let cursorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        cursorPopup.addItems(withTitles: [L("方块"), L("下划线"), L("竖线")])
        cursorPopup.selectItem(at: ["block", "underline", "bar"].firstIndex(of: AppSettings.shared.cursorStyle) ?? 0)
        cursorPopup.target = self
        cursorPopup.action = #selector(cursorChanged(_:))
        cursorPopup.translatesAutoresizingMaskIntoConstraints = false

        let charsetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let charsetList = RemoteCharset.allCases
        charsetPopup.addItems(withTitles: charsetList.map(\.displayName))
        charsetPopup.selectItem(at: charsetList.firstIndex(of: AppSettings.shared.sshCharset) ?? 0)
        charsetPopup.target = self
        charsetPopup.action = #selector(charsetChanged(_:))
        charsetPopup.toolTip = L("新建连接的默认字符集；单台主机在「编辑连接」里单独改。远端为 GBK/Big5 等老编码时按所选编码收发文本")
        charsetPopup.translatesAutoresizingMaskIntoConstraints = false

        let scrollbackTitle = NSTextField(labelWithString: L("回滚行数"))
        scrollbackTitle.font = NSFont.systemFont(ofSize: 13)
        scrollbackTitle.translatesAutoresizingMaskIntoConstraints = false

        let scrollbackField = NSTextField(string: "\(AppSettings.shared.terminalScrollback)")
        scrollbackField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        scrollbackField.focusRingType = .none
        scrollbackField.target = self
        scrollbackField.action = #selector(scrollbackSubmitted(_:))
        scrollbackField.toolTip = L("终端可回滚查看的历史行数（100–100000），输入后回车生效，立即对所有会话生效")
        scrollbackField.translatesAutoresizingMaskIntoConstraints = false
        scrollbackValue.stringValue = L("行")
        scrollbackValue.font = NSFont.systemFont(ofSize: 12)
        scrollbackValue.textColor = .secondaryLabelColor
        scrollbackValue.translatesAutoresizingMaskIntoConstraints = false

        let toolTitle = NSTextField(labelWithString: L("文件打开工具"))
        toolTitle.font = NSFont.systemFont(ofSize: 13)
        toolTitle.translatesAutoresizingMaskIntoConstraints = false
        if !AppSettings.shared.fileOpenToolPath.isEmpty {
            toolPath.stringValue = AppSettings.shared.fileOpenToolPath
            toolPath.textColor = .labelColor
        }
        toolPath.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        toolPath.lineBreakMode = .byTruncatingHead
        toolPath.translatesAutoresizingMaskIntoConstraints = false
        let toolChoose = GlassTextButton(title: L("选择…"), controlSize: .small)
        toolChoose.button.target = self
        toolChoose.button.action = #selector(chooseFileTool)
        toolReset.button.target = self
        toolReset.button.action = #selector(resetFileTool)
        toolReset.button.isEnabled = !AppSettings.shared.fileOpenToolPath.isEmpty

        let copyToggle = NSButton(checkboxWithTitle: L("选中即复制"), target: self, action: #selector(copyToggled(_:)))
        copyToggle.state = AppSettings.shared.copyOnSelection ? .on : .off
        let bellToggle = NSButton(checkboxWithTitle: L("响铃提示"), target: self, action: #selector(bellToggled(_:)))
        bellToggle.state = AppSettings.shared.bellEnabled ? .on : .off
        let followToggle = NSButton(checkboxWithTitle: L("文件管理器跟随终端目录"), target: self, action: #selector(followToggled(_:)))
        followToggle.state = AppSettings.shared.syncFileManagerWithTerminal ? .on : .off
        followToggle.toolTip = L("SSH 会话切换目录时，文件管理器自动跟随到该目录（被动解析服务器发出的 OSC 7 / 窗口标题，必要时经 SFTP 连接只读探测；不向服务器注入任何命令）")
        let logHighlightToggle = NSButton(checkboxWithTitle: L("终端日志高亮"), target: self, action: #selector(logHighlightToggled(_:)))
        logHighlightToggle.state = AppSettings.shared.logHighlightEnabled ? .on : .off

        let changeButton = GlassTextButton(title: L("更改…"), controlSize: .small)
        changeButton.button.target = self
        changeButton.button.action = #selector(changeDir)
        let resetButton = GlassTextButton(title: L("恢复默认"), controlSize: .small)
        resetButton.button.target = self
        resetButton.button.action = #selector(resetDir)
        let openButton = GlassTextButton(title: L("打开目录"), controlSize: .small)
        openButton.button.target = self
        openButton.button.action = #selector(openDir)

        // ---------- 分页内容（分组盒子：标题 + 圆角浅底面板，Finder 式层次） ----------
        // 不用 NSBox（标题定位怪异）也不装外层 NSStackView（gravity 分布在多页互斥下不确定），
        // 全部显式约束手排，结构确定。

        func labeled(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = NSFont.systemFont(ofSize: 13)
            return label
        }
        func grid(rows: [[NSView]]) -> NSGridView {
            let grid = NSGridView(views: rows)
            grid.rowSpacing = 12
            grid.columnSpacing = 14
            grid.column(at: 0).xPlacement = .leading
            return grid
        }

        /// 分组：标题在面板上方，内容放圆角浅底面板（labelColor 5%，随黑白主题自适应）
        func section(_ title: String, _ content: NSView) -> NSView {
            content.translatesAutoresizingMaskIntoConstraints = false
            // 内容高度显式钉死：页面首个分组的容器底边无约束引用、存在高度自由度，
            // NSGridView/NSStackView 又不实现 intrinsicContentSize（hugging 无效），
            // 求解器会把多余空间塞给它们（界面主题框被撑出 ~550pt 空白，实测）。
            // fitting 比真实渲染略小（popup/slider bezel 差 ~16pt），差值会让钉值与
            // 内部约束冲突、引擎断链撑大 grid——钉值加 20pt 余量保证 ≥ 真实高度
            content.setContentHuggingPriority(.required, for: .vertical)
            content.setContentCompressionResistancePriority(.required, for: .vertical)
            let pin = content.heightAnchor.constraint(equalToConstant: content.fittingSize.height + 20)
            pin.isActive = true
            pinnedContentHeights.append((content, pin))
            let titleLabel = NSTextField(labelWithString: title)
            titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            titleLabel.textColor = .secondaryLabelColor
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            let surface = NSView()
            surface.wantsLayer = true
            surface.layer?.cornerRadius = 8
            surface.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
            surface.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(content)
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(titleLabel)
            container.addSubview(surface)
            NSLayoutConstraint.activate([
                titleLabel.topAnchor.constraint(equalTo: container.topAnchor),
                titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
                surface.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
                surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                content.topAnchor.constraint(equalTo: surface.topAnchor, constant: 14),
                content.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 14),
                content.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -14),
                // content 高度已被 pin 唯一化 → surface/container 高度随之唯一，
                // 分组框不会再被引擎拉伸（曾撑出几百 pt 空白）
                surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                content.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -14),
            ])
            return container
        }

        /// 页面：分组自上而下手排竖直链，页高 = 内容高
        func makePage(sections: [NSView]) -> NSView {
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            var previous: NSView?
            for sectionView in sections {
                container.addSubview(sectionView)
                NSLayoutConstraint.activate([
                    sectionView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    sectionView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                ])
                if let previous {
                    sectionView.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: 18).isActive = true
                } else {
                    sectionView.topAnchor.constraint(equalTo: container.topAnchor).isActive = true
                }
                previous = sectionView
            }
            if let previous {
                container.bottomAnchor.constraint(equalTo: previous.bottomAnchor).isActive = true
            }
            return container
        }

        // 通用页
        uiThemePopup.widthAnchor.constraint(equalToConstant: 140).isActive = true
        langPopup.widthAnchor.constraint(equalToConstant: 140).isActive = true
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        toolPath.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let pathRow = NSStackView(views: [pathLabel, changeButton, resetButton, openButton])
        pathRow.orientation = .horizontal
        pathRow.spacing = 8
        let pathColumn = NSStackView(views: [pathRow, hint])
        pathColumn.orientation = .vertical
        pathColumn.alignment = .leading
        pathColumn.spacing = 10
        let toolRow = NSStackView(views: [toolPath, toolChoose, toolReset])
        toolRow.orientation = .horizontal
        toolRow.spacing = 8

        // 终端页
        slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        themeNameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 160).isActive = true
        let themeRow = NSStackView(views: [themeNameLabel, themePickButton])
        themeRow.orientation = .horizontal
        themeRow.spacing = 8
        linkPopup.widthAnchor.constraint(equalToConstant: 120).isActive = true
        fontPopup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        cursorPopup.widthAnchor.constraint(equalToConstant: 120).isActive = true
        charsetPopup.widthAnchor.constraint(equalToConstant: 120).isActive = true
        scrollbackField.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let sizeRow = NSStackView(views: [slider, fontSizeValue])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 8
        sizeRow.setContentHuggingPriority(.required, for: .horizontal)
        let scrollbackRow = NSStackView(views: [scrollbackField, scrollbackValue])
        scrollbackRow.orientation = .horizontal
        scrollbackRow.spacing = 6
        scrollbackRow.setContentHuggingPriority(.required, for: .horizontal)

        // 行为页（Finder 式纵向开关清单）
        for toggle in [copyToggle, bellToggle, followToggle, logHighlightToggle] {
            toggle.font = NSFont.systemFont(ofSize: 13)
        }
        let behaviorList = NSStackView(views: [copyToggle, bellToggle, followToggle, logHighlightToggle])
        behaviorList.orientation = .vertical
        behaviorList.alignment = .leading
        behaviorList.spacing = 10

        let generalPage = makePage(sections: [
            section(L("语言"), grid(rows: [[langPopup]])),
            section(L("界面主题"), grid(rows: [[uiThemePopup]])),
            section(L("列表字号"), grid(rows: [
                [labeled(L("会话列表")), sessionFontPopup],
                [labeled(L("文件管理列表")), fileFontPopup],
            ])),
            section(L("文件数据保存路径"), pathColumn),
            section(L("文件打开工具"), toolRow),
        ])
        let terminalPage = makePage(sections: [
            section(L("外观"), grid(rows: [
                [labeled(L("终端字号")), sizeRow],
                [labeled(L("终端主题")), themeRow],
                [labeled(L("终端字体")), fontPopup],
                [labeled(L("光标样式")), cursorPopup],
                [labeled(L("链接点击")), linkPopup],
            ])),
            section(L("缓冲"), grid(rows: [[labeled(L("回滚行数")), scrollbackRow]])),
            section(L("SSH 编码"), grid(rows: [[labeled(L("字符集")), charsetPopup]])),
        ])
        let behaviorPage = makePage(sections: [section(L("行为"), behaviorList)])
        let forwardPage = makePage(sections: [section(L("端口转发（本地 -L，经 SSH 隧道访问远端服务）"), PortForwardSettingsView())])

        // grid 行高锁死：NSPopUpButton 渲染高度与 intrinsic 一致（20），显式 required
        // 防引擎在拉伸布局时把行撑高（grid 高度随之唯一，分组框/页面高度全部稳定）
        func pinPopupHeights(in view: NSView) {
            for sub in view.subviews {
                if let popup = sub as? NSPopUpButton {
                    popup.heightAnchor.constraint(equalToConstant: 20).isActive = true
                } else {
                    pinPopupHeights(in: sub)
                }
            }
        }
        for page in [generalPage, terminalPage, behaviorPage, forwardPage] {
            pinPopupHeights(in: page)
        }

        // ---------- 侧栏 + 内容区 ----------

        let sidebarStack = NSStackView()
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 2
        sidebarStack.edgeInsets = NSEdgeInsets(top: 16, left: 10, bottom: 16, right: 10)
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false

        for (title, _) in [(L("通用"), generalPage), (L("终端"), terminalPage), (L("行为"), behaviorPage), (L("转发"), forwardPage)] {
            let item = SettingsSidebarItem(title: title)
            item.widthAnchor.constraint(equalToConstant: 112).isActive = true
            item.onSelect = { [weak self, weak item] in
                guard let item else { return }
                self?.select(item)
            }
            sidebarStack.addArrangedSubview(item)
            sidebarItems.append(item)
        }

        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor

        let contentArea = NSView()
        contentArea.translatesAutoresizingMaskIntoConstraints = false

        addSubview(sidebarStack)
        addSubview(divider)
        addSubview(contentArea)

        // 四个页面叠放同一区域（隐藏互斥）：宽度随内容区、高度各随内容，贴顶显示。
        // 文档高度必须被页面唯一确定：contentArea.bottom ≥ 每页 bottom + 20（隐藏页同样参与，
        // 文档 = 最高页 + 边距），再用优先级 1 的「高度趋零」把 ≥ 收成等式——此前写成
        // page.bottom ≥ contentArea.bottom（AppKit 约束 y 向下，等于允许页面垂到内容区之下），
        // 文档高度是歧义解，曾恰好解成内容高；2026-10-26 加两行后解成了侧栏高 150pt，
        // 页面伸出文档边界：macOS 14+ 不裁剪子视图所以看得见，但 hitTest 只认边界内 → 控件点不动
        for page in [generalPage, terminalPage, behaviorPage, forwardPage] {
            contentArea.addSubview(page)
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: contentArea.topAnchor, constant: 20),
                page.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor, constant: 20),
                page.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor, constant: -20),
                contentArea.bottomAnchor.constraint(greaterThanOrEqualTo: page.bottomAnchor, constant: 20),
            ])
        }
        let hugHeight = contentArea.heightAnchor.constraint(equalToConstant: 0)
        hugHeight.priority = NSLayoutConstraint.Priority(1)
        hugHeight.isActive = true

        NSLayoutConstraint.activate([
            sidebarStack.topAnchor.constraint(equalTo: topAnchor),
            sidebarStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebarStack.heightAnchor.constraint(equalTo: heightAnchor),
            sidebarStack.widthAnchor.constraint(equalToConstant: 132),

            divider.leadingAnchor.constraint(equalTo: sidebarStack.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            contentArea.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentArea.topAnchor.constraint(equalTo: topAnchor),
            contentArea.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        sidebarPages = [generalPage, terminalPage, behaviorPage, forwardPage]
        select(sidebarItems[0])
    }
    private func select(_ item: SettingsSidebarItem) {
        for (index, entry) in sidebarItems.enumerated() {
            let on = entry === item
            entry.setOn(on)
            guard index < sidebarPages.count else { continue }
            sidebarPages[index].isHidden = !on
        }
        // 切页滚回顶部（内容矮于可视区时无需滚动，高于时避免停在中段看起来「被裁」）
        if let scroll = item.enclosingScrollView {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// 布局探针入口（`--probe-settings-layout`，见 SettingsLayoutProbe）：逐页选中并布局后回调
    func forEachPage(_ body: (String, NSView) -> Void) {
        let titles = [L("通用"), L("终端"), L("行为"), L("转发")]
        for (index, item) in sidebarItems.enumerated() where index < sidebarPages.count {
            select(item)
            layoutSubtreeIfNeeded()
            body(titles[safe: index] ?? "\(index)", sidebarPages[index])
        }
    }

    @objc private func interfaceThemeChanged(_ sender: NSPopUpButton) {
        AppSettings.shared.interfaceTheme = sender.indexOfSelectedItem == 1 ? "black" : "white"
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem < langValues.count else { return }
        AppSettings.shared.interfaceLanguage = langValues[sender.indexOfSelectedItem].rawValue
    }

    // 列表字号：popup 选项 10...18 pt 顺排
    @objc private func sessionListFontChanged(_ sender: NSPopUpButton) {
        AppSettings.shared.sessionListFontSize = sender.indexOfSelectedItem + 10
    }

    @objc private func fileListFontChanged(_ sender: NSPopUpButton) {
        AppSettings.shared.fileListFontSize = sender.indexOfSelectedItem + 10
    }

    @objc private func fontSizeChanged(_ sender: NSSlider) {
        AppSettings.shared.terminalFontSize = sender.doubleValue
        fontSizeValue.stringValue = String(format: "%.1f pt", sender.doubleValue)
        SessionManager.shared.applyAppearanceToAll()
    }

    /// 打开主题选择器（选中即预览，取消回滚）；返回后同步名称
    @objc private func themePickClicked() {
        if let picked = ThemePickerDialog.run(parent: window) {
            AppSettings.shared.terminalThemeId = picked.id
        }
        SessionManager.shared.applyAppearanceToAll()
        themeNameLabel.stringValue = TerminalThemes.theme(id: AppSettings.shared.terminalThemeId).name
    }

    @objc private func linkClickChanged(_ sender: NSPopUpButton) {
        AppSettings.shared.linkClickRequiresCommand = sender.indexOfSelectedItem == 0
        SessionManager.shared.applyAppearanceToAll()
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        AppSettings.shared.terminalFontFamily = sender.indexOfSelectedItem == 0
            ? "" : sender.titleOfSelectedItem ?? ""
        SessionManager.shared.applyAppearanceToAll()
    }

    /// 回滚行数回车提交：非法输入回退现值，合法值钳制 100–100000 后立即刷所有存活终端
    @objc private func scrollbackSubmitted(_ sender: NSTextField) {
        let parsed = Int(sender.stringValue.trimmingCharacters(in: .whitespaces))
        AppSettings.shared.terminalScrollback = parsed ?? AppSettings.shared.terminalScrollback
        sender.stringValue = "\(AppSettings.shared.terminalScrollback)"
        for session in SessionManager.shared.sessions {
            (session.terminalView as? TerminalView)?.applyScrollbackSetting(force: true)
        }
    }

    @objc private func cursorChanged(_ sender: NSPopUpButton) {
        AppSettings.shared.cursorStyle = ["block", "underline", "bar"][max(0, sender.indexOfSelectedItem)]
        SessionManager.shared.applyAppearanceToAll()
    }

    @objc private func charsetChanged(_ sender: NSPopUpButton) {
        let list = RemoteCharset.allCases
        guard sender.indexOfSelectedItem < list.count else { return }
        AppSettings.shared.sshCharset = list[sender.indexOfSelectedItem] // 即改即生效，所有 SSH 会话下一块数据起转码
    }

    @objc private func copyToggled(_ sender: NSButton) {
        AppSettings.shared.copyOnSelection = sender.state == .on
    }

    @objc private func bellToggled(_ sender: NSButton) {
        AppSettings.shared.bellEnabled = sender.state == .on
    }

    @objc private func followToggled(_ sender: NSButton) {
        AppSettings.shared.syncFileManagerWithTerminal = sender.state == .on
    }

    @objc private func logHighlightToggled(_ sender: NSButton) {
        AppSettings.shared.logHighlightEnabled = sender.state == .on
    }

    @objc private func chooseFileTool() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true   // 允许直接选 .app 包
        panel.allowsMultipleSelection = false
        panel.message = L("选择打开文件用的工具（支持 .app 或命令行可执行文件），之后打开任意类型文件都优先用它")
        if !AppSettings.shared.fileOpenToolPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: AppSettings.shared.fileOpenToolPath)
                .deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppSettings.shared.fileOpenToolPath = url.path
        refreshFileToolRow()
    }

    @objc private func resetFileTool() {
        AppSettings.shared.fileOpenToolPath = ""
        refreshFileToolRow()
    }

    private func refreshFileToolRow() {
        let tool = AppSettings.shared.fileOpenToolPath
        toolPath.stringValue = tool.isEmpty ? L("系统默认（未配置）") : tool
        toolPath.textColor = tool.isEmpty ? .tertiaryLabelColor : .labelColor
        toolReset.button.isEnabled = !tool.isEmpty
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refresh() {
        pathLabel.stringValue = AppSettings.shared.dataDirDescription
    }

    @objc private func changeDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = L("选择 Picoterm 数据保存目录（hosts.json 等将存放在此）")
        panel.directoryURL = AppSettings.shared.dataDir
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppSettings.shared.setDataDir(url.path)
        refresh()
    }

    @objc private func resetDir() {
        AppSettings.shared.setDataDir(nil)
        refresh()
    }

    @objc private func openDir() {
        let dir = AppSettings.shared.dataDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}

// MARK: - 设置侧栏条目（分组导航，Finder/WindTerm 风格）

final class SettingsSidebarItem: NSView {
    private let label = NSTextField(labelWithString: "")
    private(set) var isOn = false
    var onSelect: (() -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        label.stringValue = title
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) { onSelect?() }

    func setOn(_ on: Bool) {
        isOn = on
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = on
            ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor
        label.textColor = on ? NSColor.labelColor : NSColor.secondaryLabelColor
        label.font = NSFont.systemFont(ofSize: 13, weight: on ? .medium : .regular)
        CATransaction.commit()
    }
}

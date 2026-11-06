import AppKit
import PicotermCore

// 底部传输进度栏（TODO 52，参考 WindTerm）：窗口最下方（状态栏上方）聚合展示
// 全部会话的文件传输——文件名/方向/主机/字节进度/百分比 + 迷你进度条 + 取消。
// 无传输时整栏隐藏（高度 0）。
final class TransferBarView: NSView {
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    // 「清除已完成」用图标玻璃按钮：主窗口内禁用 GlassTextButton——它放进传输条会
    // 把主窗口宽度压瘪成细条（2026-10-24 实测，机制未明但 100% 复现；弹窗/设置等
    // 独立窗口不受影响），主窗口内一律用 GlassIconButton
    private let clearButton = GlassIconButton(symbol: "trash", size: 22, pointSize: 10,
                                              tooltip: L("清除已完成的传输"))
    private var heightConstraint: NSLayoutConstraint!
    /// 条目视图复用（TODO 73）：进度 0.1s 一刷，不再整栏拆了重建
    private var itemViews: [UUID: TransferItemView] = [:]

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.045).cgColor
        clearButton.button.target = self
        clearButton.button.action = #selector(clearClicked)

        // 顶部分隔线
        let hairline = NSView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(hairline)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8 // 条目间距（2026-10-23 用户指定：10→2 过紧，回调至 8）
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = stack
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(clearButton)

        // 初始 0：启动时无传输，等首个传输事件再撑开（初始化 56 会让空白一直留着）
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightConstraint,
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(lessThanOrEqualTo: clearButton.leadingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            // documentView 约束：stack 钉进 contentView（左对齐、纵向撑满、可横向溢出滚动）
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),

            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
        TransferStore.shared.onChanged = { [weak self] in self?.reload() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func clearClicked() {
        TransferStore.shared.clearFinished()
    }

    private func reload() {
        let tasks = TransferStore.shared.tasks
        isHidden = tasks.isEmpty
        heightConstraint.constant = tasks.isEmpty ? 0 : 70
        clearButton.isHidden = !tasks.contains { $0.state != .running }
        // 已消失的任务移除视图，存活的复用并就地刷新（TODO 73）
        let liveIds = Set(tasks.map(\.id))
        var orderChanged = stack.arrangedSubviews.count != tasks.count
        for (id, view) in itemViews where !liveIds.contains(id) {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
            itemViews.removeValue(forKey: id)
            orderChanged = true
        }
        for task in tasks where itemViews[task.id] == nil {
            itemViews[task.id] = TransferItemView(task: task)
            orderChanged = true
        }
        // arranged 顺序跟随任务列表；新建视图只存表不入栈，统一在这里入栈——
        // remove 前判在栈内（首个任务入列时视图从未进栈，直接 remove 会触发
        // AppKit 断言崩溃，2026-10-23 下载闪退的根因）；顺序没变时整段跳过，
        // 免得每个进度 tick 都全量拆装一遍 arrangedSubviews
        if orderChanged {
            for task in tasks {
                guard let view = itemViews[task.id] else { continue }
                if stack.arrangedSubviews.contains(view) {
                    stack.removeArrangedSubview(view)
                }
                stack.addArrangedSubview(view)
            }
        }
        itemViews.values.forEach { $0.refresh() }
    }
}

/// 单个传输条目：方向图标 + 文件名 + 主机 + 进度文本 + 迷你进度条 + 取消/状态
private final class TransferItemView: NSView {
    // 进度条长度：原 60 按 +50% 放大为 90（2026-10-23 用户指定）
    private static let barLength: CGFloat = 90
    /// 0.1s 一刷新：formatter 与四个状态图标全部静态缓存，tick 内零分配
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
    private static let stateIcons: [TransferTask.State: NSImage] = {
        var map: [TransferTask.State: NSImage] = [:]
        let specs: [(TransferTask.State, String)] = [
            (.running, "xmark.circle.fill"), (.finished, "checkmark.circle.fill"),
            (.failed, "exclamationmark.circle.fill"), (.cancelled, "xmark.circle"),
        ]
        for (state, symbol) in specs {
            map[state] = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        }
        return map
    }()
    private let task: TransferTask
    private let progressLabel = NSTextField(labelWithString: "")
    private let barFill = NSView()
    private let actionButton = NSButton()
    private var barWidth: NSLayoutConstraint!

    init(task: TransferTask) {
        self.task = task
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // 四行布局（2026-10-25 用户指定）：上=用户名@IP；中=图标+文件名；三=进度条+状态按钮；底=字节进度/速度（进度条下方）
        let hostLabel = NSTextField(labelWithString: task.host)
        hostLabel.font = .systemFont(ofSize: 11)
        hostLabel.textColor = .tertiaryLabelColor
        hostLabel.lineBreakMode = .byTruncatingTail
        hostLabel.cell?.truncatesLastVisibleLine = true
        hostLabel.cell?.wraps = false
        hostLabel.translatesAutoresizingMaskIntoConstraints = false
        hostLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 170).isActive = true

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = task.isUpload ? .systemOrange : .systemBlue
        icon.image = NSImage(systemSymbolName: task.isUpload ? "arrow.up.circle" : "arrow.down.circle",
                             accessibilityDescription: task.isUpload ? L("上传") : L("下载"))?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))

        let nameLabel = NSTextField(labelWithString: task.name)
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.cell?.truncatesLastVisibleLine = true
        nameLabel.cell?.wraps = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 170).isActive = true

        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.lineBreakMode = .byTruncatingTail
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        // 进度文本按内容伸缩（条目随之收紧，TODO 80）：传输中数值变长会让条目微幅
        // 变宽，完成后稳定——比定宽 150（条目被撑到 ~270，记录看着隔很远）合适
        progressLabel.setContentHuggingPriority(.required, for: .horizontal)

        let barTrack = NSView()
        barTrack.translatesAutoresizingMaskIntoConstraints = false
        barTrack.wantsLayer = true
        barTrack.layer?.cornerRadius = 2
        barTrack.layer?.backgroundColor = NSColor.separatorColor.cgColor
        barFill.translatesAutoresizingMaskIntoConstraints = false
        barFill.wantsLayer = true
        barFill.layer?.cornerRadius = 2
        barFill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        barTrack.addSubview(barFill)
        // 蓝色 fill = 当前进度：左缘钉死、宽度按百分比增长（此前误用 leading 常量成了「移动」）
        barFill.leadingAnchor.constraint(equalTo: barTrack.leadingAnchor).isActive = true
        barFill.topAnchor.constraint(equalTo: barTrack.topAnchor).isActive = true
        barFill.bottomAnchor.constraint(equalTo: barTrack.bottomAnchor).isActive = true
        barWidth = barFill.widthAnchor.constraint(equalToConstant: 0)
        barWidth.isActive = true

        actionButton.bezelStyle = .regularSquare
        actionButton.isBordered = false
        actionButton.imagePosition = .imageOnly
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.target = self
        actionButton.action = #selector(actionClicked)
        actionButton.toolTip = L("取消传输")

        addSubview(hostLabel)
        addSubview(icon)
        addSubview(nameLabel)
        addSubview(barTrack)
        addSubview(progressLabel)
        addSubview(actionButton)
        NSLayoutConstraint.activate([
            // 上行：用户名@IP
            hostLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            hostLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            hostLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            // 中行：图标 + 文件名
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.topAnchor.constraint(equalTo: hostLabel.bottomAnchor, constant: 2),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            nameLabel.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            // 三行：进度条（90×4）+ 状态按钮紧贴其右
            barTrack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            barTrack.widthAnchor.constraint(equalToConstant: Self.barLength),
            barTrack.heightAnchor.constraint(equalToConstant: 4),
            barTrack.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor),
            actionButton.leadingAnchor.constraint(equalTo: barTrack.trailingAnchor, constant: 2),
            actionButton.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 2),
            actionButton.widthAnchor.constraint(equalToConstant: 18),
            actionButton.heightAnchor.constraint(equalToConstant: 18),
            // 底行：字节进度/速度放进度条下方（左对齐进度条，宽度随内容）
            progressLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            progressLabel.topAnchor.constraint(equalTo: actionButton.bottomAnchor, constant: 2),
            progressLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            bottomAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 2),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func actionClicked() {
        if task.state == .running {
            TransferStore.shared.cancel(task)
        } else {
            TransferStore.shared.remove(task) // 逐条关闭（不自动消失，用户手动关）
        }
    }

    /// 状态/进度刷新（外部按 tick 调用就地更新，TODO 73）
    func refresh() {
        let formatter = Self.byteFormatter
        let state = task.state
        let percent = task.total > 0 ? min(Double(task.done) / Double(task.total), 1) : 0

        switch state {
        case .running:
            let speed = formatter.string(fromByteCount: Int64(task.speed)) + "/s"
            progressLabel.textColor = .secondaryLabelColor
            progressLabel.stringValue = task.total > 0
                ? "\(formatter.string(fromByteCount: Int64(task.done)))/\(formatter.string(fromByteCount: Int64(task.total))) \(Int(percent * 100))% · \(speed)"
                : "\(formatter.string(fromByteCount: Int64(task.done))) · \(speed)"
            barWidth.constant = CGFloat(percent) * Self.barLength
            actionButton.contentTintColor = .secondaryLabelColor
        case .finished:
            progressLabel.stringValue = task.isUpload ? L("已上传") : L("已下载")
            progressLabel.textColor = .systemGreen
            barWidth.constant = Self.barLength
            actionButton.contentTintColor = .systemGreen
        case .failed:
            progressLabel.stringValue = L("失败")
            progressLabel.textColor = .systemRed
            actionButton.contentTintColor = .systemRed
        case .cancelled:
            progressLabel.stringValue = L("已取消")
            progressLabel.textColor = .tertiaryLabelColor
            actionButton.contentTintColor = .tertiaryLabelColor
        }
        if actionButton.image !== Self.stateIcons[state] {
            actionButton.image = Self.stateIcons[state]
        }
        barFill.layer?.backgroundColor = state == .failed
            ? NSColor.systemRed.cgColor : NSColor.controlAccentColor.cgColor
    }
}

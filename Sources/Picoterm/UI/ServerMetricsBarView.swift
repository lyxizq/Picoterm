import AppKit
import PicotermCore

// 服务器状态显示面板（SSH 窗口下方）：CPU/内存/磁盘/Swap 迷你进度条 + 负载 +
// 网络与磁盘读写速率 + 运行时长。数据来自会话的 ServerMetricsPoller（3s 一轮）。
// 非 SSH 会话或采集不可用时整条隐藏（高度 0，对齐传输栏口径）。
final class ServerMetricsBarView: NSView {
    private var heightConstraint: NSLayoutConstraint!
    private var boundSession: SSHSession?
    private let stack = NSStackView()
    /// 显隐变化回调（宿主据此调整终端卡片与状态条的间距）
    var onVisibilityChange: ((Bool) -> Void)?
    /// 最近一次读数：网卡菜单的列表与实时速率来源
    private var latestReading: ServerMetricsReading?
    /// 当前会话的连接标识（user@host:port）：网卡选择按主机持久化的键
    private var identity: String?
    /// 选中的网卡名；nil = 全部网卡合计
    private var selectedNetIf: String? {
        didSet { netCell.setTitle(selectedNetIf.map { L("网络 · %@", $0) } ?? L("网络")) }
    }
    /// 选中的挂载点；nil = 主磁盘（根分区优先）。同时驱动磁盘用量与磁盘读写两列
    private var selectedDisk: String?

    // 8 组指标单元（Swap 缺失时隐藏该列）
    private let cpuCell = MetricCell(title: "CPU", style: .percentWithBar)
    private let memCell = MetricCell(title: L("内存"), style: .percentWithBar)
    private let diskCell = MetricCell(title: L("磁盘"), style: .percentWithBar)
    private let swapCell = MetricCell(title: "Swap", style: .percentWithBar)
    private let loadCell = MetricCell(title: L("负载"), style: .single)
    private let netCell = MetricCell(title: L("网络"),
                                     style: .dual(upPrefix: "↑", upColor: .systemOrange,
                                                  downPrefix: "↓", downColor: .systemBlue))
    private let ioCell = MetricCell(title: L("磁盘读写"),
                                    style: .dual(upPrefix: L("写"), upColor: .systemOrange,
                                                 downPrefix: L("读"), downColor: .systemBlue))
    private let procCell = MetricCell(title: L("进程"), style: .single)
    private let uptimeCell = MetricCell(title: L("运行"), style: .single)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // 与终端卡片同色系但略浮起：更实的底 + 亮边框，避免和上方卡片糊成一片
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.19, alpha: 0.97).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor

        let cells: [MetricCell] = [cpuCell, memCell, diskCell, swapCell, loadCell, netCell, ioCell, procCell, uptimeCell]
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .top
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, cell) in cells.enumerated() {
            cell.showsLeadingHairline = index > 0
            stack.addArrangedSubview(cell)
        }
        netCell.onClick = { [weak self] in self?.showNetIfMenu() }
        netCell.toolTip = L("点击选择网卡")
        diskCell.onClick = { [weak self] in self?.showDiskMenu() }
        diskCell.toolTip = L("点击选择磁盘")
        procCell.onClick = { [weak self] in self?.showProcessMenu() }
        procCell.toolTip = L("点击查看进程 TOP（按 CPU）")
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
        ])

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.isActive = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 换绑数据源（选中会话变化时调用）。传 nil 解绑并隐藏。
    func bind(_ session: SSHSession?) {
        if boundSession !== session {
            boundSession?.onMetricsUpdate = nil
        }
        boundSession = session
        guard let session else {
            identity = nil
            selectedNetIf = nil
            selectedDisk = nil
            latestReading = nil
            setVisible(false)
            return
        }
        // 网卡/磁盘选择按主机恢复（不同主机各自的网卡名与挂载点）
        identity = session.config.connectionIdentity
        selectedNetIf = identity.flatMap {
            UserDefaults.standard.string(forKey: "picoterm.netif." + $0)
        }
        selectedDisk = identity.flatMap {
            UserDefaults.standard.string(forKey: "picoterm.disk." + $0)
        }
        session.onMetricsUpdate = { [weak self, weak session] reading in
            guard let self, session != nil else { return }
            if let reading {
                self.setVisible(true)
                self.apply(reading)
            } else {
                self.setVisible(false) // 采集停止（断开/不可用）
            }
        }
        // 切回已连接的会话时立即显示上次读数
        if let latest = session.latestMetrics {
            setVisible(true)
            apply(latest)
        } else {
            setVisible(false)
        }
    }

    private func setVisible(_ visible: Bool) {
        guard isHidden == visible else { return }
        isHidden = !visible
        heightConstraint.constant = visible ? 58 : 0
        onVisibilityChange?(visible)
    }

    private func apply(_ reading: ServerMetricsReading) {
        latestReading = reading
        if reading.cpuCount > 0 {
            cpuCell.setTitle(L("CPU · %ld核", reading.cpuCount))
        }
        cpuCell.setPercent(reading.cpuFraction)
        if let total = reading.memTotalKB {
            memCell.setTitle(L("内存 · %@", MetricFormat.kilobytes(total)))
        }
        memCell.setPercent(reading.memFraction)
        // 磁盘列：选中挂载点优先（容量标题 + 用量），读写列按同一磁盘的块设备对齐
        let usage = reading.diskUsage(selectedMount: selectedDisk)
        if let usage {
            diskCell.setTitle(L("磁盘 · %@/%@", MetricFormat.kilobytes(usage.usedKB), MetricFormat.kilobytes(usage.totalKB)))
        } else {
            diskCell.setTitle(L("磁盘"))
        }
        diskCell.setPercent(usage?.fraction)
        if reading.swapTotalKB == nil {
            swapCell.isHidden = true
        } else {
            swapCell.isHidden = false
            swapCell.setPercent(reading.swapFraction)
        }
        loadCell.setSingle(reading.load.first.map { String(format: "%.2f", $0) })
        let net = reading.netRates(selected: selectedNetIf)
        netCell.setDual(up: MetricFormat.rate(net.up),
                        down: MetricFormat.rate(net.down))
        let io = reading.diskRates(selectedMount: selectedDisk)
        ioCell.setDual(up: MetricFormat.rate(io.write),
                       down: MetricFormat.rate(io.read))
        procCell.setSingle(reading.processes.map { "\($0)" })
        uptimeCell.setSingle(MetricFormat.uptime(reading.uptimeSeconds))
        toolTip = L("%1$@ · %2$@\n%3$@ · %4$ld 核", reading.hostname, reading.os, reading.kernel, reading.cpuCount)
    }

    // MARK: 进程 TOP 菜单（Termind 监控的进程维度：按 CPU 降序前 10）
    // 样式对齐网卡选择弹层：普通菜单条目 + autoenablesItems=false + 手动启用——
    // 启用态按 labelColor 全色渲染（禁用态会被 AppKit 整体淡化成看不清的浅灰）

    private func showProcessMenu() {
        guard let reading = latestReading else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: L("进程 TOP（按 CPU）"), action: nil, keyEquivalent: "")
        header.isEnabled = true
        menu.addItem(header)
        if reading.topProcesses.isEmpty {
            let empty = NSMenuItem(title: L("（此服务器不支持进程采集）"), action: nil, keyEquivalent: "")
            empty.isEnabled = true
            menu.addItem(empty)
        } else {
            for proc in reading.topProcesses {
                let cpu = proc.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—"
                let mem = proc.memPercent.map { String(format: "%.1f%%", $0) } ?? "—"
                let item = NSMenuItem(title: L("%1$@   PID %2$ld · CPU %3$@ · 内存 %4$@", proc.name, proc.pid, cpu, mem),
                                      action: nil, keyEquivalent: "")
                item.isEnabled = true
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 8, y: procCell.bounds.height - 2), in: procCell)
    }

    // MARK: 网卡选择菜单

    /// 点击网络列弹出网卡清单（按当前速率从高到低排，便于认出哪块在跑流量）
    private func showNetIfMenu() {
        guard let reading = latestReading else { return }
        let menu = NSMenu()
        let all = NSMenuItem(title: L("全部网卡（合计）"), action: #selector(netIfPicked(_:)), keyEquivalent: "")
        all.target = self
        all.state = selectedNetIf == nil ? .on : .off
        menu.addItem(all)
        let rates = reading.netIfRates.sorted {
            (($0.txRate ?? 0) + ($0.rxRate ?? 0)) > (($1.txRate ?? 0) + ($1.rxRate ?? 0))
        }
        for nic in rates {
            let item = NSMenuItem(title: "\(nic.name)   ↑ \(MetricFormat.rate(nic.txRate))  ↓ \(MetricFormat.rate(nic.rxRate))",
                                  action: #selector(netIfPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = nic.name
            item.state = selectedNetIf == nic.name ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 8, y: netCell.bounds.height - 2), in: netCell)
    }

    @objc private func netIfPicked(_ sender: NSMenuItem) {
        selectedNetIf = sender.representedObject as? String
        if let identity {
            // nil 即移除存档（回到合计）
            UserDefaults.standard.set(selectedNetIf, forKey: "picoterm.netif." + identity)
        }
        if let latestReading {
            apply(latestReading) // 立即按新选择刷新显示
        }
    }

    // MARK: 磁盘选择菜单

    /// 点击磁盘列弹出挂载点清单（选中的磁盘同时驱动用量与读写两列）
    private func showDiskMenu() {
        guard let reading = latestReading, !reading.disks.isEmpty else { return }
        let menu = NSMenu()
        let auto = NSMenuItem(title: L("主磁盘（自动）"), action: #selector(diskPicked(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = selectedDisk == nil ? .on : .off
        menu.addItem(auto)
        for disk in reading.disks {
            let item = NSMenuItem(title: "\(disk.mount)   \(MetricFormat.kilobytes(disk.usedKB)) / \(MetricFormat.kilobytes(disk.totalKB))",
                                  action: #selector(diskPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = disk.mount
            item.state = selectedDisk == disk.mount ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 8, y: diskCell.bounds.height - 2), in: diskCell)
    }

    @objc private func diskPicked(_ sender: NSMenuItem) {
        selectedDisk = sender.representedObject as? String
        if let identity {
            UserDefaults.standard.set(selectedDisk, forKey: "picoterm.disk." + identity)
        }
        if let latestReading {
            apply(latestReading)
        }
    }
}

// MARK: - 单列指标单元

private final class MetricCell: NSView {
    enum Style {
        case percentWithBar // 百分比 + 迷你进度条
        case single         // 单行文本
        /// 两行（↑/↓、写/读），前缀着色
        case dual(upPrefix: String, upColor: NSColor, downPrefix: String, downColor: NSColor)
    }

    private static let barLength: CGFloat = 86
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "—")
    private let upLabel = NSTextField(labelWithString: "—")
    private let downLabel = NSTextField(labelWithString: "—")
    private let barTrack = NSView()
    private let barFill = NSView()
    private var barWidth: NSLayoutConstraint!
    private let hairline = NSView()
    private let style: Style
    private var dualPrefixes: (up: String, upColor: NSColor, down: String, downColor: NSColor)?
    /// 整格点击回调（网络列选网卡用）
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if let onClick {
            onClick()
        } else {
            super.mouseDown(with: event)
        }
    }

    init(title: String, style: Style) {
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // 固定浅色文字：状态条是深色表面，不跟随系统外观——亮色系统下
        // labelColor 解析成黑色，落在深底上就看不清了
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        valueLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        var constraints: [NSLayoutConstraint] = [
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ]

        switch style {
        case .percentWithBar:
            barTrack.translatesAutoresizingMaskIntoConstraints = false
            barTrack.wantsLayer = true
            barTrack.layer?.cornerRadius = 2
            barTrack.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
            barFill.translatesAutoresizingMaskIntoConstraints = false
            barFill.wantsLayer = true
            barFill.layer?.cornerRadius = 2
            barFill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            barTrack.addSubview(barFill)
            addSubview(barTrack)
            barWidth = barFill.widthAnchor.constraint(equalToConstant: 0)
            constraints += [
                valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
                valueLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
                barTrack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                barTrack.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 4),
                barTrack.widthAnchor.constraint(equalToConstant: Self.barLength),
                barTrack.heightAnchor.constraint(equalToConstant: 3),
                barFill.leadingAnchor.constraint(equalTo: barTrack.leadingAnchor),
                barFill.topAnchor.constraint(equalTo: barTrack.topAnchor),
                barFill.bottomAnchor.constraint(equalTo: barTrack.bottomAnchor),
                barWidth,
            ]
        case .single:
            constraints += [
                valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
                valueLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            ]
        case .dual(let upPrefix, let upColor, let downPrefix, let downColor):
            dualPrefixes = (upPrefix, upColor, downPrefix, downColor)
            for label in [upLabel, downLabel] {
                label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
                label.textColor = NSColor.white.withAlphaComponent(0.92)
                label.lineBreakMode = .byTruncatingTail
                label.translatesAutoresizingMaskIntoConstraints = false
                addSubview(label)
            }
            setDual(up: "—", down: "—")
            constraints += [
                upLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
                upLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                upLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
                downLabel.topAnchor.constraint(equalTo: upLabel.bottomAnchor, constant: 2),
                downLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                downLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            ]
        }
        // dual 样式用上下两行标签，单值标签不进层级
        if case .dual = style {} else {
            addSubview(valueLabel)
        }

        // 列间分隔线（首列不带）；锚在标题上（所有样式共有、必在层级内）
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        hairline.isHidden = true
        addSubview(hairline)
        constraints += [
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            hairline.widthAnchor.constraint(equalToConstant: 1),
            hairline.heightAnchor.constraint(equalToConstant: 30),
        ]

        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var showsLeadingHairline: Bool {
        get { !hairline.isHidden }
        set { hairline.isHidden = !newValue }
    }

    func setTitle(_ text: String) {
        titleLabel.stringValue = text
    }

    func setPercent(_ fraction: Double?) {
        valueLabel.stringValue = MetricFormat.percent(fraction)
        barWidth.constant = CGFloat(fraction ?? 0) * Self.barLength
        // 高占用警示：≥70% 橙、≥90% 红
        barFill.layer?.backgroundColor = {
            switch fraction {
            case .some(0.9...): NSColor.systemRed.cgColor
            case .some(0.7..<0.9): NSColor.systemOrange.cgColor
            default: NSColor.controlAccentColor.cgColor
            }
        }()
    }

    func setSingle(_ text: String?) {
        valueLabel.stringValue = text ?? "—"
    }

    func setDual(up: String, down: String) {
        guard let p = dualPrefixes else { return }
        upLabel.attributedStringValue = Self.prefixed(p.up, up, color: p.upColor)
        downLabel.attributedStringValue = Self.prefixed(p.down, down, color: p.downColor)
    }

    /// 「↑ 235.1 KB/s」：箭头/前缀着色，数值常规色
    private static func prefixed(_ prefix: String, _ value: String, color: NSColor) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if !prefix.isEmpty {
            text.append(NSAttributedString(string: "\(prefix) ", attributes: [
                .foregroundColor: color,
            ]))
        }
        text.append(NSAttributedString(string: value, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]))
        return text
    }
}

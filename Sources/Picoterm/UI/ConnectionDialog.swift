import AppKit
import PicotermCore

// 新建/编辑连接对话框：自建模态窗口（不用 NSAlert——自带大图标去不掉）
// 表单字段：标签/主机/端口/用户/认证/密钥/密码/分组/终端/字符集/WoL MAC/连接前唤醒；底部 取消/保存
// 编辑时密码框回填已存密码/私钥口令（否则保存会把 secrets.json 里的记录清掉），点眼睛验证身份后可看明文
final class ConnectionDialogView: NSView {
    private let labelField = NSTextField(string: "")
    let hostField = NSTextField(string: "")
    private let portField = NSTextField(string: "22")
    private let userField = NSTextField(string: "root")
    private let authPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let keyField = NSTextField(string: NSString(string: "~/.ssh/id_ed25519").expandingTildeInPath)
    private let secretField = RevealableSecretField()
    private let groupPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let colorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let terminalField = NSTextField(string: "xterm-256color")
    private let charsetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let macField = NSTextField(string: "")
    private let wakeToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    // 协议（Termind 三协议）：ssh | telnet | serial
    private let protoPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let serialDeviceField = NSTextField(string: "")
    private let baudPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// 按协议显隐的行（label, field）

    private static let charsets = RemoteCharset.allCases

    private let keyLabel = rowLabel(L("密钥路径"))
    private let secretLabel = rowLabel(L("密码"))
    private let groups: [HostGroup]
    private let editing: HostEntry?

    static func rowLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13)
        label.alignment = .right
        return label
    }

    init(frame: NSRect, groups: [HostGroup], entry: HostEntry?, defaultGroupId: UUID?, initialSecret: String?) {
        self.groups = groups
        self.editing = entry
        super.init(frame: frame)

        secretField.stringValue = initialSecret ?? ""
        if let entry {
            labelField.stringValue = entry.label
            hostField.stringValue = entry.host
            portField.stringValue = String(entry.proto == "telnet" && entry.port == 23 ? 23 : entry.port)
            userField.stringValue = entry.user
            keyField.stringValue = entry.keyPath
            terminalField.stringValue = entry.terminal
            if let charset = RemoteCharset(hostValue: entry.charset) {
                charsetPopup.selectItem(at: Self.charsets.firstIndex(of: charset) ?? 0)
            }
            macField.stringValue = entry.wolMac
            wakeToggle.state = entry.wakeBeforeConnect ? .on : .off
            authPopup.selectItem(at: ["password", "key", "agent"].firstIndex(of: entry.authKind) ?? 0)
            protoPopup.selectItem(at: ["ssh", "telnet", "serial"].firstIndex(of: entry.proto) ?? 0)
            serialDeviceField.stringValue = entry.serialDevice
            if let index = [9600, 19200, 38400, 57600, 115200, 230400].firstIndex(of: entry.serialBaud) {
                baudPopup.selectItem(at: index)
            }
        }

        hostField.placeholderString = L("[用户@]主机地址")
        secretField.placeholderString = L("密码")

        groupPopup.addItems(withTitles: groups.map(\.name))
        if let entry, let index = groups.firstIndex(where: { $0.id == entry.groupId }) {
            groupPopup.selectItem(at: index)
        } else if let defaultGroupId,
                  let index = groups.firstIndex(where: { $0.id == defaultGroupId }) {
            groupPopup.selectItem(at: index)
        }

        TabColors.populate(colorPopup)
        colorPopup.selectItem(at: TabColors.index(of: entry?.colorTag ?? ""))
        colorPopup.toolTip = L("标签底部色条与会话树图标颜色，用于区分环境（如生产红、测试绿）")

        authPopup.addItems(withTitles: [L("密码"), L("公钥"), "Agent"])
        authPopup.target = self
        authPopup.action = #selector(authChanged)

        protoPopup.addItems(withTitles: ["SSH", "Telnet", L("串口")])
        protoPopup.target = self
        protoPopup.action = #selector(protoChanged)
        protoPopup.toolTip = L("连接协议：SSH 加密远程；Telnet 明文（路由器/老设备控制台）；串口直连本地 /dev/tty.*")

        serialDeviceField.placeholderString = "/dev/tty.usbserial-XXXX"
        serialDeviceField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        serialDeviceField.toolTip = L("串口设备路径，可用 ioreg 或 ls /dev/tty.* 查；USB 转串口通常为 /dev/tty.usbserial-*")
        baudPopup.addItems(withTitles: ["9600", "19200", "38400", "57600", "115200", "230400"].map { L("%ld 波特", $0) })
        baudPopup.selectItem(at: 4) // 默认 115200

        charsetPopup.addItems(withTitles: Self.charsets.map(\.displayName))
        if entry == nil {
            // 新建连接：字符集默认取设置页「SSH 编码」的新建默认值
            charsetPopup.selectItem(at: Self.charsets.firstIndex(of: AppSettings.shared.sshCharset) ?? 0)
        }
        macField.placeholderString = "AA:BB:CC:DD:EE:FF"
        macField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        wakeToggle.title = ""
        wakeToggle.toolTip = L("连接前先向局域网广播 Wake-on-LAN 魔术包唤醒该主机（需在主机 BIOS/网卡开启网络唤醒，并填对 MAC）")

        let rows: [(String, NSView)] = [
            (L("标签"), labelField),
            (L("协议"), protoPopup),
            (L("主机"), hostField),
            (L("端口"), portField),
            (L("用户"), userField),
            (L("认证"), authPopup),
            (L("密钥路径"), keyField),
            (L("密码"), secretField),
            (L("串口设备"), serialDeviceField),
            (L("波特率"), baudPopup),
            (L("分组"), groupPopup),
            (L("颜色"), colorPopup),
            (L("终端"), terminalField),
            (L("字符集"), charsetPopup),
            ("WoL MAC", macField),
            (L("连接前唤醒"), wakeToggle),
        ]

        var y = frame.height - 28
        let fieldX: CGFloat = 92
        let fieldW = frame.width - fieldX - 16
        for (title, field) in rows {
            let label = Self.rowLabel(title)
            label.frame = NSRect(x: 0, y: y + 3, width: 84, height: 20)
            field.frame = NSRect(x: fieldX, y: y, width: fieldW, height: 24)
            addSubview(label)
            addSubview(field)
            allRows.append((label, field))
            y -= 30
        }

        applyAuthVisibility()
        applyProtoVisibility()
    }

    /// 全部表单行（有序）：显隐变化后按可见行紧凑重排，不留空位
    private var allRows: [(label: NSTextField, field: NSView)] = []

    /// 可见行从顶往下重排（行距 30）；隐藏行整行隐藏
    private func relayoutRows() {
        let fieldX: CGFloat = 92
        let fieldW = frame.width - fieldX - 16
        var y = frame.height - 28
        for (label, field) in allRows {
            if field.isHidden {
                label.isHidden = true
                continue
            }
            label.isHidden = false
            label.frame = NSRect(x: 0, y: y + 3, width: 84, height: 20)
            field.frame = NSRect(x: fieldX, y: y, width: fieldW, height: 24)
            y -= 30
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func authChanged() { applyAuthVisibility() }

    // MARK: 协议显隐（SSH：主机/端口/用户/认证；Telnet：主机/端口；串口：设备/波特率）

    @objc private func protoChanged() { applyProtoVisibility() }

    private var selectedProto: String { ["ssh", "telnet", "serial"][max(0, protoPopup.indexOfSelectedItem)] }

    private func applyProtoVisibility() {
        let proto = selectedProto
        // 串口专属行只在 serial 显示
        setRow(serialDeviceField, visible: proto == "serial")
        setRow(baudPopup, visible: proto == "serial")
        // Telnet/串口隐藏 SSH 认证行；Telnet 保留主机/端口
        setRow(userField, visible: proto == "ssh")
        setRow(authPopup, visible: proto == "ssh")
        setRow(keyField, visible: proto == "ssh")
        setRow(secretField, visible: proto == "ssh")
        // 串口无主机/端口
        setRow(hostField, visible: proto != "serial")
        setRow(portField, visible: proto != "serial")
        // 端口默认值随协议切（22/23）
        if proto == "telnet", portField.stringValue == "22" {
            portField.stringValue = "23"
        } else if proto == "ssh", portField.stringValue == "23" {
            portField.stringValue = "22"
        }
        relayoutRows()
    }

    private func setRow(_ field: NSView, visible: Bool) {
        field.isHidden = !visible
    }

    private func applyAuthVisibility() {
        let isKey = authPopup.indexOfSelectedItem == 1
        let isPassword = authPopup.indexOfSelectedItem == 0
        keyField.isEnabled = isKey
        keyLabel.textColor = isKey ? .labelColor : .tertiaryLabelColor
        secretField.isEnabled = isKey || isPassword
        secretField.placeholderString = isKey ? L("私钥口令（无口令可留空）") : L("密码")
        secretField.authReason = isKey ? L("显示已保存的私钥口令") : L("显示已保存的密码")
        secretLabel.stringValue = isKey ? L("私钥口令") : L("密码")
        secretLabel.textColor = (isKey || isPassword) ? .labelColor : .tertiaryLabelColor
    }

    /// 保存结果；表单不合法返回 nil
    func makeResult() -> (entry: HostEntry, secret: String?)? {
        let proto = selectedProto
        let label = labelField.stringValue.trimmingCharacters(in: .whitespaces)

        // 协议分流：串口需要设备路径；SSH/Telnet 需要主机与端口
        if proto == "serial" {
            let device = serialDeviceField.stringValue.trimmingCharacters(in: .whitespaces)
            guard device.hasPrefix("/dev/") else { return nil }
            let baud = [9600, 19200, 38400, 57600, 115200, 230400][max(0, baudPopup.indexOfSelectedItem)]
            var entry = editing ?? HostEntry(groupId: groups.first?.id ?? UUID())
            entry.proto = "serial"
            entry.label = label.isEmpty ? (device as NSString).lastPathComponent : label
            entry.serialDevice = device
            entry.serialBaud = baud
            entry.charset = Self.charsets[safe: charsetPopup.indexOfSelectedItem]?.displayName ?? "UTF-8"
            entry.colorTag = TabColors.presets[safe: colorPopup.indexOfSelectedItem]?.tag ?? ""
            if let group = groups[safe: groupPopup.indexOfSelectedItem] {
                entry.groupId = group.id
            }
            return (entry, nil)
        }

        let rawHost = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !rawHost.isEmpty,
              let port = UInt16(portField.stringValue.trimmingCharacters(in: .whitespaces)), port > 0 else {
            return nil
        }

        // 支持 [用户@]主机 一栏式写法；单独用户栏优先
        var host = rawHost
        var effectiveUser = userField.stringValue.trimmingCharacters(in: .whitespaces)
        if rawHost.contains("@"), let at = rawHost.firstIndex(of: "@") {
            let prefix = String(rawHost[..<at])
            if !prefix.isEmpty { effectiveUser = prefix }
            host = String(rawHost[rawHost.index(after: at)...])
        }

        let authKind = ["password", "key", "agent"][authPopup.indexOfSelectedItem]
        let macText = macField.stringValue.trimmingCharacters(in: .whitespaces).uppercased()
        // 勾了连接前唤醒就必须有合法 MAC，否则留在窗口里改
        if wakeToggle.state == .on, WakeOnLAN.parseMAC(macText) == nil { return nil }
        var entry = editing ?? HostEntry(groupId: groups.first?.id ?? UUID())
        entry.label = label.isEmpty ? host : label
        entry.host = host
        entry.port = port
        entry.user = effectiveUser
        entry.authKind = authKind
        entry.keyPath = isKeySelected ? keyField.stringValue : entry.keyPath
        entry.terminal = terminalField.stringValue
        entry.charset = Self.charsets[safe: charsetPopup.indexOfSelectedItem]?.displayName ?? "UTF-8"
        entry.wolMac = macText
        entry.wakeBeforeConnect = wakeToggle.state == .on && !macText.isEmpty
        entry.proto = proto
        entry.serialDevice = proto == "serial" ? entry.serialDevice : ""
        entry.colorTag = TabColors.presets[safe: colorPopup.indexOfSelectedItem]?.tag ?? ""
        if let group = groups[safe: groupPopup.indexOfSelectedItem] {
            entry.groupId = group.id
        }

        let secret: String?
        if proto == "ssh", isKeySelected || authKind == "password" {
            let value = secretField.stringValue
            secret = value.isEmpty ? nil : value
        } else {
            secret = nil
        }
        return (entry, secret)
    }

    private var isKeySelected: Bool { authPopup.indexOfSelectedItem == 1 }
}

// 自建模态窗口：无图标，标题栏标题 + 表单 + 取消/保存
final class ConnectionDialogWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let dialog: ConnectionDialogView
    private(set) var result: (entry: HostEntry, secret: String?)?

    /// initialSecret：编辑时传入已存密码/私钥口令用于回填；新建传 nil
    init(groups: [HostGroup], entry: HostEntry?, defaultGroupId: UUID?, initialSecret: String? = nil) {
        dialog = ConnectionDialogView(frame: NSRect(x: 0, y: 0, width: 460, height: 456),
                                      groups: groups, entry: entry, defaultGroupId: defaultGroupId,
                                      initialSecret: initialSecret)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = entry == nil ? L("新建连接") : L("编辑连接")
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
        dialog.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(dialog)
        contentView.addSubview(save)
        contentView.addSubview(cancel)
        window.contentView = contentView
        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(equalToConstant: 460),
            contentView.heightAnchor.constraint(equalToConstant: 520),
            dialog.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            dialog.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            dialog.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            save.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            save.topAnchor.constraint(equalTo: dialog.bottomAnchor, constant: 14),
            save.widthAnchor.constraint(equalToConstant: 96),
            cancel.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -10),
            cancel.centerYAnchor.constraint(equalTo: save.centerYAnchor),
            cancel.widthAnchor.constraint(equalToConstant: 96),
            contentView.bottomAnchor.constraint(equalTo: save.bottomAnchor, constant: 14),
        ])
        window.initialFirstResponder = dialog.hostField
    }

    var windowTitle: String { window.title }

    /// 阻塞运行；结束后从 result 取保存结果（nil = 取消）
    func runModal() {
        window.center()
        NSApp.runModal(for: window)
        window.orderOut(nil)
    }

    @objc private func saveClicked() {
        guard let value = dialog.makeResult() else { return } // 表单不合法：留在窗口里改
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

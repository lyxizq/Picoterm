import AppKit
import PicotermCore

// 端口转发设置页（规则清单 + 新建/编辑/启停/删除 + 实时状态）
final class PortForwardSettingsView: NSView {
    private let listStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: L("暂无转发规则。新建一条：本地端口经 SSH 隧道访问远端服务。"))
    private var hostToken: UUID?
    private var forwardToken: UUID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 8
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listStack.addSubview(emptyLabel)

        let add = GlassTextButton(title: L("新建转发…"), controlSize: .small)
        add.button.target = self
        add.button.action = #selector(addClicked)

        let header = NSStackView(views: [add])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(listStack)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            listStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            listStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            listStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        // 规则/主机变化即重建清单
        hostToken = HostStore.shared.observe { [weak self] in self?.rebuild() }
        forwardToken = PortForwardStore.shared.observe { [weak self] in self?.rebuild() }
        PortForwardService.shared.onStateChanged = { [weak self] _, _ in self?.rebuild() }
        rebuild()
    }

    deinit {
        if let hostToken { HostStore.shared.removeObserver(hostToken) }
        if let forwardToken { PortForwardStore.shared.removeObserver(forwardToken) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func rebuild() {
        listStack.arrangedSubviews.forEach { listStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let rules = PortForwardStore.shared.rules
        emptyLabel.isHidden = !rules.isEmpty
        if rules.isEmpty {
            listStack.addArrangedSubview(emptyLabel)
            return
        }
        for rule in rules {
            listStack.addArrangedSubview(makeRow(rule))
        }
    }

    private func makeRow(_ rule: PortForwardRule) -> NSView {
        let toggle = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleClicked(_:)))
        toggle.state = rule.enabled ? .on : .off
        toggle.identifier = NSUserInterfaceItemIdentifier(rule.id.uuidString)
        toggle.toolTip = L("启用 / 停用")

        let title = NSTextField(labelWithString: rule.label.isEmpty
            ? "\(rule.bindPort) → \(rule.targetHost):\(rule.targetPort)"
            : rule.label)
        title.font = .systemFont(ofSize: 12, weight: .medium)

        let detail = NSTextField(labelWithString: rule.summary)
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor

        let state = NSTextField(labelWithString: rule.enabled
            ? PortForwardService.shared.states[rule.id]?.label ?? L("启动中…")
            : L("已停用"))
        state.font = .systemFont(ofSize: 11)
        state.textColor = .secondaryLabelColor
        state.identifier = NSUserInterfaceItemIdentifier("state:" + rule.id.uuidString)

        let edit = GlassTextButton(title: L("编辑"), controlSize: .small)
        edit.button.target = self
        edit.button.action = #selector(editClicked(_:))
        edit.button.identifier = NSUserInterfaceItemIdentifier(rule.id.uuidString)
        let delete = GlassIconButton(symbol: "trash", size: 20, pointSize: 9, tooltip: L("删除"))
        delete.button.target = self
        delete.button.action = #selector(deleteClicked(_:))
        delete.button.identifier = NSUserInterfaceItemIdentifier(rule.id.uuidString)

        let line = NSStackView(views: [toggle, title, detail, state, edit, delete])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 10
        line.translatesAutoresizingMaskIntoConstraints = false
        return line
    }

    // MARK: 动作

    @objc private func addClicked() {
        edit(rule: nil)
    }

    @objc private func editClicked(_ sender: NSButton) {
        guard let id = UUID(uuidString: sender.identifier?.rawValue ?? ""),
              let rule = PortForwardStore.shared.rules.first(where: { $0.id == id }) else { return }
        edit(rule: rule)
    }

    @objc private func toggleClicked(_ sender: NSButton) {
        guard let id = UUID(uuidString: sender.identifier?.rawValue ?? ""),
              let rule = PortForwardStore.shared.rules.first(where: { $0.id == id }) else { return }
        PortForwardStore.shared.setEnabled(sender.state == .on, id: id)
        PortForwardService.shared.applyRules()
    }

    @objc private func deleteClicked(_ sender: NSButton) {
        guard let id = UUID(uuidString: sender.identifier?.rawValue ?? "") else { return }
        PortForwardStore.shared.delete(id: id)
        PortForwardService.shared.applyRules()
    }

    /// 新建/编辑弹窗（主机下拉 + 监听/目标 + 并行连接数）
    private func edit(rule: PortForwardRule?) {
        let hosts = HostStore.shared.hosts
        guard !hosts.isEmpty else {
            _ = PicotermDialog.run(title: L("新建转发"), content: PicotermDialog.message(L("请先在会话面板新建 SSH 主机")),
                                   primaryTitle: L("好"), cancelTitle: L("取消"), parent: window)
            return
        }

        let hostPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        hostPopup.addItems(withTitles: hosts.map { L("%1$@（%2$@）", $0.label, "\($0.user)@\($0.host)") })
        if let rule, let index = hosts.firstIndex(where: { $0.id == rule.hostEntryId }) {
            hostPopup.selectItem(at: index)
        }

        let labelField = NSTextField(string: rule?.label ?? "")
        labelField.placeholderString = L("名称（可空）")
        let bindField = NSTextField(string: rule.map { "\($0.bindHost):\($0.bindPort)" } ?? "127.0.0.1:8080")
        let targetField = NSTextField(string: rule.map { "\($0.targetHost):\($0.targetPort)" } ?? "127.0.0.1:80")
        let parallelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        parallelPopup.addItems(withTitles: (1...6).map { $0 == 1 ? L("1（普通）") : L("%ld（并行提速）", $0) })
        parallelPopup.selectItem(at: min(max((rule?.parallelConnections ?? 1) - 1, 0), 5))
        parallelPopup.toolTip = L("并行 SSH 连接数：多条连接分担转发流量，吞吐随连接数提升（Termind 多连接口径）")

        func row(_ label: String, _ field: NSView, width: CGFloat = 220) -> NSView {
            let text = NSTextField(labelWithString: label)
            text.font = .systemFont(ofSize: 12)
            field.translatesAutoresizingMaskIntoConstraints = false
            if let popup = field as? NSPopUpButton {
                popup.widthAnchor.constraint(equalToConstant: width).isActive = true
            } else if let field = field as? NSTextField {
                field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                field.widthAnchor.constraint(equalToConstant: width).isActive = true
            }
            let line = NSStackView(views: [text, field])
            line.orientation = .horizontal
            line.spacing = 10
            return line
        }

        let form = NSStackView(views: [
            row(L("主机"), hostPopup, width: 240),
            row(L("名称"), labelField),
            row(L("本地监听"), bindField),
            row(L("远端目标"), targetField),
            row(L("连接数"), parallelPopup, width: 140),
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10

        func parseEndpoint(_ text: String) -> (host: String, port: Int)? {
            let parts = text.trimmingCharacters(in: .whitespaces)
                .split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let port = Int(parts[1]), (1...65_535).contains(port),
                  !parts[0].isEmpty else { return nil }
            return (String(parts[0]), port)
        }

        guard PicotermDialog.run(title: rule == nil ? L("新建转发") : L("编辑转发"), content: form,
                                 primaryTitle: L("保存"), contentWidth: 420, parent: window) == .OK,
              let hostIndex = hosts[safe: hostPopup.indexOfSelectedItem].map(\.id),
              let bind = parseEndpoint(bindField.stringValue),
              let target = parseEndpoint(targetField.stringValue) else { return }

        var value = rule ?? PortForwardRule(hostEntryId: hostIndex)
        value.hostEntryId = hostIndex
        value.label = labelField.stringValue.trimmingCharacters(in: .whitespaces)
        value.bindHost = bind.host
        value.bindPort = bind.port
        value.targetHost = target.host
        value.targetPort = target.port
        value.parallelConnections = max(1, min(6, parallelPopup.indexOfSelectedItem + 1))
        guard value.isValid else { return }
        PortForwardStore.shared.upsert(value)
        PortForwardService.shared.applyRules()
    }
}

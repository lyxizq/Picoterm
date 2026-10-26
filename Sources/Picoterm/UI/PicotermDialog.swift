import AppKit
import PicotermCore

// 统一样式弹窗（2026-10-23 用户指定：所有弹窗对齐「编辑连接」样式）
// 居中标题 + 分隔线 + 内容区 + 右下「取消 / 主按钮」；模态运行，
// 主按钮返回 .OK，取消或 Esc 返回 .cancel。替代 NSAlert 的全部场景。
enum PicotermDialog {
    private final class Actions: NSObject, NSWindowDelegate {
        @objc func cancel(_ sender: Any?) { NSApp.stopModal(withCode: .cancel) }
        @objc func primary(_ sender: Any?) { NSApp.stopModal(withCode: .OK) }

        /// 标题栏红绿灯关闭 = 取消（必须 stopModal，否则模态循环卡死）
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            NSApp.stopModal(withCode: .cancel)
            return true
        }
    }
    private static let actions = Actions()

    /// 弹窗窗口：没有取消按钮的信息框也要能用 Esc 关掉（按钮的 keyEquivalent 只能挂一个键）
    private final class DialogWindow: NSWindow {
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { // Esc
                NSApp.stopModal(withCode: .cancel)
                return
            }
            super.keyDown(with: event)
        }

        override func cancelOperation(_ sender: Any?) {
            NSApp.stopModal(withCode: .cancel)
        }
    }

    /// 单按钮信息框（错误/提示）：只有「好」，Esc / 红绿灯同样关闭
    @discardableResult
    static func info(title: String, _ text: String, parent: NSWindow? = nil) -> NSApplication.ModalResponse {
        run(title: title, content: message(text), primaryTitle: L("好"), cancelTitle: nil, parent: parent)
    }

    /// 纯文本内容视图（自动换行）
    static func message(_ text: String, width: CGFloat = 340) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    /// cancelTitle 传 nil = 不要取消按钮（信息框 / 预览），Esc 仍返回 .cancel
    @discardableResult
    static func run(title: String,
                    content: NSView,
                    primaryTitle: String = L("确定"),
                    cancelTitle: String? = L("取消"),
                    destructive: Bool = false,
                    contentWidth: CGFloat = 380,
                    parent: NSWindow? = nil) -> NSApplication.ModalResponse {
        content.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let hairline = NSBox()
        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false

        var buttonViews: [NSView] = []
        if let cancelTitle {
            let cancelButton = GlassTextButton(title: cancelTitle)
            cancelButton.button.target = actions
            cancelButton.button.action = #selector(Actions.cancel(_:))
            cancelButton.button.keyEquivalent = "\u{1b}"
            buttonViews.append(cancelButton)
        }

        let primaryButton = GlassTextButton(title: primaryTitle,
                                            emphasized: !destructive, destructive: destructive)
        primaryButton.button.target = actions
        primaryButton.button.action = #selector(Actions.primary(_:))
        primaryButton.button.keyEquivalent = "\r"
        buttonViews.append(primaryButton)

        let buttons = NSStackView(views: buttonViews)
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(titleLabel)
        container.addSubview(hairline)
        container.addSubview(content)
        container.addSubview(buttons)
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            hairline.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            hairline.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: hairline.bottomAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(lessThanOrEqualTo: buttons.topAnchor, constant: -18),
            buttons.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 18),
            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])

        let window = DialogWindow(contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: 160),
                                  styleMask: [.titled, .closable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = title
        window.delegate = actions
        window.contentView = container

        // 按内容实测高度定窗口
        container.layoutSubtreeIfNeeded()
        let needed = max(150, container.fittingSize.height)
        window.setContentSize(NSSize(width: contentWidth, height: needed))
        if let parent {
            window.setFrameOrigin(NSPoint(x: parent.frame.midX - contentWidth / 2,
                                          y: parent.frame.midY - needed / 2))
        } else {
            window.center()
        }
        let response = NSApp.runModal(for: window)
        window.orderOut(nil)
        return response
    }
}

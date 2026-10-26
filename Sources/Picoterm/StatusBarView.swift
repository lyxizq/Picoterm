import AppKit
import PicotermCore

// 底部状态栏：连接状态 / 模式 / 窗口尺寸 / 编码。
// 全部真实数据——模式与会话类型联动、尺寸经 terminalSizeChanged 实时刷新、
// 编码取主机配置（本地 Shell 恒 UTF-8）；无会话时中段隐藏。
final class StatusBarView: NSVisualEffectView {
    private let statusDot = NSView()
    private let sessionLabel = NSTextField(labelWithString: L("无活动会话"))
    private let modeChip = NSTextField(labelWithString: L("本地 Shell"))
    private let sizeChip = NSTextField(labelWithString: "")
    private let charsetChip = NSTextField(labelWithString: "UTF-8")
    private var middle: NSStackView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .titlebar
        blendingMode = .behindWindow
        state = .active
        translatesAutoresizingMaskIntoConstraints = false

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
        statusDot.layer?.cornerRadius = 3.5
        statusDot.layer?.masksToBounds = false

        sessionLabel.font = NSFont.systemFont(ofSize: 11)
        sessionLabel.textColor = .secondaryLabelColor
        sessionLabel.translatesAutoresizingMaskIntoConstraints = false

        func chip(_ title: String, monospaced: Bool = false) -> NSTextField {
            let label = NSTextField(labelWithString: title)
            label.font = monospaced
                ? NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                : NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            return label
        }

        let left = NSStackView(views: [statusDot, sessionLabel])
        left.orientation = .horizontal
        left.alignment = .centerY
        left.spacing = 6
        left.translatesAutoresizingMaskIntoConstraints = false

        sizeChip.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeChip.textColor = .secondaryLabelColor
        sizeChip.translatesAutoresizingMaskIntoConstraints = false
        modeChip.font = NSFont.systemFont(ofSize: 11)
        modeChip.textColor = .secondaryLabelColor
        modeChip.translatesAutoresizingMaskIntoConstraints = false
        charsetChip.font = NSFont.systemFont(ofSize: 11)
        charsetChip.textColor = .secondaryLabelColor
        charsetChip.translatesAutoresizingMaskIntoConstraints = false

        let middle = NSStackView(views: [modeChip, sizeChip, charsetChip])
        middle.orientation = .horizontal
        middle.alignment = .centerY
        middle.spacing = 14
        middle.translatesAutoresizingMaskIntoConstraints = false
        middle.isHidden = true
        addSubview(middle)
        self.middle = middle

        addSubview(left)

        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),

            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),

            middle.centerXAnchor.constraint(equalTo: centerXAnchor),
            middle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // 终端尺寸实时刷新（选中会话的尺寸变化才更新 chip）
        NotificationCenter.default.addObserver(forName: .terminalSizeChanged,
                                               object: nil, queue: .main) { [weak self] note in
            guard let self, let session = note.object as? TerminalSession,
                  session.id == SessionManager.shared.selected?.id else { return }
            self.applySize(session)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 状态栏左侧 + 中段跟随选中会话
    func update(session: TerminalSession?) {
        guard let session else {
            sessionLabel.stringValue = L("无活动会话")
            statusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
            middle?.isHidden = true
            return
        }
        let title = SessionManager.shared.displayTitle(for: session)
        sessionLabel.stringValue = session.state == .exited ? L("%@ · 已退出", title) : title
        statusDot.layer?.backgroundColor = (session.state == .running
            ? NSColor.systemGreen
            : NSColor.systemRed).cgColor
        modeChip.stringValue = session is SSHSession ? L("SSH 远程") : L("本地 Shell")
        charsetChip.stringValue = (session as? SSHSession)?.config.charset.displayName ?? "UTF-8"
        applySize(session)
        middle?.isHidden = false
    }

    private func applySize(_ session: TerminalSession) {
        guard let size = session.terminalSize else {
            sizeChip.stringValue = ""
            return
        }
        sizeChip.stringValue = L("窗口 %ld×%ld", size.cols, size.rows)
    }
}

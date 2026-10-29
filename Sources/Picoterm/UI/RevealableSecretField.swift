import AppKit
import LocalAuthentication
import PicotermCore

/// 可回显的密码框（2026-10-26 用户指定）：默认遮蔽，右侧玻璃小眼睛；点眼睛先过本机
/// 身份验证（Touch ID / Apple Watch / Mac 登录密码），通过后切明文，再点即恢复遮蔽（免验证）。
/// 内部叠放 NSSecureTextField 与 NSTextField 共用同一字符串——AppKit 的安全框没有
/// 「切明文」开关，只能两框互换；对外只暴露 stringValue / placeholderString / isEnabled。
/// 连接编辑、连接补录密码、MFA 质询三处密码框统一用它。
final class RevealableSecretField: NSView {
    private let secureField = NSSecureTextField(string: "")
    private let plainField = NSTextField(string: "")
    private let eye: GlassIconButton
    private(set) var isRevealed = false
    private var authenticating = false

    /// 身份验证弹窗上显示的事由
    var authReason = L("显示密码")
    /// 为 false 时点眼睛直接明暗切换、不做身份验证
    let gated: Bool

    private static let eyeSize: CGFloat = 22
    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)

    init(gated: Bool = true) {
        self.gated = gated
        eye = GlassIconButton(symbol: "eye", size: Self.eyeSize, pointSize: 11, tooltip: L("显示密码"))
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 24))

        for field in [secureField, plainField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.usesSingleLineMode = true
            field.cell?.isScrollable = true
            field.cell?.wraps = false
            field.delegate = self
            addSubview(field)
        }
        plainField.isHidden = true
        addSubview(eye)
        eye.button.target = self
        eye.button.action = #selector(eyeClicked)
        eye.button.setAccessibilityLabel(L("显示密码"))

        var constraints: [NSLayoutConstraint] = [
            eye.trailingAnchor.constraint(equalTo: trailingAnchor),
            eye.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        for field in [secureField, plainField] {
            constraints += [
                field.leadingAnchor.constraint(equalTo: leadingAnchor),
                field.trailingAnchor.constraint(equalTo: eye.leadingAnchor, constant: -6),
                field.topAnchor.constraint(equalTo: topAnchor),
                field.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: 300, height: 24) }

    private var activeField: NSTextField { isRevealed ? plainField : secureField }

    var stringValue: String {
        get { activeField.stringValue }
        set {
            secureField.stringValue = newValue
            plainField.stringValue = newValue
        }
    }

    var placeholderString: String? {
        get { secureField.placeholderString }
        set {
            secureField.placeholderString = newValue
            plainField.placeholderString = newValue
        }
    }

    var isEnabled: Bool {
        get { secureField.isEnabled }
        set {
            secureField.isEnabled = newValue
            plainField.isEnabled = newValue
            eye.button.isEnabled = newValue
            eye.alphaValue = newValue ? 1 : 0.4
        }
    }

    // MARK: 明暗切换

    @objc private func eyeClicked() {
        if isRevealed {
            setRevealed(false)
            return
        }
        guard !authenticating else { return }
        guard gated else {
            setRevealed(true)
            return
        }
        authenticating = true
        Self.authenticateOwner(reason: authReason) { [weak self] ok in
            guard let self else { return }
            self.authenticating = false
            if ok { self.setRevealed(true) }
        }
    }

    private func setRevealed(_ reveal: Bool) {
        guard reveal != isRevealed else { return }
        let from = reveal ? secureField : plainField
        let to = reveal ? plainField : secureField
        // 正在编辑时把焦点与光标一并搬到新框，用户感觉只是字符换了显示方式
        let hadFocus = from.currentEditor() != nil
        let selection = from.currentEditor()?.selectedRange
        to.stringValue = from.stringValue
        isRevealed = reveal
        from.isHidden = true
        to.isHidden = false
        let symbol = reveal ? "eye.slash" : "eye"
        let title = reveal ? L("隐藏密码") : L("显示密码")
        eye.button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(Self.symbolConfig)
        eye.button.toolTip = title
        eye.button.setAccessibilityLabel(title)
        if hadFocus {
            window?.makeFirstResponder(to)
            if let selection, let editor = to.currentEditor() as? NSTextView {
                editor.setSelectedRange(selection)
            }
        }
    }

    // MARK: 本机身份验证

    /// Touch ID / Apple Watch / Mac 登录密码任一通过即放行；本机没有可核验的身份（账户未设密码）时直接放行。
    /// LAContext 的 reply 跑在框架内部队列（非主队列），回主线程必须用 RunLoop.perform(inModes:)：
    /// NSApp.runModal 是嵌套运行循环，不排空 GCD 主队列（2026-10-26 实测），main.async 会卡到弹窗关闭。
    static func authenticateOwner(reason: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        context.localizedCancelTitle = L("取消")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(true)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            RunLoop.main.perform(inModes: [.modalPanel, .default, .eventTracking]) {
                completion(ok)
            }
        }
    }
}

// 明文框走窗口共享的 field editor，关掉智能引号/破折号/替换/纠错——密码里的 "、-- 不能被替换
extension RevealableSecretField: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let editor = obj.userInfo?["NSFieldEditor"] as? NSTextView else { return }
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
    }
}

/// 质询弹窗里回显（NSTextField）/不回显（RevealableSecretField）两种输入框的统一取值口
protocol StringPromptField: AnyObject {
    var stringValue: String { get }
}

extension NSTextField: StringPromptField {}
extension RevealableSecretField: StringPromptField {}

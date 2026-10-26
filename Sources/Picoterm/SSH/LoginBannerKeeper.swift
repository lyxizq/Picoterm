// 登录横幅保留器（TODO 66，参考 WindTerm 登录信息驻留）：SSH 登录后立即收到的
// Last login / motd 属于登录信息，用户执行 clear 或重置屏后重新回插，不随清屏消失。
// - 横幅 = 首次用户输入（或 OSC 7 钩子注入）之前收到的全部输出，去掉尾部不完整行
//   （登录提示符），之后冻结定型；
// - 未冻结期间遇到清屏序列视为服务器自己清屏（登录脚本 clear）：清空已捕获内容，
//   被服务器主动清掉的输出不再算登录信息；
// - 仅主屏幕回插：vim/less/htop 等进入 alternate screen 的应用内部清屏不插横幅，
//   避免打乱 TUI 光标坐标；
// - 仅 SSH 会话接入（本地 shell 无 motd）；主线程使用。
@MainActor
final class LoginBannerKeeper {
    private var capture: [UInt8] = []
    private var frozen = false
    private var altscreen = false
    /// 跨 chunk 的未完转义序列（留待下一 chunk 拼上再判）
    private var carry: [UInt8] = []

    /// 首次用户输入/内部注入后调用：横幅定型（幂等）
    func freezeOnFirstInput() {
        guard !frozen else { return }
        frozen = true
        // 尾部不完整行是登录后的第一段提示符，回插时会与 shell 新提示符叠成两份，截掉
        if let newline = capture.lastIndex(of: UInt8(ascii: "\n")) {
            capture.removeSubrange(capture.index(after: newline)...)
        } else {
            capture = []
        }
    }

    /// 处理一段远端输出（已过日志高亮管道），返回应喂给终端的字节；
    /// 遇清屏序列先喂清屏、再回插横幅（顺序不能反，否则横幅立刻被清掉）
    func process(_ bytes: [UInt8]) -> [UInt8] {
        // 快速路径（TODO 73）：横幅已冻结且为空（无内容可回插）时整段直通，免逐字节扫描
        if frozen, capture.isEmpty, carry.isEmpty { return bytes }
        let stream = carry + bytes
        carry = []
        var out = [UInt8]()
        out.reserveCapacity(stream.count + capture.count)
        var i = 0
        while i < stream.count {
            if stream[i] == 0x1B {
                guard let len = Self.sequenceLength(stream, i) else {
                    carry = Array(stream[i...])
                    if carry.count > 4096 {
                        // 异常流兜底：超长未终止序列按普通字节放行，防无限滞留
                        if !frozen { capture.append(contentsOf: carry) }
                        out.append(contentsOf: carry)
                        carry = []
                    }
                    break
                }
                let seq = stream[i..<i + len]
                if Self.isClearScreen(seq) {
                    out.append(contentsOf: seq)
                    if frozen {
                        if !altscreen, !capture.isEmpty {
                            out.append(contentsOf: capture) // 清屏后回插登录横幅
                        }
                    } else {
                        capture = [] // 服务器自己清的屏：此前输出不再算登录信息
                    }
                } else {
                    if !frozen { capture.append(contentsOf: seq) }
                    Self.updateAltscreen(seq, &altscreen)
                    out.append(contentsOf: seq)
                }
                i += len
                continue
            }
            if !frozen { capture.append(stream[i]) }
            out.append(stream[i])
            i += 1
        }
        return out
    }

    /// ESC 起始序列的长度；被 chunk 截断（不完整）返回 nil。始终保证前进，
    /// 非法序列按最短长度跳过
    private static func sequenceLength(_ s: [UInt8], _ i: Int) -> Int? {
        guard i + 1 < s.count else { return nil }
        switch s[i + 1] {
        case 0x5B: // CSI：ESC [ 参数(0x30–3F) 中间(0x20–2F) final(0x40–7E)；非法 final 也按已结束跳过
            var j = i + 2
            while j < s.count && (0x20...0x3F).contains(s[j]) { j += 1 }
            guard j < s.count else { return nil }
            return j - i + 1
        case 0x5D: // OSC：ESC ] … BEL 或 ESC \（ST）
            var j = i + 2
            while j < s.count {
                if s[j] == 0x07 { return j - i + 1 }
                if s[j] == 0x1B { return j + 1 < s.count ? j - i + 2 : nil }
                j += 1
            }
            return nil
        default: // 其余：ESC + 中间字节(0x20–2F)* + final(0x30–7E)，如 RIS \ec、字符集 \e(B
            var j = i + 1
            while j < s.count && (0x20...0x2F).contains(s[j]) { j += 1 }
            guard j < s.count else { return nil }
            return (0x30...0x7E).contains(s[j]) ? j - i + 1 : 1
        }
    }

    /// 清屏判定：CSI …J（参数空/0/2，即 \e[J、\e[0J、\e[2J）或 RIS（\ec）；
    /// \e[3J 只清回滚缓冲不动屏幕、\e[?J 是选择性擦除，都不触发
    private static func isClearScreen(_ seq: ArraySlice<UInt8>) -> Bool {
        let a = Array(seq)
        if a.count == 2, a[0] == 0x1B, a[1] == UInt8(ascii: "c") { return true }
        guard a.count >= 3, a[0] == 0x1B, a[1] == 0x5B, a.last == UInt8(ascii: "J") else { return false }
        let params = String(bytes: a[2..<(a.count - 1)], encoding: .ascii) ?? "?"
        return params.isEmpty || params == "0" || params == "2"
    }

    /// 跟踪 alternate screen 进出（\e[?1049h/l、\e[?47h/l、\e[?1047h/l）
    private static func updateAltscreen(_ seq: ArraySlice<UInt8>, _ altscreen: inout Bool) {
        let a = Array(seq)
        guard a.count >= 3, a[0] == 0x1B, a[1] == 0x5B,
              let last = a.last, last == UInt8(ascii: "h") || last == UInt8(ascii: "l") else { return }
        let params = String(bytes: a[2..<(a.count - 1)], encoding: .ascii) ?? ""
        guard params.hasPrefix("?"), params.contains("1049") || params.contains("47") else { return }
        altscreen = last == UInt8(ascii: "h")
    }
}

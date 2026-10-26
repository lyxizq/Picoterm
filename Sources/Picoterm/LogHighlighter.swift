import Foundation

// 终端日志高亮（对标 WindTerm 客户端侧关键字着色，TODO 49）：
// SSH 输出多为纯文本日志（tailf 等），服务器不发任何颜色；本组件在字节流喂进
// SwiftTerm 前对「纯文本段」按规则注入 SGR 颜色，已有转义序列（服务器自己的
// 彩色 PS1/ls 颜色、OSC 7 等）原样透传不受影响。
//
// 结构：LogHighlightPipe 负责按行缓冲（跨 chunk 拼行；尾行无换行时挂起，由
// 调用方空闲兜底 flush，避免 shell 提示符延迟显示）与逐行处理；
// highlight(line:) 负责行内转义序列扫描 + 纯文本段正则着色。
enum LogHighlighter {
    static let esc = UInt8(0x1b)
    private static let newline = UInt8(0x0a)

    // MARK: 着色规则（顺序即应用顺序；方括号 token 先于 IP/URL，避免长 bracket 串被二次套色）
    // 所有模式都工作在无 ESC 的纯文本段上；带自由字符类的仍显式排除 ESC 兜底。
    private static let rules: [(regex: NSRegularExpression, sgr: String)] = [
        // 时间戳：2026-10-22 20:19:45,943 / 2026-10-22T20:19:45 → 青
        (try! NSRegularExpression(pattern: "\\b\\d{4}-\\d{2}-\\d{2}[ T]\\d{2}:\\d{2}:\\d{2}(?:[.,]\\d{1,9})?\\b"), "36"),
        // 方括号结构 token（含 : 或 =，如 [myid:1]、[Thread-756:NIOServerCxn@821]；不碰 [root@host] 提示符）→ 绿
        (try! NSRegularExpression(pattern: "\\[[^\\[\\]\\n\\x{1b}]*[:=][^\\[\\]\\n\\x{1b}]*\\]"), "32"),
        // 日志级别 → INFO 蓝 / WARN 黄 / ERROR·FATAL 红 / DEBUG·TRACE 灰 / NOTICE 青
        (try! NSRegularExpression(pattern: "\\b(?:ERROR|ERR|FATAL|CRITICAL)\\b"), "1;31"),
        (try! NSRegularExpression(pattern: "\\b(?:WARN|WARNING)\\b"), "33"),
        (try! NSRegularExpression(pattern: "\\bINFO\\b"), "34"),
        (try! NSRegularExpression(pattern: "\\b(?:DEBUG|TRACE)\\b"), "90"),
        (try! NSRegularExpression(pattern: "\\bNOTICE\\b"), "36"),
        // IPv4（含可选 :端口，如 205.210.31.111:63840）→ 品红下划线
        (try! NSRegularExpression(pattern: "\\b(?:\\d{1,3}\\.){3}\\d{1,3}(?::\\d{1,5})?\\b"), "4;35"),
        // URL → 蓝下划线
        (try! NSRegularExpression(pattern: "\\bhttps?://[^\\s\\x{1b}\\]]+"), "4;34"),
    ]

    private static let maxHighlightRunLength = 8192

    /// 对一行（不含换行符）的纯文本段套色；escape 段原样保留。
    /// 行内已生效的服务器 SGR 会记入 lastSGR，注入颜色后恢复，不破坏后续原色。
    static func highlight(line: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(line.count + 32)
        var lastSGR = ""
        var runStart = 0
        var i = 0
        func flushRun(_ end: Int) {
            guard end > runStart else { return }
            let run = Array(line[runStart..<end])
            // 非 UTF-8（二进制/截断多字节）不强转，原样透传避免字节损坏
            if let text = String(bytes: run, encoding: .utf8), text.count <= maxHighlightRunLength {
                out.append(contentsOf: Array(colorize(text, restoreSGR: lastSGR.isEmpty ? "0" : lastSGR).utf8))
            } else {
                out.append(contentsOf: run)
            }
        }
        while i < line.count {
            guard line[i] == esc else { i += 1; continue }
            let seqLen = escapeSequenceLength(line, from: i)
            // 末尾悬挂的不完整转义序列并入前段文本透传（调用方按行切分后理论不出现，兜底）
            guard seqLen > 0, i + seqLen <= line.count else { break }
            flushRun(i)
            let seq = Array(line[i..<i + seqLen])
            out.append(contentsOf: seq)
            rememberSGR(seq, into: &lastSGR)
            i += seqLen
            runStart = i
        }
        flushRun(line.count)
        return out
    }

    /// 识别 ESC 序列长度；不完整/不认识返回 0
    static func escapeSequenceLength(_ bytes: [UInt8], from: Int) -> Int {
        guard from < bytes.count, bytes[from] == esc, from + 1 < bytes.count else { return 0 }
        switch bytes[from + 1] {
        case UInt8(ascii: "["): // CSI：参数/中间字节后遇 0x40–0x7E 终止
            var i = from + 2
            while i < bytes.count {
                if (0x40...0x7E).contains(bytes[i]) { return i - from + 1 }
                if !(0x20...0x3F).contains(bytes[i]) { return 0 }
                i += 1
            }
            return 0
        case UInt8(ascii: "]"): // OSC：BEL 或 ESC \ 终止
            var i = from + 2
            while i < bytes.count {
                if bytes[i] == 0x07 { return i - from + 1 }
                if bytes[i] == esc, i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "\\") {
                    return i - from + 2
                }
                i += 1
            }
            return 0
        default: // 两字节转义（ESC ( B、ESC 7 等）
            return 2
        }
    }

    /// SGR（CSI … m）参数记入 lastSGR，供注入颜色后恢复现场；reset 归空
    private static func rememberSGR(_ seq: [UInt8], into lastSGR: inout String) {
        guard seq.count >= 3, seq[1] == UInt8(ascii: "["), seq.last == UInt8(ascii: "m") else { return }
        let params = String(bytes: seq[2..<seq.count - 1], encoding: .utf8) ?? ""
        lastSGR = (params.isEmpty || params == "0") ? "" : params
    }

    /// 对一段无 ESC 的文本套色：逐规则包 \e[<sgr>m … \e[<restore>m
    private static func colorize(_ text: String, restoreSGR: String) -> String {
        var working = text
        for (regex, sgr) in rules {
            let matches = regex.matches(in: working, range: NSRange(working.startIndex..., in: working))
            guard !matches.isEmpty else { continue }
            var rebuilt = ""
            var cursor = working.startIndex
            for match in matches {
                guard let range = Range(match.range, in: working) else { continue }
                rebuilt += working[cursor..<range.lowerBound]
                rebuilt += "\u{1b}[\(sgr)m"
                rebuilt += working[range]
                rebuilt += "\u{1b}[\(restoreSGR)m"
                cursor = range.upperBound
            }
            rebuilt += working[cursor...]
            working = rebuilt
        }
        return working
    }
}

/// 按行缓冲的高亮管道：喂任意字节块，返回可直喂终端的字节（完整行已着色）。
/// 尾部无换行的半行挂起（shell 提示符场景），由调用方定时 flushIfStalled 放出：
/// 闲置超过 idleFlushInterval 或持满 maxHoldInterval 即放出——只按「闲置」等行完成，
/// 持续输出会把按键回显无限推迟（TODO 72 输入延迟的根因）。
final class LogHighlightPipe {
    private var buffer: [UInt8] = []
    /// 半行首字节时间（硬上限计时起点）与末次追加时间（闲置计时起点）
    private var pendingSince: Date?
    private var lastAppendAt: Date?
    /// 闲置放出阈值：回显延迟上界，25ms 在感知阈值内
    static let idleFlushInterval: TimeInterval = 0.025
    /// 半行硬上限：再长的行也放行（跨 chunk 慢流场景保持不超 150ms 延迟）
    static let maxHoldInterval: TimeInterval = 0.15
    /// 超限保护：异常巨量输出直接直通，不做正则（内存/卡顿兜底）
    private static let maxBufferSize = 1 << 20
    /// 着色开关（关闭时行原样透传，管道仍负责拼行/过滤）
    var colorizeEnabled = true
    /// 行级过滤：返回 true 丢弃该行（SSH 会话启动期隐藏 Last login 横幅用）
    var lineFilter: (([UInt8]) -> Bool)?

    /// 是否有挂起的半行
    var hasPending: Bool { !buffer.isEmpty }

    /// 喂一个字节块，返回可直喂终端的字节（完整行，含换行）
    func process(_ chunk: [UInt8]) -> [UInt8] {
        guard !chunk.isEmpty else { return [] }
        if buffer.isEmpty { pendingSince = Date() }
        lastAppendAt = Date()
        buffer.append(contentsOf: chunk)
        if buffer.count > LogHighlightPipe.maxBufferSize {
            let all = buffer
            buffer = []
            pendingSince = nil
            lastAppendAt = nil
            return all
        }
        var out = [UInt8]()
        out.reserveCapacity(chunk.count + 64)
        var cursor = buffer.startIndex
        while let nl = buffer[cursor...].firstIndex(of: 0x0a) {
            let line = Array(buffer[cursor..<nl])
            if lineFilter?(line) != true {
                out.append(contentsOf: colorizeEnabled ? LogHighlighter.highlight(line: line) : line)
                out.append(0x0a)
            }
            cursor = buffer.index(after: nl)
        }
        if cursor > buffer.startIndex {
            buffer.removeFirst(cursor - buffer.startIndex)
            if buffer.isEmpty {
                pendingSince = nil
                lastAppendAt = nil
            }
        }
        return out
    }

    /// 到点检查：闲置超时或持满硬上限则放出挂起内容（已过横幅保留器口径由调用方接），
    /// 未到点返回空
    func flushIfStalled(now: Date = Date()) -> [UInt8] {
        guard !buffer.isEmpty else { return [] }
        let held = now.timeIntervalSince(pendingSince ?? now)
        let idle = now.timeIntervalSince(lastAppendAt ?? now)
        guard idle >= Self.idleFlushInterval || held >= Self.maxHoldInterval else { return [] }
        return flushPending()
    }

    /// 强制放出挂起半行（不着色，模式可能不完整）
    func flushPending() -> [UInt8] {
        pendingSince = nil
        lastAppendAt = nil
        guard !buffer.isEmpty else { return [] }
        let tail = buffer
        buffer = []
        return tail
    }

    /// 关闭高亮/会话结束时清挂起内容
    func reset() { buffer = []; pendingSince = nil; lastAppendAt = nil }
}

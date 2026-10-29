import AppKit

// 轻量 shell 语法高亮（脚本片段预览用）：
// 注释灰、字符串绿、变量/命令替换橙、控制关键词紫、常用命令蓝，其余浅灰
enum ShellHighlighter {
    private static let keywords: Set<String> = [
        "if", "then", "elif", "else", "fi", "for", "in", "do", "done", "while", "until",
        "case", "esac", "function", "return", "local", "export", "readonly", "shift",
        "break", "continue", "exit", "source",
    ]
    private static let commands: Set<String> = [
        "echo", "printf", "cd", "ls", "cat", "grep", "awk", "sed", "find", "xargs", "sort",
        "uniq", "head", "tail", "wc", "tr", "cut", "tee", "curl", "wget", "ssh", "scp",
        "rsync", "tar", "zip", "gzip", "chmod", "chown", "mkdir", "rm", "cp", "mv", "ln",
        "touch", "df", "du", "free", "top", "htop", "ps", "kill", "systemctl", "journalctl",
        "service", "docker", "kubectl", "git", "apt", "yum", "brew", "ping", "netstat",
        "ifconfig", "ip", "iptables", "nginx", "mysql", "redis-cli", "psql", "python3",
        "node", "npm", "jq", "date", "sleep", "which", "whoami", "hostname", "uname",
        "sudo", "su", "set", "apt-get", "crontab", "uptime", "vmstat", "lsof", "less",
    ]

    struct Palette {
        let plain = NSColor(calibratedWhite: 0.88, alpha: 1)
        let comment = NSColor(calibratedWhite: 0.45, alpha: 1)
        let string = NSColor(calibratedRed: 0.55, green: 0.8, blue: 0.5, alpha: 1)
        let variable = NSColor(calibratedRed: 0.95, green: 0.7, blue: 0.42, alpha: 1)
        let keyword = NSColor(calibratedRed: 0.72, green: 0.55, blue: 0.95, alpha: 1)
        let command = NSColor(calibratedRed: 0.45, green: 0.7, blue: 0.98, alpha: 1)
        let option = NSColor(calibratedWhite: 0.65, alpha: 1)
    }

    static func highlight(_ script: String, font: NSFont) -> NSAttributedString {
        let palette = Palette()
        let result = NSMutableAttributedString()
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false)

        for (lineIndex, rawLine) in lines.enumerated() {
            let line = String(rawLine)
            var index = line.startIndex
            var atLineStart = true
            var afterPipeOrDelim = false

            while index < line.endIndex {
                let ch = line[index]

                // 行内注释：未被引号包裹的 # 起全部置灰（简化：' 后无空格的 # 视为注释起点）
                if ch == "#" {
                    let rest = String(line[index...])
                    result.append(NSAttributedString(string: rest, attributes: attrs(palette.comment, font)))
                    break
                }
                // 引号字符串
                if ch == "\"" || ch == "'" {
                    let quote = ch
                    var end = line.index(after: index)
                    while end < line.endIndex && line[end] != quote {
                        end = line.index(after: end)
                    }
                    if end < line.endIndex { end = line.index(after: end) }
                    let piece = String(line[index..<end])
                    // 双引号内的 $VAR 再着色
                    if quote == "\"" && piece.contains("$") {
                        appendVariableAware(piece, base: palette.string, variable: palette.variable, font: font, into: result)
                    } else {
                        result.append(NSAttributedString(string: piece, attributes: attrs(palette.string, font)))
                    }
                    index = end
                    atLineStart = false
                    continue
                }
                // 变量 / 命令替换：$VAR ${…} $(…)
                if ch == "$" {
                    var end = line.index(after: index)
                    var depth = 0
                    while end < line.endIndex {
                        let c = line[end]
                        if c == "(" { depth += 1 }
                        if c == ")" {
                            if depth == 0 { break }
                            depth -= 1
                        }
                        if depth == 0, !(c.isLetter || c.isNumber || c == "_" || c == "{" || c == "(" || c == "}" || c == "?") { break }
                        end = line.index(after: end)
                    }
                    if end == line.index(after: index) { // 光杆 $，按普通字符
                        result.append(NSAttributedString(string: "$", attributes: attrs(palette.plain, font)))
                        index = end
                        continue
                    }
                    result.append(NSAttributedString(string: String(line[index..<end]),
                                                     attributes: attrs(palette.variable, font)))
                    index = end
                    atLineStart = false
                    continue
                }
                // 词
                if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == "/" || ch == "." {
                    var end = index
                    while end < line.endIndex {
                        let c = line[end]
                        if c.isLetter || c.isNumber || c == "_" || c == "-" || c == "/" || c == "." || c == "*" {
                            end = line.index(after: end)
                        } else { break }
                    }
                    let word = String(line[index..<end])
                    let isCommandPosition = atLineStart || afterPipeOrDelim
                    let color: NSColor
                    if keywords.contains(word) && isCommandPosition {
                        color = palette.keyword
                    } else if commands.contains(word) && isCommandPosition {
                        color = palette.command
                    } else if word.hasPrefix("-") {
                        color = palette.option
                    } else {
                        color = palette.plain
                    }
                    result.append(NSAttributedString(string: word, attributes: attrs(color, font)))
                    index = end
                    atLineStart = false
                    continue
                }
                // 单字符分隔符
                result.append(String(ch), color: palette.plain, font: font)
                if ch == "|" || ch == ";" || ch == "&" {
                    afterPipeOrDelim = true
                } else if ch != " " {
                    afterPipeOrDelim = false
                    atLineStart = false
                }
                index = line.index(after: index)
            }

            if lineIndex < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: attrs(palette.plain, font)))
            }
        }
        return result
    }

    /// 双引号字符串内部的 $VAR 橙色、其余字符串色
    private static func appendVariableAware(_ piece: String, base: NSColor, variable: NSColor,
                                            font: NSFont, into result: NSMutableAttributedString) {
        var index = piece.startIndex
        while index < piece.endIndex {
            if piece[index] == "$" {
                var end = piece.index(after: index)
                while end < piece.endIndex {
                    let c = piece[end]
                    if c.isLetter || c.isNumber || c == "_" || c == "{" || c == "}" { end = piece.index(after: end) }
                    else { break }
                }
                result.append(NSAttributedString(string: String(piece[index..<end]),
                                                 attributes: attrs(variable, font)))
                index = end
            } else {
                var end = index
                while end < piece.endIndex && piece[end] != "$" { end = piece.index(after: end) }
                result.append(NSAttributedString(string: String(piece[index..<end]),
                                                 attributes: attrs(base, font)))
                index = end
            }
        }
    }

    private static func attrs(_ color: NSColor, _ font: NSFont) -> [NSAttributedString.Key: Any] {
        [.foregroundColor: color, .font: font]
    }
}

private extension NSMutableAttributedString {
    func append(_ string: String, color: NSColor, font: NSFont) {
        append(NSAttributedString(string: string, attributes: [.foregroundColor: color, .font: font]))
    }
}

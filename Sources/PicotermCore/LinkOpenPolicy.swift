import Foundation

/// 终端链接点击口径（2026-10-26 用户指定；安全规则参考 Tabby tabby-linkifier/src/handlers.ts）。
/// SwiftTerm 识别出的链接文本（URL 或路径）只归四类，scheme 白名单之外一律不交给系统打开——
/// 远端输出可以构造任意 URL，smb:/ssh:/git: 之类交给系统会触发挂载或起进程。
public enum LinkTarget: Equatable {
    /// http / https / mailto：交系统默认程序
    case web(URL)
    /// 本机文件或目录（本地 Shell 的路径、无 host 的 file: URL）：在 Finder 中显示
    case localFile(URL)
    /// 远端会话里的路径（绝对化后）：文件管理器跳转
    case remotePath(String)
    /// 白名单外 scheme、带变量的路径、无法绝对化的相对路径：不处理
    case rejected
}

public enum LinkOpenPolicy {
    private static let webSchemes: Set<String> = ["http", "https", "mailto"]

    /// - Parameters:
    ///   - link: SwiftTerm 回调的链接文本（显式 OSC 8 的 URL 或正则命中的 URL/路径）
    ///   - isRemote: SSH/Telnet 会话为 true（路径归远端），本地 Shell 为 false
    ///   - currentDirectory: 会话当前目录（相对路径的基准；未知传 nil → 相对路径拒绝）
    ///   - home: 会话的 home（`~` 展开基准；未知传 nil → `~` 路径拒绝）
    public static func classify(_ link: String, isRemote: Bool,
                                currentDirectory: String?, home: String?) -> LinkTarget {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .rejected }

        if let scheme = scheme(of: text) {
            if webSchemes.contains(scheme) {
                return URL(string: text).map { .web($0) } ?? .rejected
            }
            if scheme == "file" {
                guard let url = URL(string: text),
                      (url.host ?? "").isEmpty || url.host == "localhost" else { return .rejected }
                let path = url.path
                guard path.hasPrefix("/") else { return .rejected }
                return isRemote ? .remotePath(normalize(path)) : .localFile(URL(fileURLWithPath: normalize(path)))
            }
            return .rejected
        }

        guard let absolute = absolutePath(from: stripTrailing(text), currentDirectory: currentDirectory, home: home) else {
            return .rejected
        }
        return isRemote ? .remotePath(absolute) : .localFile(URL(fileURLWithPath: absolute))
    }

    /// RFC 3986 scheme（`host:/path` 这类 scp 写法也会被当成 scheme——不在白名单内自然拒绝）
    static func scheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let head = text[..<colon]
        guard let first = head.first, first.isLetter,
              head.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) else {
            return nil
        }
        return head.lowercased()
    }

    /// 去掉编译器/grep 风格的行号后缀（`main.c:12:5`）与粘在末尾的标点
    static func stripTrailing(_ text: String) -> String {
        var value = Substring(text)
        if let range = value.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) {
            value = value[..<range.lowerBound]
        }
        while let last = value.last, ",.;:".contains(last) {
            value = value.dropLast()
        }
        return String(value)
    }

    /// 路径绝对化：`~`/相对路径按给定基准展开，`$VAR` 无法解析一律拒绝
    static func absolutePath(from path: String, currentDirectory: String?, home: String?) -> String? {
        guard !path.isEmpty, !path.contains("$") else { return nil }
        if path.hasPrefix("/") { return normalize(path) }
        if path == "~" || path.hasPrefix("~/") {
            guard let home, home.hasPrefix("/") else { return nil }
            return normalize(home + String(path.dropFirst()))
        }
        guard !path.hasPrefix("~") else { return nil } // ~user 不认
        guard let base = currentDirectory, base.hasPrefix("/") else { return nil }
        return normalize(base + "/" + path)
    }

    /// 纯字符串规范化：合并重复斜杠、消 `.`/`..`，不触盘
    public static func normalize(_ path: String) -> String {
        var stack: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": _ = stack.popLast()
            default: stack.append(part)
            }
        }
        return "/" + stack.joined(separator: "/")
    }
}

import Foundation

// 终端输入补全（TODO 18）：会话命令历史 + 关键词集合，⇥ 触发
// 历史来源：回显行中「提示符后到行尾」的启发式抽取（对 SSH/本地 shell 通用）
final class CommandHistory {
    static let shared = CommandHistory()

    private(set) var commands: [String] = []
    private var fileURL: URL {
        AppSettings.shared.dataDir.appendingPathComponent("history.json")
    }

    /// 内置常用命令/关键词（补全候选兜底）
    static let keywords: Set<String> = [
        "systemctl", "journalctl", "docker", "kubectl", "docker-compose", "tail", "grep", "awk",
        "sed", "find", "chmod", "chown", "netstat", "ss", "ping", "curl", "wget", "tar", "zip",
        "unzip", "vim", "nano", "htop", "top", "df", "du", "free", "uname", "whoami", "hostname",
        "ls", "cd", "cp", "mv", "rm", "mkdir", "touch", "cat", "less", "head", "sudo", "apt",
        "yum", "brew", "git", "ssh", "scp", "rsync", "nginx", "mysql", "redis-cli", "psql",
    ]

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return }
        commands = list
    }

    func record(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2, trimmed.count < 200 else { return }
        commands.removeAll { $0 == trimmed }
        commands.append(trimmed)
        if commands.count > 500 {
            commands.removeFirst(commands.count - 500)
        }
        if let data = try? JSONEncoder().encode(commands) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 补全候选：历史（最近优先，按前缀）→ 关键词（字典序）；跨集合去重（大小写不敏感）
    func completions(prefix: String) -> [String] {
        guard !prefix.isEmpty else { return [] }
        let lowered = prefix.lowercased()
        var seen = Set<String>()
        var result: [String] = []
        // 只取命令首词补全（含路径参数的历史整行不适合词补全）
        for candidate in commands.reversed().map({ line -> String in
            line.split(separator: " ").first.map(String.init) ?? line
        }) {
            guard result.count < 20 else { break }
            if candidate.lowercased().hasPrefix(lowered), candidate != prefix,
               seen.insert(candidate.lowercased()).inserted {
                result.append(candidate)
            }
        }
        for candidate in Self.keywords.sorted() where result.count < 20 {
            if candidate.lowercased().hasPrefix(lowered), candidate != prefix,
               seen.insert(candidate.lowercased()).inserted {
                result.append(candidate)
            }
        }
        return result
    }
}

// L10n 机制单测：语言解析、L() 查表与回退、format 展开、译文表数据体检
import PicotermCore

enum L10nChecks {
    static func run() -> Int {
        print("L10n:")
        var n = 0

        // 显式语言解析
        n += check({
            L10n.preference = .en
            let en = L10n.isEnglish
            L10n.preference = .zh
            let zh = L10n.isEnglish
            return en && !zh
        }(), "explicitLanguageResolution")

        // L()：中文原样、英文查表、缺条目回退键
        n += check({
            L10n.preference = .zh
            let zhPass = L("连接") == "连接"
            L10n.preference = .en
            let enLookup = L("连接") == "Connect"
            let fallback = L("此键不存在于表中的文案") == "此键不存在于表中的文案"
            return zhPass && enLookup && fallback
        }(), "lookupAndFallback")

        // format 展开：两种语言分支一致走 String(format:)
        n += check({
            L10n.preference = .en
            let en = L("有 %ld 个会话", 3)
            L10n.preference = .zh
            let zh = L("有 %ld 个会话", 5)
            return en == "There are 3 sessions" && zh == "有 5 个会话"
        }(), "formatExpansion")

        // Int32 %d 与浮点 %.1f（后者无译文条目，验证缺译回退时 format 照常展开）
        n += check({
            L10n.preference = .en
            let d = L("%d 项", Int32(7))
            let f = L("字号 %.1f pt", 12.5)
            return d == "7 items" && f == "字号 12.5 pt"
        }(), "formatSpecifierVariants")

        // 译文表体检：值非空、键含非 ASCII 字符（中文或全角标点；纯 ASCII 键无需翻译不入表，
        // 防手滑把英文/日志串当键）、键无前后空白
        n += check({
            !L10nEn.table.isEmpty
                && L10nEn.table.allSatisfy { !$0.value.isEmpty }
                && L10nEn.table.allSatisfy { key, _ in
                    key.unicodeScalars.contains { $0.value > 127 }
                }
                && L10nEn.table.allSatisfy { key, _ in key == key.trimmingCharacters(in: .whitespaces) }
        }(), "tableSanity (\(L10nEn.table.count) entries)")

        L10n.preference = .system
        return n
    }
}

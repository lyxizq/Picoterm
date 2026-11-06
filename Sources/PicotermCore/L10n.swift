import Foundation

// 界面本地化（2026-10-26 用户指定：设置可选中/英文）
// 机制：中文字符串即键——L("连接") 中文界面原样返回，英文界面查 L10nEn.table，
// 缺条目回退键本身（新文案漏翻译时英文界面显示中文，不丢内容）。

/// 界面语言偏好；App 侧（AppSettings）持久化，启动时灌入 preference
public enum AppLanguage: String, CaseIterable {
    case system   // 跟随系统首选语言
    case zh       // 简体中文
    case en       // English
}

public enum L10n {
    /// 当前语言偏好（App 启动早期由 AppDelegate 灌入；设置页切换时同步覆盖）。
    /// 仅主线程读写（UI 构建期取值），nonisolated(unsafe) 规避 Swift 6 全局可变态检查
    public nonisolated(unsafe) static var preference: AppLanguage = .system

    /// 生效语言是否英文（system 按系统首选语言解析，zh* 一律中文）
    public static var isEnglish: Bool {
        switch preference {
        case .en: return true
        case .zh: return false
        case .system:
            let first = Locale.preferredLanguages.first ?? "en"
            return !first.hasPrefix("zh")
        }
    }
}

/// 界面文案本地化入口。带参数时按 String(format:) 语义展开，中文/英文两分支
/// 一致走 format（键里写 %ld（Int）/%d（Int32）/%.1f/%@ 等占位符）。
/// 只包「会显示给用户看」的文案；日志、存储键、参与 == 比较或持久化的值不包。
public func L(_ zh: String, _ args: CVarArg...) -> String {
    let raw = L10n.isEnglish ? (L10nEn.table[zh] ?? zh) : zh
    return args.isEmpty ? raw : String(format: raw, arguments: args)
}

import AppKit
import SwiftTerm
import PicotermCore

// Ported from Berth (GPL-3) — github.com/xinghelee/Berth  Core/Terminal/TerminalTheme.swift
// 主题定义 + 预设（midnight/pureBlack/berthDark/catppuccin-macchiato 照搬，另加浅色 Solarized）

struct TerminalTheme: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let isDark: Bool
    let background: String   // hex
    let foreground: String
    let cursor: String
    let selection: String
    let ansi: [String]       // 16 色
}

extension NSColor {
    convenience init(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        var rgba: UInt64 = 0
        Scanner(string: value).scanHexInt64(&rgba)
        self.init(srgbRed: CGFloat((rgba >> 16) & 0xFF) / 255,
                  green: CGFloat((rgba >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgba & 0xFF) / 255,
                  alpha: 1)
    }
}

enum TerminalThemes {
    // Ported from Berth: 精调深色（深靛蓝近黑底）
    static let midnight = TerminalTheme(
        id: "midnight", name: L("午夜"), isDark: true,
        background: "#0F1117", foreground: "#E6E8EE", cursor: "#8C9CF9", selection: "#2A3350",
        ansi: ["#2A2E3A", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0CAF5",
               "#414868", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#FFFFFF"])

    // Ported from Berth: 纯黑（OLED/高对比）
    static let pureBlack = TerminalTheme(
        id: "pure-black", name: L("纯黑"), isDark: true,
        background: "#000000", foreground: "#E6E6E6", cursor: "#FFFFFF", selection: "#333333",
        ansi: ["#1A1A1A", "#FF5F57", "#32D74B", "#FFD60A", "#0A84FF", "#BF5AF2", "#5AC8FA", "#D6D6D6",
               "#4D4D4D", "#FF6E67", "#5DE372", "#FFE454", "#409CFF", "#D28CF7", "#70D7FF", "#FFFFFF"])

    // Ported from Berth: One Dark 气质
    static let berthDark = TerminalTheme(
        id: "berth-dark", name: L("深色经典"), isDark: true,
        background: "#1B1E25", foreground: "#EBEEF2", cursor: "#56B6C2", selection: "#3E4451",
        ansi: ["#1B1E25", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#ABB2BF",
               "#5C6370", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#FFFFFF"])

    // Ported from Berth: Catppuccin Macchiato
    static let macchiato = TerminalTheme(
        id: "catppuccin-macchiato", name: "Macchiato", isDark: true,
        background: "#24273A", foreground: "#CAD3F5", cursor: "#F4DBD6", selection: "#454A5F",
        ansi: ["#494D64", "#ED8796", "#A6DA95", "#EED49F", "#8AADF4", "#F5BDE6", "#8BD5CA", "#B8C0E0",
               "#5B6078", "#ED8796", "#A6DA95", "#EED49F", "#8AADF4", "#F5BDE6", "#8BD5CA", "#A5ADCB"])

    static let light = TerminalTheme(
        id: "light", name: L("浅色"), isDark: false,
        background: "#FAFAFA", foreground: "#333A45", cursor: "#0969DA", selection: "#CDE3F5",
        ansi: ["#24292F", "#CF222E", "#116329", "#4D2D00", "#0969DA", "#8250DF", "#1B7C83", "#6E7781",
               "#57606A", "#A40E26", "#1A7F37", "#633C01", "#218BFF", "#A475F9", "#3192AA", "#8B949E"])

    /// 内置 5 套（Berth 移植 + 浅色）
    static let builtIn: [TerminalTheme] = [midnight, pureBlack, berthDark, macchiato, light]

    /// Tabby 社区配色 190 套（CommunityColorSchemes.swift 生成件；id 前缀 "tabby:"），首次访问解码
    static let community: [TerminalTheme] = {
        (try? JSONDecoder().decode([TerminalTheme].self, from: Data(CommunityColorSchemes.json.utf8))) ?? []
    }()

    static let all: [TerminalTheme] = builtIn + community

    private static let byId: [String: TerminalTheme] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    static func theme(id: String) -> TerminalTheme {
        byId[id] ?? midnight
    }
}

// 主题应用到终端视图（ANSI 16 色走 SwiftTerm 原生 installColors，
// 不再经 OSC 4 序列注入——旧实现每色后误加结束符，rgb 载荷被当正文显示成乱码）
enum ThemeApplier {
    static func apply(_ theme: TerminalTheme, to view: TerminalView) {
        view.nativeBackgroundColor = NSColor(hex: theme.background)
        view.nativeForegroundColor = NSColor(hex: theme.foreground)
        view.caretColor = NSColor(hex: theme.cursor)
        view.selectedTextBackgroundColor = NSColor(hex: theme.selection)
        let palette = theme.ansi.map { hex -> SwiftTerm.Color in
            var value = hex
            if value.hasPrefix("#") { value.removeFirst() }
            let r = value.prefix(2), g = value.dropFirst(2).prefix(2), b = value.suffix(2)
            func channel(_ s: Substring) -> UInt16 { UInt16(Int(s, radix: 16) ?? 0) * 257 }
            return SwiftTerm.Color(red: channel(r), green: channel(g), blue: channel(b))
        }
        view.installColors(palette)
    }
}

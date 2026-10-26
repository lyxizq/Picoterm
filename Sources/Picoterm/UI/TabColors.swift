import AppKit
import PicotermCore

/// 标签/主机颜色标记（2026-10-26 用户指定；预设色板口径参考 Tabby TAB_COLORS：6 色 + 无，不做自由取色）。
/// 存储值为 tag 字符串（HostEntry.colorTag / 会话内存态），显示用系统动态色以适配明暗外观。
enum TabColors {
    struct Preset {
        let tag: String
        let name: String
        let color: NSColor?
    }

    static let presets: [Preset] = [
        Preset(tag: "", name: L("无"), color: nil),
        Preset(tag: "blue", name: L("蓝"), color: .systemBlue),
        Preset(tag: "green", name: L("绿"), color: .systemGreen),
        Preset(tag: "orange", name: L("橙"), color: .systemOrange),
        Preset(tag: "purple", name: L("紫"), color: .systemPurple),
        Preset(tag: "red", name: L("红"), color: .systemRed),
        Preset(tag: "yellow", name: L("黄"), color: .systemYellow),
    ]

    static func color(for tag: String) -> NSColor? {
        presets.first { $0.tag == tag }?.color
    }

    static func index(of tag: String) -> Int {
        presets.firstIndex { $0.tag == tag } ?? 0
    }

    /// 菜单/下拉用的圆点图标；无色画空心圈
    static func dotImage(for color: NSColor?, diameter: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            if let color {
                color.setFill()
                path.fill()
            } else {
                NSColor.tertiaryLabelColor.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 填充好的下拉框（无 + 6 色，带圆点）
    static func populate(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        for preset in presets {
            popup.addItem(withTitle: preset.name)
            popup.lastItem?.image = dotImage(for: preset.color)
        }
    }
}

// Picoterm app icon 生成器：swift Resources/make-icon.swift
// 输出 Resources/AppIcon.iconset/*.png，再用 iconutil 打成 icns
import AppKit

let master: CGFloat = 1024

func roundedRect(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func shadow(_ alpha: CGFloat, blur: CGFloat, dy: CGFloat) -> NSShadow {
    let s = NSShadow()
    s.shadowColor = NSColor(calibratedWhite: 0.02, alpha: alpha)
    s.shadowBlurRadius = blur
    s.shadowOffset = NSSize(width: 0, height: -dy)
    return s
}

// 统一按 1024 画布绘制，坐标乘 scale 缩放到目标尺寸
func drawIcon(_ s: CGFloat) {
    let k = s / master
    let full = NSRect(x: 0, y: 0, width: s, height: s)

    // ---- 背景：圆角方块 + 蓝→紫对角渐变 + 顶部玻璃高光 ----
    let bg = roundedRect(full, 224 * k)
    bg.addClip()

    NSGradient(starting: NSColor(calibratedRed: 0.22, green: 0.47, blue: 0.98, alpha: 1),
               ending: NSColor(calibratedRed: 0.52, green: 0.32, blue: 0.98, alpha: 1))!
        .draw(in: full, angle: -55)

    NSGradient(colors: [NSColor(calibratedWhite: 0.04, alpha: 0.34),
                        NSColor(calibratedWhite: 0.04, alpha: 0.0)])!
        .draw(in: NSRect(x: 0, y: 0, width: s, height: s * 0.55), angle: 90)

    NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 0.30),
                        NSColor(calibratedWhite: 1, alpha: 0.02)])!
        .draw(in: NSRect(x: 0, y: s * 0.52, width: s, height: s * 0.48), angle: -90)

    // ---- 左下：终端卡片 ----
    let termRect = NSRect(x: 84 * k, y: 104 * k, width: 572 * k, height: 508 * k)
    NSGraphicsContext.current!.saveGraphicsState()
    shadow(0.38, blur: 44 * k, dy: 26 * k).set()
    NSColor(calibratedRed: 0.043, green: 0.055, blue: 0.086, alpha: 0.97).setFill()
    roundedRect(termRect, 80 * k).fill()
    NSGraphicsContext.current!.restoreGraphicsState()

    NSGraphicsContext.current!.saveGraphicsState()
    roundedRect(termRect, 80 * k).addClip()
    // 窗口三点
    for (i, color) in [NSColor(calibratedWhite: 1, alpha: 0.30),
                       NSColor(calibratedWhite: 1, alpha: 0.22),
                       NSColor(calibratedWhite: 1, alpha: 0.15)].enumerated() {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: termRect.minX + 52 * k + CGFloat(i) * 58 * k,
                                    y: termRect.maxY - 92 * k,
                                    width: 36 * k, height: 36 * k)).fill()
    }
    // >_ 提示符
    let prompt = NSAttributedString(string: ">_", attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 296 * k, weight: .bold),
        .foregroundColor: NSColor(calibratedRed: 0.36, green: 0.84, blue: 0.55, alpha: 1),
    ])
    let ps = prompt.size()
    prompt.draw(at: NSPoint(x: termRect.midX - ps.width / 2,
                            y: termRect.midY - ps.height / 2 - 26 * k))
    NSGraphicsContext.current!.restoreGraphicsState()

    // ---- 右上：玻璃面板（会话/文件列表意象） ----
    let panelRect = NSRect(x: 616 * k, y: 388 * k, width: 322 * k, height: 420 * k)
    NSGraphicsContext.current!.saveGraphicsState()
    shadow(0.35, blur: 40 * k, dy: 24 * k).set()
    NSColor(calibratedWhite: 1, alpha: 0.17).setFill()
    roundedRect(panelRect, 72 * k).fill()
    NSGraphicsContext.current!.restoreGraphicsState()

    roundedRect(panelRect, 72 * k).lineWidth = 6 * k
    NSColor(calibratedWhite: 1, alpha: 0.32).setStroke()
    roundedRect(panelRect, 72 * k).stroke()

    let swatchColors: [NSColor] = [
        NSColor(calibratedRed: 0.19, green: 0.82, blue: 0.35, alpha: 1),
        NSColor(calibratedRed: 0.25, green: 0.78, blue: 0.88, alpha: 1),
        NSColor(calibratedWhite: 1, alpha: 0.55),
        NSColor(calibratedWhite: 1, alpha: 0.30),
    ]
    let barWidths: [CGFloat] = [196, 156, 178, 132]
    for i in 0..<4 {
        let rowY = panelRect.maxY - 118 * k - CGFloat(i) * 96 * k
        swatchColors[i].setFill()
        roundedRect(NSRect(x: panelRect.minX + 52 * k, y: rowY, width: 44 * k, height: 44 * k), 12 * k).fill()
        NSColor(calibratedWhite: 1, alpha: 0.62 - CGFloat(i) * 0.10).setFill()
        roundedRect(NSRect(x: panelRect.minX + 120 * k, y: rowY + 10 * k,
                           width: barWidths[i] * k, height: 24 * k), 12 * k).fill()
    }
}

func renderRep(_ pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outDir = "Resources/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let specs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, pixels) in specs {
    let rep = renderRep(pixels)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: outDir + "/" + name))
    print("wrote \(outDir)/\(name)")
}

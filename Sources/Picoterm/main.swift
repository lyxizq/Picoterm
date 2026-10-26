import AppKit

// 入口：手工装配 NSApplication；菜单走系统菜单栏，不做窗内菜单行
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

import AppKit
import Darwin

// 屏蔽 SIGPIPE（网络连接/转发对端关闭时不杀进程，由读写错误码处理）
signal(SIGPIPE, SIG_IGN)

// 入口：手工装配 NSApplication；菜单走系统菜单栏，不做窗内菜单行
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

import AppKit

/// 设置页布局探针（调试工具，2026-10-26）：`Picoterm --probe-settings-layout`
/// 建出设置窗口，逐页对每个可交互控件的中心做 hitTest，报告被其他视图挡住（点不到）的控件，
/// 以及各分组内容框是否溢出其底板。纯几何命中测试，不依赖合成鼠标事件（那条路不可靠，见记忆）。
/// 输出到 stdout 后进程退出；排查「设置里控件点不动 / 行被下一分组盖住」类问题用。
@MainActor
enum SettingsLayoutProbe {
    static func run() {
        let controller = SettingsWindowController()
        controller.showWindow(nil)
        guard let window = controller.window,
              let scroll = window.contentView as? NSScrollView,
              let view = scroll.documentView as? SettingsView else {
            print("probe: settings view not found")
            exit(2)
        }
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        print("window content size: \(window.contentView!.bounds.size), document height: \(view.bounds.height)")
        print("document ambiguous: \(view.hasAmbiguousLayout)")
        for (index, sub) in view.subviews.enumerated() {
            print("  doc.subview[\(index)] \(type(of: sub)) frame=\(sub.frame.integral) ambiguous=\(sub.hasAmbiguousLayout)")
        }

        var blocked = 0
        view.forEachPage { title, page in
            window.layoutIfNeeded()
            print("== 页「\(title)」 frame=\(page.frame.integral) ==")
            var controls: [NSControl] = []
            collectControls(in: page, into: &controls)
            for control in controls {
                let center = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
                let hit = window.contentView?.hitTest(center)
                let ok = hit === control || (hit?.isDescendant(of: control) ?? false)
                if !ok { blocked += 1 }
                let frame = control.convert(control.bounds, to: nil).integral
                let hitName = hit.map { String(describing: type(of: $0)) } ?? "nil"
                var extra = ""
                if control is NSPopUpButton {
                    let heights = control.constraints.filter { $0.firstAttribute == .height }.map { "\(Int($0.constant))@\(Int($0.priority.rawValue))" }
                    extra = " heightConstraints=\(heights) intrinsic=\(Int(control.intrinsicContentSize.height))"
                }
                print("  \(ok ? "OK     " : "BLOCKED") \(describe(control)) frame=\(frame) hit=\(hitName)\(extra)")
            }
            reportOverflow(in: page)
        }
        print(blocked == 0 ? "RESULT: all controls hit-testable" : "RESULT: \(blocked) control(s) BLOCKED")
        exit(blocked == 0 ? 0 : 1)
    }

    private static func collectControls(in view: NSView, into out: inout [NSControl]) {
        if let control = view as? NSControl {
            let interactive = control is NSPopUpButton || control is NSSlider || control is NSButton
                || ((control as? NSTextField)?.isEditable ?? false)
            if interactive { out.append(control) }
        }
        for sub in view.subviews { collectControls(in: sub, into: &out) }
    }

    private static func describe(_ control: NSControl) -> String {
        let type = String(describing: Swift.type(of: control))
        if let popup = control as? NSPopUpButton { return "\(type)[\(popup.titleOfSelectedItem ?? "")]" }
        if let field = control as? NSTextField { return "\(type)[\(field.stringValue.prefix(14))]" }
        if let button = control as? NSButton, !button.title.isEmpty { return "\(type)[\(button.title)]" }
        return type
    }

    /// 分组内容框（section 内 content）底边超出底板（surface）即为溢出——下一分组会盖住它
    private static func reportOverflow(in page: NSView) {
        for container in page.subviews {
            guard let surface = container.subviews.first(where: { $0.layer?.cornerRadius == 8 }),
                  let content = surface.subviews.first else { continue }
            let contentBottom = content.convert(content.bounds, to: nil).minY
            let surfaceBottom = surface.convert(surface.bounds, to: nil).minY
            // 非翻转窗口坐标：minY 越小越靠下；content 比 surface 更低即溢出
            if contentBottom < surfaceBottom - 0.5 {
                print("  OVERFLOW section content exceeds surface by \(Int(surfaceBottom - contentBottom))pt (content=\(content.frame.integral) surface=\(surface.frame.integral))")
            }
        }
    }
}

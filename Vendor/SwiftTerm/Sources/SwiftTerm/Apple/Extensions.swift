//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 4/15/20.
//
#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS)
import Foundation

extension NSAttributedString.Key {
    static let fullBackgroundColor: NSAttributedString.Key = .init("SwiftTerm_fullBackgroundColor") // NSColor, default nil: no background
    static let selectionBackgroundColor: NSAttributedString.Key = .init("SwiftTerm_selectionBackgroundColor") // NSColor, default nil: no background
    // Picoterm 扩展：搜索「高亮全部匹配」的底色属性（优先级低于 selectionBackgroundColor）
    static let searchHighlightBackgroundColor: NSAttributedString.Key = .init("SwiftTerm_searchHighlightBackgroundColor")
}

// 搜索匹配底色：半透明黄，浅色/深色模式下都可读（WindTerm 风格的标记色）
#if os(macOS)
let swiftTermSearchHighlightColor: TTColor = TTColor(calibratedRed: 1.0, green: 0.79, blue: 0.16, alpha: 0.42)
#else
let swiftTermSearchHighlightColor: TTColor = TTColor(red: 1.0, green: 0.79, blue: 0.16, alpha: 0.42)
#endif

extension NSMutableAttributedString {
    func removeAttribute(_ attributeKey: NSAttributedString.Key) {
        self.removeAttribute(attributeKey, range: NSRange(location: 0, length: length))
    }
}

extension NSRange {
    var isEmpty: Bool {
        location == NSNotFound && length == 0
    }

    static var empty: NSRange {
        NSRange(location: NSNotFound, length: 0)
    }
}

#endif

#endif // !SWIFTTERM_EMBEDDED

// 文本预览拼接单测：整文件 / 二进制 / 头尾对齐与省略字节数 / 尾段续字节跳过 / 无换行头部回退 / UTF-16 只显头部
import Foundation
import PicotermCore

enum TextPreviewAssemblerChecks {
    static func run() -> Int {
        print("TextPreviewAssembler:")
        var n = 0
        let marker: (UInt64) -> String = { "<<\($0)>>" }

        // 整文件（tail 为 nil）原样显示
        let whole = Data("line1\nline2\n".utf8)
        let r1 = TextPreviewAssembler.assemble(head: whole, tail: nil, totalSize: UInt64(whole.count), marker: marker)
        n += check(r1?.text == "line1\nline2\n" && r1?.omittedBytes == 0 && r1?.markerRange == nil, "wholeFile")

        // 二进制头部 → nil
        let binary = Data([0x00, 0xFF, 0xFE, 0x12, 0x80, 0x81])
        n += check(TextPreviewAssembler.assemble(head: binary, tail: nil, totalSize: 6, marker: marker) == nil, "binaryRejected")

        // 头尾对齐：头切到最后换行（丢掉半行 "ccc"），尾从第一个换行后开始（丢掉半行 "xx"），省略字节数 = 总大小 − 两段保留
        let head = Data("aaa\nbbb\nccc".utf8)          // 11 字节，保留 "aaa\nbbb\n" = 8
        let tail = Data("xx\nyyy\nzzz\n".utf8)         // 11 字节，保留 "yyy\nzzz\n" = 8
        let total: UInt64 = 1000
        let r3 = TextPreviewAssembler.assemble(head: head, tail: tail, totalSize: total, marker: marker)
        n += check(r3?.text == "aaa\nbbb\n<<984>>yyy\nzzz\n", "lineAlignedJoin", r3?.text ?? "nil")
        n += check(r3?.omittedBytes == 984, "omittedBytes", "\(r3?.omittedBytes ?? 0)")
        n += check(r3.flatMap { r in r.markerRange.map { String(r.text[$0]) } } == "<<984>>", "markerRange")

        // 尾段开头是 3 字节字符「中」(E4 B8 AD) 的后两个续字节，须跳过；之后无换行则整段保留
        var tailBytes: [UInt8] = [0xB8, 0xAD]
        tailBytes += Array("文本".utf8)
        let r4 = TextPreviewAssembler.assemble(head: Data("头\n".utf8), tail: Data(tailBytes), totalSize: 5000, marker: marker)
        n += check(r4?.text.hasSuffix("文本") == true && r4?.text.contains("�") == false, "tailContinuationSkipped", r4?.text ?? "nil")

        // 头部无换行且末尾切在「中」的第一个字节上：回退到字符边界
        var headBytes = Array("abc".utf8)
        headBytes.append(0xE4)
        let r5 = TextPreviewAssembler.assemble(head: Data(headBytes), tail: Data("\nend\n".utf8), totalSize: 4000, marker: marker)
        n += check(r5?.text.hasPrefix("abc<<") == true, "headPartialCharTrimmed", r5?.text ?? "nil")

        // UTF-16（带 BOM）头部：只显示头部 + 标记，不拼尾段
        var utf16 = Data([0xFF, 0xFE])
        utf16.append(contentsOf: "hi\n".data(using: .utf16LittleEndian)!)
        let r6 = TextPreviewAssembler.assemble(head: utf16, tail: Data("garbage".utf8), totalSize: 2000, marker: marker)
        n += check(r6?.text.hasPrefix("hi\n") == true && r6?.text.contains("garbage") == false
                   && r6?.omittedBytes == 2000 - UInt64(utf16.count), "utf16HeadOnly", r6?.text ?? "nil")

        n += check(TextPreviewAssembler.formatBytes(512) == "512 B"
                   && TextPreviewAssembler.formatBytes(12 * 1024 * 1024 + 300 * 1024) == "12.3 MB", "formatBytes")
        return n
    }
}

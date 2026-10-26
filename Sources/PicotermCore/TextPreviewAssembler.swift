import Foundation

/// 文本预览拼接（2026-10-26 用户指定：前 256KB + 后 256KB，中间省略标记）。纯逻辑、不触网，
/// 由 SFTPService 喂两段字节：
/// - 文件 ≤ 2×segmentBytes：`tail` 传 nil，整段显示、无省略；
/// - 更大：`head` 为前 256KB、`tail` 为后 256KB。两段都对齐到整行（头切到最后一个换行、尾从第一个换行后起），
///   尾段先跳过开头的 UTF-8 续字节（切口可能落在多字节字符中间）；
/// - 编码由头部判定：UTF-8 走拼接；UTF-16（BOM）只显示头部；都不是 → nil（二进制，不预览）；
/// - 尾段用宽容解码（脏字节显示为 �），头部能解码就不会因尾部判成二进制。
public enum TextPreviewAssembler {
    public static let segmentBytes = 256 * 1024

    public struct Result: Equatable {
        public let text: String
        /// 0 = 全文显示；>0 = 中间省略的字节数（含对齐时让掉的半行）
        public let omittedBytes: UInt64
        /// 省略标记在 text 中的范围（弹窗用次要颜色居中显示）
        public let markerRange: Range<String.Index>?
    }

    public static func assemble(head: Data, tail: Data?, totalSize: UInt64,
                                marker: (UInt64) -> String = defaultMarker) -> Result? {
        guard let tail else {
            // 整文件在 head 里
            if let text = String(data: head, encoding: .utf8) ?? decodeUTF16WithBOM(head) {
                return Result(text: text, omittedBytes: 0, markerRange: nil)
            }
            return nil
        }

        let headBytes = [UInt8](head)
        let tailBytes = [UInt8](tail)

        // 头部：切到最后一个换行（含）；没有换行就按字符边界回退
        let headKept: [UInt8]
        if let newline = headBytes.lastIndex(of: 0x0A) {
            headKept = Array(headBytes[...newline])
        } else {
            headKept = trimIncompleteUTF8Suffix(headBytes)
        }

        guard let headText = decodeUTF8Strict(headKept) ?? decodeUTF8Strict(trimIncompleteUTF8Suffix(headKept)) else {
            // 非 UTF-8：带 BOM 的 UTF-16 只显示头部，否则按二进制处理
            guard let utf16 = decodeUTF16WithBOM(head) else { return nil }
            let omitted = totalSize - UInt64(head.count)
            let note = marker(omitted)
            let text = utf16 + note
            let range = text.range(of: note, options: .backwards)
            return Result(text: text, omittedBytes: omitted, markerRange: range)
        }

        // 尾部：跳过开头续字节（最多 3 个），再从第一个换行之后开始
        var tailStart = 0
        while tailStart < min(3, tailBytes.count), tailBytes[tailStart] & 0xC0 == 0x80 { tailStart += 1 }
        var tailKept = Array(tailBytes[tailStart...])
        if let newline = tailKept.firstIndex(of: 0x0A), newline + 1 < tailKept.count {
            tailKept = Array(tailKept[(newline + 1)...])
        }
        let tailText = String(decoding: tailKept, as: UTF8.self)

        let omitted = totalSize >= UInt64(headKept.count + tailKept.count)
            ? totalSize - UInt64(headKept.count) - UInt64(tailKept.count)
            : 0
        let note = marker(omitted)
        let text = headText + note + tailText
        let noteStart = headText.endIndex
        let noteEnd = text.index(noteStart, offsetBy: note.count)
        return Result(text: text, omittedBytes: omitted, markerRange: noteStart..<noteEnd)
    }

    /// 默认省略标记：独立成行，带省略字节数
    public static func defaultMarker(_ omitted: UInt64) -> String {
        "\n……（中间省略 \(formatBytes(omitted))）……\n\n"
    }

    public static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[unit])
    }

    /// 按字节硬截断的末尾可能是半个多字节字符：最多退 3 字节直到能严格解码
    static func trimIncompleteUTF8Suffix(_ bytes: [UInt8]) -> [UInt8] {
        for drop in 0...3 where bytes.count > drop {
            let candidate = Array(bytes.dropLast(drop))
            if decodeUTF8Strict(candidate) != nil { return candidate }
        }
        return bytes
    }

    static func decodeUTF8Strict(_ bytes: [UInt8]) -> String? {
        String(data: Data(bytes), encoding: .utf8)
    }

    /// 只认带 BOM 的 UTF-16：`String(data:encoding:.utf16)` 对任意偶数长度字节都会"成功"，
    /// 二进制文件会被当成乱码文本显示
    static func decodeUTF16WithBOM(_ data: Data) -> String? {
        guard data.count >= 2 else { return nil }
        let b0 = data[data.startIndex], b1 = data[data.startIndex + 1]
        let body = data.dropFirst(2)
        if b0 == 0xFF, b1 == 0xFE { return String(data: body, encoding: .utf16LittleEndian) }
        if b0 == 0xFE, b1 == 0xFF { return String(data: body, encoding: .utf16BigEndian) }
        return nil
    }
}

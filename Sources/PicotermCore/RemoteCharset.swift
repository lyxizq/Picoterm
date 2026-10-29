// Ported from Termind (GPL-3) — github.com/AkinoKaede/Termind
// Sources/TermindDomain/Connections/RemoteCharset.swift
// Sources/TermindRemoteInfrastructure/SSH/RemoteCharsetConverter.swift
//
// 远端字符集：SSH 会话与远端交换文本所用编码；流式 iconv 转换器保留
// 不可转换字节原样输出（坏字节不中断字节流），未完成的多字节尾缀留待下一块。

import Darwin
import Foundation

/// The character set used by text exchanged with a remote session.
public enum RemoteCharset: String, Codable, CaseIterable, Sendable {
    case utf8
    case gb18030
    case big5
    case shiftJIS
    case eucJP
    case eucKR
    case isoLatin1
    case windows1252

    public var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .gb18030: "GB18030"
        case .big5: "Big5"
        case .shiftJIS: "Shift_JIS"
        case .eucJP: "EUC-JP"
        case .eucKR: "EUC-KR"
        case .isoLatin1: "ISO-8859-1"
        case .windows1252: "Windows-1252"
        }
    }

    /// iconv 名称；未列出的一律 UTF-8 直通
    var requiresConversion: Bool { self != .utf8 }

    /// HostEntry.charset 存展示名（"UTF-8"/"GB18030"…）；兼容历史自由文本
    ///（GBK/GB2312 视同 GB18030）。无法识别返回 nil，调用方回退 utf8
    public init?(hostValue: String) {
        let text = hostValue.trimmingCharacters(in: .whitespaces)
        if let exact = RemoteCharset(rawValue: text) {
            self = exact
            return
        }
        switch text.lowercased() {
        case "gbk", "gb2312", "gb18030":
            self = .gb18030
        case "big5":
            self = .big5
        case "shift_jis", "shiftjis", "sjis":
            self = .shiftJIS
        case "euc-jp", "eucjp":
            self = .eucJP
        case "euc-kr", "euckr":
            self = .eucKR
        case "iso-8859-1", "latin1":
            self = .isoLatin1
        case "windows-1252", "cp1252":
            self = .windows1252
        case "utf-8", "utf8", "":
            self = .utf8
        default:
            return nil
        }
    }
}

/// A stateful iconv adapter that preserves unconvertible source bytes verbatim.
/// Valid input is converted while malformed, incomplete, or unrepresentable bytes
/// remain in place so charset conversion never interrupts a byte stream.
public final class RemoteCharsetStreamConverter: @unchecked Sendable {
    public enum Direction: Sendable { case encoding, decoding }

    public struct Output: Sendable {
        public var data: Data
        public var rejectedInput: Bool
    }

    private struct Conversion {
        var output: Data
        var remainder: Data
        var rejectedInput: Bool
    }

    public let charset: RemoteCharset

    private let descriptor: iconv_t?
    private let lock = NSLock()
    private var pending = Data()

    public init(charset: RemoteCharset, direction: Direction) throws {
        self.charset = charset
        let source = direction == .encoding ? "UTF-8" : iconvName(charset)
        let destination = direction == .encoding ? iconvName(charset) : "UTF-8"
        let descriptor = iconv_open(destination, source)
        guard descriptor != iconv_t(bitPattern: -1) else {
            self.descriptor = nil
            return
        }
        self.descriptor = descriptor
    }

    deinit {
        if let descriptor { iconv_close(descriptor) }
    }

    /// Converts one stream fragment. Incomplete source characters are retained.
    /// Bytes that cannot be converted are emitted verbatim.
    public func convert(_ data: Data, recoveringInvalidInput: Bool = false) throws -> Output {
        try lock.withLock {
            try convertLocked(data, recoveringInvalidInput: recoveringInvalidInput)
        }
    }

    private func convertLocked(_ data: Data, recoveringInvalidInput: Bool) throws -> Output {
        var source = pending
        source.append(data)
        pending.removeAll(keepingCapacity: true)
        if !charset.requiresConversion || descriptor == nil {
            return Output(data: source, rejectedInput: false)
        }
        do {
            let converted = try convert(source, final: false, recoveringInvalidInput: recoveringInvalidInput)
            pending = converted.remainder
            return Output(data: converted.output, rejectedInput: converted.rejectedInput)
        } catch {
            pending.removeAll(keepingCapacity: false)
            reset()
            throw error
        }
    }

    /// Finishes the stream, emitting an incomplete trailing character verbatim.
    public func finish(recoveringInvalidInput: Bool = false) throws -> Output {
        try lock.withLock {
            try finishLocked(recoveringInvalidInput: recoveringInvalidInput)
        }
    }

    private func finishLocked(recoveringInvalidInput: Bool) throws -> Output {
        defer {
            pending.removeAll(keepingCapacity: false)
            reset()
        }
        if !charset.requiresConversion || descriptor == nil {
            return Output(data: pending, rejectedInput: false)
        }
        let converted = try convert(pending, final: true, recoveringInvalidInput: recoveringInvalidInput)
        return Output(data: converted.output, rejectedInput: converted.rejectedInput)
    }

    /// 一次性字符串转换（编码方向：UTF-8 → 目标字符集）
    public static func encode(_ value: String, charset: RemoteCharset) throws -> Data {
        let converter = try RemoteCharsetStreamConverter(charset: charset, direction: .encoding)
        var output = try converter.convert(Data(value.utf8)).data
        output.append(try converter.finish().data)
        return output
    }

    /// 一次性字符串转换（解码方向：目标字符集 → UTF-8）
    public static func decode(_ data: Data, charset: RemoteCharset) throws -> String {
        let converter = try RemoteCharsetStreamConverter(charset: charset, direction: .decoding)
        var output = try converter.convert(data).data
        output.append(try converter.finish().data)
        return String(decoding: output, as: UTF8.self)
    }

    private func convert(
        _ data: Data, final: Bool, recoveringInvalidInput: Bool
    ) throws -> Conversion {
        _ = recoveringInvalidInput
        var bytes = Array(data)
        var output = Data()
        var remainder = Data()

        bytes.withUnsafeMutableBytes { rawBuffer in
            var input = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self)
            var inputCount = rawBuffer.count

            while inputCount > 0 {
                var chunk = [CChar](repeating: 0, count: max(256, min(64 * 1024, inputCount * 4 + 16)))
                let result: Int = chunk.withUnsafeMutableBufferPointer { buffer in
                    var destination = buffer.baseAddress
                    var destinationCount = buffer.count
                    let result = iconv(descriptor!, &input, &inputCount, &destination, &destinationCount)
                    output.append(
                        Data(bytes: buffer.baseAddress!, count: buffer.count - destinationCount)
                    )
                    return result
                }
                if result != -1 { continue }
                switch errno {
                case E2BIG:
                    continue
                case EINVAL where !final:
                    if let input, inputCount > 0 {
                        remainder = Data(bytes: input, count: inputCount)
                    }
                    inputCount = 0
                case EINVAL, EILSEQ:
                    guard let currentInput = input, inputCount > 0 else { return }
                    output.append(UInt8(bitPattern: currentInput.pointee))
                    self.reset()
                    inputCount -= 1
                    // iconv updates `input`; advance past the bypassed source byte.
                    input = currentInput.advanced(by: 1)
                default:
                    guard let input, inputCount > 0 else { return }
                    output.append(Data(bytes: input, count: inputCount))
                    self.reset()
                    inputCount = 0
                }
            }
        }

        if final, !remainder.isEmpty {
            output.append(remainder)
            remainder.removeAll()
        }
        return Conversion(output: output, remainder: remainder, rejectedInput: false)
    }

    private func reset() {
        guard let descriptor else { return }
        _ = iconv(descriptor, nil, nil, nil, nil)
    }
}

private func iconvName(_ charset: RemoteCharset) -> String {
    switch charset {
    case .utf8: "UTF-8"
    case .gb18030: "GB18030"
    case .big5: "BIG5"
    case .shiftJIS: "SHIFT_JIS"
    case .eucJP: "EUC-JP"
    case .eucKR: "EUC-KR"
    case .isoLatin1: "ISO-8859-1"
    case .windows1252: "WINDOWS-1252"
    }
}

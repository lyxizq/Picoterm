// SSH 字符集流式转换器单测（GB18030 主场景 + 流式切分 + 坏字节直通）
// Ported-test 口径与 Termind 行为一致：坏字节不中断流、未完尾缀跨块留存
import Foundation
import PicotermCore

enum RemoteCharsetChecks {
    static func run() -> Int {
        print("RemoteCharset:")
        var n = 0
        n += check({
            let source = "中文abc\r\n"
            guard let encoded = try? RemoteCharsetStreamConverter.encode(source, charset: .gb18030) else { return false }
            // 「中文」的 GBK/GB18030 编码
            return Array(encoded) == [0xD6, 0xD0, 0xCE, 0xC4] + Array("abc\r\n".utf8)
                && (try? RemoteCharsetStreamConverter.decode(encoded, charset: .gb18030)) == source
        }(), "gb18030RoundTrip")

        n += check({
            // 多字节序列跨块切分：尾缀字节留存，拼起来与一次性转换一致
            let text = "服务器运维手册 terminal 123"
            guard let encoded = try? RemoteCharsetStreamConverter.encode(text, charset: .gb18030),
                  let converter = try? RemoteCharsetStreamConverter(charset: .gb18030, direction: .decoding) else { return false }
            var out = Data()
            let bytes = Array(encoded)
            out.append((try? converter.convert(Data(bytes[..<3])).data) ?? Data())
            out.append((try? converter.convert(Data(bytes[3..<10])).data) ?? Data())
            out.append((try? converter.convert(Data(bytes[10...])).data) ?? Data())
            out.append((try? converter.finish().data) ?? Data())
            return String(decoding: out, as: UTF8.self) == text
        }(), "streamingSplitAcrossChunks")

        n += check({
            // 坏字节不中断流：0xFF 无法成字原样放行；后随 0x0A 不能作 GB18030 尾字节
            guard let converter = try? RemoteCharsetStreamConverter(charset: .gb18030, direction: .decoding) else { return false }
            var data = Data([0xFF, 0x0A])
            data.append(Data("ok".utf8))
            let out = (try? converter.convert(data).data) ?? Data()
            return Array(out) == [0xFF, 0x0A] + Array("ok".utf8)
        }(), "invalidByteEmittedVerbatim")

        n += check({
            guard let converter = try? RemoteCharsetStreamConverter(charset: .utf8, direction: .decoding) else { return false }
            let text = "直通 utf8 ✓"
            let out = (try? converter.convert(Data(text.utf8)).data) ?? Data()
            return String(decoding: out, as: UTF8.self) == text
        }(), "utf8Passthrough")

        n += check({
            // 「中文」的 Big5 编码：A4A4 A4E5
            let big5 = Data([0xA4, 0xA4, 0xA4, 0xE5])
            return (try? RemoteCharsetStreamConverter.decode(big5, charset: .big5)) == "中文"
        }(), "big5Decoding")

        n += check({
            RemoteCharset(hostValue: "UTF-8") == .utf8
                && RemoteCharset(hostValue: "GBK") == .gb18030
                && RemoteCharset(hostValue: "gb2312") == .gb18030
                && RemoteCharset(hostValue: "utf8") == .utf8
                && RemoteCharset(hostValue: "Big5") == .big5
                && RemoteCharset(hostValue: "gb18030") == .gb18030
                && RemoteCharset(hostValue: "EUC-TW") == nil // 未支持编码不猜
        }(), "hostValueCharsetMapping")

        return n
    }
}

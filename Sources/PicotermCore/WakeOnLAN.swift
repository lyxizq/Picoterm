// Ported from Termind (GPL-3) — github.com/AkinoKaede/Termind
// Sources/TermindApplication/Connections/WakeOnLANController.swift（协议与错误口径）
// Sources/TermindDomain/Hosts/WakeOnLANPreferences.swift（魔术包构造）
//
// Wake-on-LAN：UDP 广播魔术包唤醒休眠主机。发送后不等待主机启动
//（调用方决定是否延迟重试），一次 sendto、零依赖。

import Darwin
import Foundation

public enum WakeOnLAN {
    public enum WakeError: Error, CustomStringConvertible {
        case invalidAddress
        case noLocalNetwork
        case sendFailed(Int32)

        public var description: String {
            switch self {
            case .invalidAddress: "MAC 地址格式无效"
            case .noLocalNetwork: "本机没有可用的局域网接口"
            case .sendFailed(let errno): "发送失败（errno \(errno)）"
            }
        }
    }

    /// 魔术包：6 字节 0xFF 前缀 + 目标 MAC 重复 16 次
    public static func magicPacket(mac: [UInt8]) -> [UInt8] {
        Array(repeating: UInt8(0xFF), count: 6)
            + Array(repeating: mac, count: 16).flatMap { $0 }
    }

    /// 解析 MAC 地址：接受 `:` / `-` 分隔或 12 位裸写，大小写不敏感；全零地址无效
    public static func parseMAC(_ text: String) -> [UInt8]? {
        let cleaned = text
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: ":")
        let parts = cleaned.split(separator: ":")
        let hexes: [String]
        if parts.count == 6 {
            hexes = parts.map(String.init)
        } else if parts.count == 1, cleaned.count == 12 {
            hexes = stride(from: 0, to: 12, by: 2).map { String(cleaned.dropFirst($0).prefix(2)) }
        } else {
            return nil
        }
        var bytes: [UInt8] = []
        for hex in hexes {
            guard hex.count == 2, let byte = UInt8(hex, radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes.allSatisfy { $0 == 0 } ? nil : bytes
    }

    /// 向本机局域网广播魔术包（UDP 255.255.255.255:9，SO_BROADCAST）；不等待主机应答
    public static func send(macText: String, port: UInt16 = 9) throws {
        guard let mac = parseMAC(macText), mac.count == 6 else { throw WakeError.invalidAddress }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_BROADCAST)

        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { throw WakeError.sendFailed(errno) }
        defer { close(sock) }

        var yes: Int32 = 1
        guard setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw WakeError.sendFailed(errno)
        }

        let packet = magicPacket(mac: mac)
        let sent = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                packet.withUnsafeBytes { raw in
                    sendto(sock, raw.baseAddress, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else { throw WakeError.sendFailed(errno) }
    }
}

// Wake-on-LAN 魔术包构造与 MAC 解析单测（发包走 UDP 广播，不做网络单测）
import PicotermCore

enum WakeOnLANChecks {
    static func run() -> Int {
        print("WakeOnLAN:")
        var n = 0
        n += check({
            let mac: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
            let packet = WakeOnLAN.magicPacket(mac: mac)
            return packet.count == 102 // 6×FF + 16×6
                && packet.prefix(6).allSatisfy { $0 == 0xFF }
                && Array(packet.dropFirst(6).prefix(6)) == mac
                && Array(packet.suffix(6)) == mac
        }(), "magicPacketLayout")

        n += check({
            WakeOnLAN.parseMAC("AA:BB:CC:DD:EE:FF") == [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
                && WakeOnLAN.parseMAC("aa-bb-cc-dd-ee-ff") == [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
                && WakeOnLAN.parseMAC("aabbccddeeff") == [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
                && WakeOnLAN.parseMAC("  AA:BB:CC:DD:EE:FF ") == [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
                && WakeOnLAN.parseMAC("AA:BB:CC:DD:EE") == nil     // 缺段
                && WakeOnLAN.parseMAC("AA:BB:CC:DD:EE:FG") == nil  // 非十六进制
                && WakeOnLAN.parseMAC("00:00:00:00:00:00") == nil  // 全零无效
                && WakeOnLAN.parseMAC("") == nil
        }(), "macParsingVariants")

        return n
    }
}

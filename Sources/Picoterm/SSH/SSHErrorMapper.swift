import Foundation
import PicotermCore

// Ported from Berth (GPL-3) — github.com/xinghelee/Berth  Core/SSH/SSHErrorMapper.swift
// 适配 Picoterm 的 SSHClientError；按认证方式给出针对性排查提示
enum SSHErrorMapper {
    enum AuthMethodKind { case password, key, agent, keyboardInteractive }

    static func friendlyMessage(for error: Error,
                                authMethod: AuthMethodKind? = nil) -> String {
        if let sshError = error as? SSHClientError {
            switch sshError {
            case .dnsFailed:
                return L("无法解析主机地址：请检查主机名拼写与网络。")
            case .connectFailed:
                return L("无法建立连接：端口不通、服务未监听或被防火墙拦截（超时 10 秒）。")
            case .handshakeFailed:
                return L("SSH 握手失败：本机与服务器的加密算法没有交集，服务器可能过旧或过新。")
            case .hostKeyMismatch:
                return L("主机指纹与 known_hosts 记录不符：服务器可能被重装/更换，或正遭到中间人攻击。确认后可编辑 ~/.ssh/known_hosts 删除旧行再连。")
            case .authFailed:
                switch authMethod {
                case .password:
                    return L("认证失败：密码不正确，或服务器没有开放该用户的密码登录。")
                case .key:
                    return L("认证失败：服务器不接受这把密钥。请确认公钥已加入服务器上该用户的 ~/.ssh/authorized_keys，且用户名无误。")
                case .agent:
                    return L("认证失败：ssh-agent 中的身份未被服务器接受。")
                case .keyboardInteractive:
                    return L("认证失败：多轮质询均被拒绝（密码或 MFA 动态码错误）。")
                case .none:
                    return L("认证失败：服务器拒绝了用户名、密码或密钥。")
                }
            case .channelFailed:
                return L("会话通道打开失败：服务器可能限制了并发会话数。")
            case .sftpProtocol:
                return L("SFTP 协议错误：服务器在文件操作层拒绝了请求（嵌入式设备的 SFTP 实现可能不完整，或该路径在 SFTP 视图下不可访问）。")
            case .localFileFailed:
                return L("本地文件读写失败：请检查磁盘空间与临时目录权限。")
            case .disconnectedForSftp:
                return L("SFTP 未连接。")
            }
        }
        return String(describing: error)
    }
}

# Picoterm

**简体中文** | [English](README.en.md)

macOS 原生（Apple Silicon）SSH / 终端客户端，功能对标 [WindTerm](https://github.com/kingToolbox/WindTerm)，界面走 macOS 毛玻璃（Liquid Glass）设计。

## 功能特性

### 会话与连接

- 协议：本地 Shell、SSH、Telnet、串口
- SSH：密码 / 公钥 / agent 认证，keepalive，断线自动重连，主机字符集转换，Wake-on-LAN 一键唤醒
- 主机树分组管理、分组批量连接，凭据存 macOS Keychain
- 标签页 + 分屏，标签自定义颜色与重命名

### 终端

- 终端仿真与渲染基于 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
- 内置 190 套社区配色主题
- 终端内搜索（高亮全部匹配）、回滚行数可调
- 链接识别与点击、命令自动补全、代码片段面板

### 文件与传输

- SFTP 文件管理器：地址栏分段跳转与路径输入、隐藏文件过滤、新建 / 重命名 / 删除 / 压缩 tar.gz
- 文件属性与权限修改（八进制与勾选双向同步）、属主显示
- 本地编辑器打开远程文件，保存后提示回传
- 并行下载、拖出下载，传输监控条实时速度显示

### 运维

- 端口转发管理（本地 -L 隧道）
- 服务器状态条：CPU / 内存 / 磁盘 / 网络实时指标（逐网卡、逐挂载点可选）、进程 TOP，远端 Linux / macOS 自适应

### 安全

- 凭据 Keychain 加密存储
- 密码字段回显门禁：默认掩码，查看需显式确认

## 系统要求

- macOS 14.0 及以上，Apple Silicon（arm64）

## 构建与运行

需 Swift 6 工具链（Xcode 16+ 或独立 Command Line Tools）：

```sh
git clone https://github.com/lyxizq/Picoterm.git
cd Picoterm
Scripts/make-app.sh release
open build/Picoterm.app
```

- 无需 Homebrew：libssh2 与 openssl 经 SPM 二进制包静态链接，产物自包含——`build/Picoterm.app` 拷到其他 arm64 + macOS 14+ 机器可双击直接运行
- 单元测试：`swift run PicotermCoreTests`

## 技术栈

- Swift 6 + AppKit（终端主界面）；设置页可用 SwiftUI
- 终端仿真与渲染：[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)（MIT，vendored 于 `Vendor/`，含本地扩展）
- SSH 连接层：libssh2（[libssh2-spm](https://github.com/AkinoKaede/libssh2-spm) SPM 二进制包，openssl 静态链接）
- PTY：系统 `openpty` / `forkpty`
- 凭据存储：Keychain

## 开源协议

本项目以 [GPL-3.0](LICENSE) 协议开源——SSH / 终端相关代码移植自 [Berth](https://github.com/xinghelee/Berth) 与 [Termind](https://github.com/AkinoKaede/Termind)（均为 GPL-3.0，移植文件头部有 `// Ported from …` 标注）；内置 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)（MIT）与 libssh2（MIT）。

开发任务清单（TODO.md）与项目记忆（`.claude/memory/`）仅存于内部开发仓，不随公开仓分发。

# Picoterm

**简体中文** | [English](README.en.md)

macOS 原生（Apple Silicon）SSH / 终端客户端，功能对标 [WindTerm](https://github.com/kingToolbox/WindTerm)，界面走 macOS 毛玻璃（Liquid Glass）设计。

## 功能特性

### 会话与连接

- 协议：本地 Shell、SSH、Telnet、串口
- SSH：密码 / 公钥 / agent 认证，keepalive，主机字符集转换，Wake-on-LAN 一键唤醒
- 主机树分组管理、分组批量连接，凭据 AES-GCM 加密存储
- 标签页 + 分屏，标签自定义颜色与重命名；界面黑 / 白主题、中 / 英双语切换

### 终端

- 终端仿真与渲染基于 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
- 内置 190 套社区配色主题，选中即预览
- 终端内搜索（高亮全部匹配）、回滚行数可调
- 日志关键字着色（时间戳 / 级别 / IP / URL），清屏后登录横幅自动回插
- 链接识别与点击（⌘+点击 / 直接点击可配）、命令自动补全、代码片段面板

### 文件与传输

- SFTP 文件管理器：地址栏分段跳转与路径输入、隐藏文件过滤、新建 / 重命名 / 删除 / 压缩 tar.gz
- 目录收藏（按主机保存书签）、空格键快速预览（大文本取前后各 256KB、图片直读）
- 文件属性与权限修改（八进制与勾选双向同步）、属主显示
- 本地编辑器打开远程文件，改动自动监视并提示回传（远端在编辑期间被改过时先确认再覆盖）
- 并行下载、拖出下载，传输监控条实时速度显示

### 运维

- 端口转发管理（本地 -L 隧道）
- 服务器状态条：CPU / 内存 / 磁盘 / 网络实时指标（逐网卡、逐挂载点可选）、进程 TOP，远端 Linux / macOS 自适应

### 安全

- 凭据 AES-GCM 加密文件存储（密钥文件 0600 权限）
- 密码字段回显门禁：默认掩码，查看需通过本机身份验证（Touch ID / 登录密码）
- 主机指纹 TOFU：首次连接自动记录 known_hosts，指纹不符拒绝连接（非 22 端口按 `[host]:port` 区分）
- 远端命令全部单引号转义，防注入

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

- Swift 6 + AppKit（含设置页）
- 终端仿真与渲染：[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)（MIT，vendored 于 `Vendor/`，含本地扩展）
- SSH 连接层：libssh2（[libssh2-spm](https://github.com/AkinoKaede/libssh2-spm) SPM 二进制包，openssl 静态链接）
- PTY：系统 `openpty` / `forkpty`
- 凭据存储：AES-GCM 加密文件（CryptoKit）

## 开源协议

本项目以 [GPL-3.0](LICENSE) 协议开源——SSH / 终端相关代码移植自 [Berth](https://github.com/xinghelee/Berth) 与 [Termind](https://github.com/AkinoKaede/Termind)（均为 GPL-3.0，移植文件头部有 `// Ported from …` 标注）；内置 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)（MIT）与 libssh2（MIT）。

开发任务清单（TODO.md）与项目记忆（`.claude/memory/`）仅存于内部开发仓，不随公开仓分发。

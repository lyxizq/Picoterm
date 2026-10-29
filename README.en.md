# Picoterm

[简体中文](README.md) | **English**

A native macOS (Apple Silicon) SSH / terminal client benchmarked against [WindTerm](https://github.com/kingToolbox/WindTerm), with a Liquid Glass–style translucent UI.

## Features

### Sessions & Connections

- Protocols: local shell, SSH, Telnet, serial
- SSH: password / public key / agent authentication, keepalive, automatic reconnection, host charset conversion, one-click Wake-on-LAN
- Host tree with groups and group batch connect; credentials stored in the macOS Keychain
- Tabs + split panes, custom tab colors and renaming

### Terminal

- Terminal emulation and rendering powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
- 190 community color schemes built in
- In-terminal search (highlight all matches), adjustable scrollback
- Link detection and click-to-open, command autocomplete, snippet panel

### Files & Transfers

- SFTP file manager: segmented address bar with path input, hidden-file filter, create / rename / delete / compress to tar.gz
- File attributes and permission changes (octal and checkboxes kept in sync), owner display
- Open remote files in a local editor, with an upload-back prompt after saving
- Parallel and drag-out downloads, transfer bar with live speed

### Operations

- Port forwarding management (local `-L` tunnels)
- Server status bar: live CPU / memory / disk / network metrics (per-NIC and per-mount selectable), process TOP, adaptive to remote Linux / macOS

### Security

- Credentials encrypted in the Keychain
- Password reveal gating: masked by default, explicit confirmation required to show

## Requirements

- macOS 14.0 or later, Apple Silicon (arm64)

## Build & Run

Requires the Swift 6 toolchain (Xcode 16+ or standalone Command Line Tools):

```sh
git clone https://github.com/lyxizq/Picoterm.git
cd Picoterm
Scripts/make-app.sh release
open build/Picoterm.app
```

- No Homebrew required: libssh2 and openssl are statically linked via an SPM binary package — the product is self-contained, so `build/Picoterm.app` can be copied to any arm64 + macOS 14+ Mac and launched directly
- Unit tests: `swift run PicotermCoreTests`

## Tech Stack

- Swift 6 + AppKit (main terminal UI); SwiftUI allowed for settings pages
- Terminal emulation & rendering: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT, vendored under `Vendor/` with local extensions)
- SSH layer: libssh2 ([libssh2-spm](https://github.com/AkinoKaede/libssh2-spm) SPM binary package, statically linked openssl)
- PTY: system `openpty` / `forkpty`
- Credential storage: Keychain

## License

This project is released under the [GPL-3.0](LICENSE) license — SSH / terminal related code is ported from [Berth](https://github.com/xinghelee/Berth) and [Termind](https://github.com/AkinoKaede/Termind) (both GPL-3.0; ported files carry a `// Ported from …` header); it bundles [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) and libssh2 (MIT).

The development task list (TODO.md) and project memory (`.claude/memory/`) live only in the internal development repository and are not distributed with this public repository.

<p align="center">
  <img src="app-icon.png" width="128" alt="SSHAppInstaller">
</p>

<h1 align="center">SSHAppInstaller / SSH 应用安装器</h1>

<p align="center">
  <b>中文</b> | <a href="#english">English</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS-black" alt="platform">
  <img src="https://img.shields.io/badge/arch-universal-blue" alt="arch">
  <img src="https://img.shields.io/badge/engine-SwiftUI%20%7C%20AppKit-orange" alt="engine">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
</p>
<p align="center">
  <img src="https://img.shields.io/badge/network-offline%20100%25-8250df" alt="network">
  <img src="https://img.shields.io/badge/released-2026--09--07-0969da" alt="released">
  <img src="https://img.shields.io/github/last-commit/hwl513782273/SSHAppInstaller" alt="last commit">
  <a href="https://github.com/hwl513782273/SSHAppInstaller/releases/latest"><img src="https://img.shields.io/github/v/release/hwl513782273/SSHAppInstaller?sort=semver" alt="release"></a>
</p>

---

<p align="center">
  <a href="https://github.com/hwl513782273/SSHAppInstaller/releases/latest">下载最新版 / Download</a>
  ·
  <a href="https://github.com/hwl513782273/SSHAppInstaller/issues">问题反馈 / Issues</a>
</p>

> 一款原生 macOS 图形化工具：填一次 SSH 信息，就能把 `.app` / `.dmg` / `.pkg` 拖拽安装到另一台 Mac/Windows/Linux，附带双向传文件，类似「跨机器的应用安装器」。/ A native macOS GUI that installs `.app` / `.dmg` / `.pkg` onto another Mac, Windows or Linux over SSH with drag-and-drop, plus two-way file transfer — like a cross-machine app installer.
>
> **作者 Author：banqiu** **许可证 License：MIT**（详见 LICENSE）。可自由使用、修改与再分发，须保留版权与许可声明。



## 中文

### 主要功能

- **图形化安装**：顶部品牌头显示应用名与版本，拖入 `.app`/`.dmg`/`.pkg` 一键安装到远端 `/Applications`。
- **跨系统传输**：向 macOS / Windows（需 OpenSSH Server）/ Linux 上传、下载文件，自动识别远端系统。
- **智能识别 Windows**：连接 Windows 时显示「此电脑」所有盘符，默认上传到 D 盘，下载列出对方下载文件夹。
- **远端文件浏览**：双击进目录、单击选中；支持框选/⌘多选、图标/列表视图、显示文件大小、隐藏文件开关。
- **密钥免密**：支持 SSH 公钥认证（BatchMode），配置一次长期免输密码；也支持密码登录。
- **原生离线**：SwiftUI + AppKit 原生构建，universal 双架构，全程离线运行、零依赖。

> **平台说明 Platform Note：本工具为 macOS 原生应用（SwiftUI + AppKit，打包为 `.app` / `.dmg`），暂无 Windows / Linux 版本。**

### 快速开始

1. 在 [Releases](https://github.com/hwl513782273/SSHAppInstaller/releases/latest) 下载对应系统的 DMG（见下方「macOS 版本选择」）。
2. 打开 DMG，把 `SSHAppInstaller.app` 拖入「应用程序」。
3. 首次打开：右键 → 打开（或终端执行 `xattr -dr com.apple.quarantine /Applications/SSHAppInstaller.app`）。
4. 填写主机/IP、用户名、端口，选择密钥或密码后即可安装与传文件；历史连接自动保存可下拉切换。

从源码构建（需 macOS 12+ 与 Swift 工具链）：

```
cd SSHAppInstaller
bash build.sh
```

打包 DMG（需 macOS 自带 hdiutil）：

```
bash make_dmg.sh
# 产物：12-SSHAppInstaller-1.2.0-universal.dmg
```

### macOS 版本选择

- **Apple Silicon 与 Intel Mac — 推荐**：下载 `12-SSHAppInstaller-1.2.0-universal.dmg`（universal 双架构，macOS 12+）。
- 各档 DMG 均为 ad-hoc 签名、**未公证（notarized）**，首次打开请右键「打开」放行 Gatekeeper。各档均由同一套源码构建，源码零改动。

> 仓库「发行版 / Releases」的命名格式为：`支持最低版本-{软件英文名}-版本-架构`（如 `12-SSHAppInstaller-1.2.0-universal.dmg`）。第一段数字为该包实际支持的最低 macOS 版本号。

### 支持的功能

| 类别 | 项目 | 说明 |
|------|------|------|
| 连接 | SSH 密钥/密码认证 | 支持公钥免密（BatchMode）与密码登录 |
| 连接 | 连接历史 | 自动保存主机/IP/用户，下拉切换/删除 |
| 远端系统 | macOS / Windows / Linux | 自动识别；Windows 需开启 OpenSSH Server |
| 传输 | 上传 / 下载 | 进度条+百分比+已传/总量；scp `-s` 强制 SFTP 协议 |
| 浏览 | 远端文件树 | 双击进目录、单选、隐藏文件开关 |
| 浏览 | 此电脑根视图(Windows) | 列出所有盘符，D 盘默认上传目录 |
| 安装 | .app / .dmg / .pkg | 拖拽安装到远端 /Applications |

### 差异化亮点

- 🔌 **跨系统互联**：macOS / Windows / Linux 统一 SSH 传文件，一台 Mac 管所有机器。
- 🪟 **Windows 原生支持**：识别「此电脑」所有盘符，默认 D 盘上传，体验贴近资源管理器。
- 🔐 **密钥免密**：SSH 公钥认证，一次配置长期免输密码，自动化友好。
- 📊 **精准进度**：实时百分比 + 已传/总大小，大文件传输心里有底。
- 💾 **连接历史**：自动记忆常用主机，一键切换/删除，告别重复输入。
- 🎨 **原生体验**：SwiftUI 品牌头，浅色/深色自动适配，贴合 macOS 视觉。

### 已知限制

- **Windows 需开 OpenSSH Server**：目标 Windows 机须先开启「OpenSSH 服务器」可选功能，否则无法连接。
- **未公证**：应用为 ad-hoc 签名、未送 Apple 公证，首次打开请右键「打开」放行 Gatekeeper。
- **远端默认目录**：浏览默认进入对方下载文件夹；macOS 目标机需开启「系统设置 → 通用 → 共享 → 远程登录」。

## English

### Highlights

- **Graphical install**: drag `.app` / `.dmg` / `.pkg` onto the window to install on the remote `/Applications`.
- **Cross-platform transfer**: upload/download to macOS / Windows (OpenSSH Server required) / Linux, with auto OS detection.
- **Windows aware**: lists every drive under "This PC", defaults uploads to D:, shows the remote Downloads folder.
- **Remote browser**: double-click to enter folders, box/⌘ multi-select, icon & list views, size column, hidden-file toggle.
- **Key-based auth**: SSH public-key (BatchMode) for passwordless login, or password login.
- **Native & offline**: SwiftUI + AppKit, universal binary, fully offline, zero dependencies.

> **Platform Note: this is a native macOS app (SwiftUI + AppKit, packaged as `.app` / `.dmg`). There is no Windows / Linux build.**

### Quick start

1. Download the DMG for your system from [Releases](https://github.com/hwl513782273/SSHAppInstaller/releases/latest) (see "Choose a macOS build" below).
2. Open the DMG and drag `SSHAppInstaller.app` into "Applications".
3. First launch: right-click → Open (or run `xattr -dr com.apple.quarantine /Applications/SSHAppInstaller.app`).
4. Fill host/IP, user and port, pick key or password, then install & transfer; history is auto-saved and switchable.

Build from source (requires macOS 12+ and the Swift toolchain):

```
cd SSHAppInstaller
bash build.sh
```

Package the DMG (requires macOS hdiutil):

```
bash make_dmg.sh
# output: 12-SSHAppInstaller-1.2.0-universal.dmg
```

### Choose a macOS build

- **Apple Silicon & Intel Mac — Recommended**: download `12-SSHAppInstaller-1.2.0-universal.dmg` (universal, macOS 12+).
- All DMGs are ad-hoc signed and **not notarized**. Right-click → Open on first launch to pass Gatekeeper. All variants are built from the same source with zero modification.

> Release naming format: `minimum-macOS-version-{software}-version-arch` (e.g. `12-SSHAppInstaller-1.2.0-universal.dmg`).

### Supported features

| Category | Item | Description |
|----------|------|-------------|
| Connection | SSH key / password | Public-key (BatchMode) passwordless or password login |
| Connection | History | Auto-saves host/IP/user; switch/delete from dropdown |
| Remote OS | macOS / Windows / Linux | Auto-detected; Windows needs OpenSSH Server |
| Transfer | Upload / Download | Progress + percent + sent/total; `scp -s` forces SFTP |
| Browser | Remote tree | Double-click to enter, single select, hidden toggle |
| Browser | This PC (Windows) | Lists all drives, D: default upload |
| Install | .app / .dmg / .pkg | Drag to install on remote /Applications |

### Why this tool

- 🔌 **Cross-platform**: one Mac manages files on macOS / Windows / Linux over SSH.
- 🪟 **Windows native**: enumerates every drive under "This PC", defaults to D:.
- 🔐 **Passwordless keys**: SSH public-key auth, configure once.
- 📊 **Accurate progress**: live percent + sent/total size.
- 💾 **Connection history**: remembers hosts, one-click switch/delete.
- 🎨 **Native feel**: SwiftUI header, light/dark adaptive.

### Known limitations

- **Windows needs OpenSSH Server**: enable the "OpenSSH Server" optional feature on the target first.
- **Not notarized**: ad-hoc signed; right-click → Open on first launch.
- **Default remote dir**: browser opens the remote Downloads folder; macOS targets need "Remote Login" enabled.

## 隐私与安全 / Privacy and security

- 全程本地运行，不收集、不上传任何数据 / Runs entirely locally; no telemetry or uploads.
- SSH 私钥留存本机，连接历史存于本机 UserDefaults / Keys stay on your Mac; history is kept in UserDefaults.
- 应用未公证（notarized），请仅从你信任的来源获取，首次打开右键放行 / Not notarized; obtain only from trusted sources and right-click to open.

## 许可证 / License

> **MIT License** — 版权归 **banqiu** 所有（2026）。
>
> - 允许个人与商业免费使用、修改、再分发，须保留版权与许可声明。
> - 完整条款见 [LICENSE](https://github.com/hwl513782273/SSHAppInstaller/blob/main/LICENSE)。

## 支持 / Support

SSH 应用安装器是一款免费开源工具，基于 MIT 许可发布，离线、无广告。如果你觉得好用，欢迎在 GitHub 上点个 Star，或反馈问题 / 提交 PR 帮它变得更好 —— 纯自愿。 SSHAppInstaller is free, open-source, and ad-free. If it helps you, a GitHub Star or an issue/PR is warmly welcome — entirely optional.

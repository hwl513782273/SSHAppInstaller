# SSHAppInstaller / SSH 应用安装器

> 一款原生 macOS 图形化工具：填一次 SSH 信息，就能把 `.app` / `.dmg` / `.pkg` 拖拽安装到另一台 Mac 的 /Applications，附带双向传文件，类似「跨 Mac 的应用安装器」。
> A native macOS GUI that installs `.app` / `.dmg` / `.pkg` onto another Mac over SSH with drag-and-drop, plus two-way file transfer — like a cross-Mac app installer.

> **作者 Author：banqiu**
>
> **许可证 License：MIT**（详见 [LICENSE](https://github.com/hwl513782273/SSHAppInstaller/blob/main/LICENSE)）。可自由使用、修改与再分发，须保留版权与许可声明。

![SSHAppInstaller 图标](app-icon.png)

[下载最新版 / Download](https://github.com/hwl513782273/SSHAppInstaller/releases/latest) · [问题反馈 / Issues](https://github.com/hwl513782273/SSHAppInstaller/issues)

---

## 中文

### 主要功能

- 原生 SwiftUI 界面：SSH 连接配置集中在一处，主机 / 端口 / 用户名 / 认证方式一次填好，连接成功后自动记住（密码除外）。
- 图形化远程安装：把 `.app` / `.dmg` / `.pkg` 拖进窗口（支持多个），一键批量安装到目标机的 `/Applications`；非这三种格式会即时提示不支持。
- 智能安装策略：dmg 自动挂载并定位其中的 .app；安装采用「暂存 → 备份旧版 → 就位」的原子替换，中途失败自动回滚，不会出现旧的删了、新的没装上。
- 双向传文件：上传支持拖入多个文件 / 文件夹；下载默认定位到对方下载文件夹，远端是文件夹时先二次确认，避免误下整个目录。
- 双认证方式：SSH 密钥（含自定义密钥路径）或密码二选一；写 `/Applications` 需要的 sudo 密码单独输入，仅驻留内存、从不落盘。
- 全程日志可视化：每一步（上传 / 挂载 / 复制 / 去隔离）都写进日志区并自动滚动，成功与失败都有浮窗提示。

> **平台说明 Platform Note：本工具为 macOS 原生应用（SwiftUI + AppKit，swiftc 直接编译并打包为 `.app` / `.dmg`），暂无 Windows / Linux 版本。**

### 快速开始

1. 在 [Releases](https://github.com/hwl513782273/SSHAppInstaller/releases/latest) 下载对应系统的 DMG（见下方「macOS 版本选择」）。
2. 打开 DMG，把 `SSHAppInstaller.app` 拖入「应用程序」。
3. 首次打开：右键 → 打开（或终端执行 `xattr -dr com.apple.quarantine /Applications/SSHAppInstaller.app`）。
4. 填好目标机的主机 / 用户名并测试连接，然后把安装包拖进「安装软件」页，点「安装到远端」。

从源码构建（需 macOS 12+ 与 Xcode Command Line Tools 的 Swift 工具链）：

```
git clone https://github.com/hwl513782273/SSHAppInstaller.git
cd SSHAppInstaller
bash build.sh
```

打包 DMG（仅需系统自带 hdiutil）：

```
bash make_dmg.sh
```

### macOS 版本选择

- **Apple Silicon（M1 及更新）— 推荐**：下载 `15-SSHAppInstaller-1.0-beta4-universal.dmg`（当前版本为 arm64 构建，macOS 12+ 可运行）。
- **Intel Mac**：当前版本未内置 x86_64 产物，请从源码构建（`swiftc` 支持 `--target x86_64-apple-macos12` 交叉编译）。

> DMG 为 ad-hoc 签名、**未公证（notarized）**，首次打开请右键「打开」放行 Gatekeeper。

> 仓库「发行版 / Releases」的命名格式为：`支持最低版本-SSHAppInstaller-版本-架构`。第一段数字为该包实际支持的最低 macOS 版本号。

### 支持的功能

| 类别 | 项目 | 说明 |
|------|------|------|
| 安装格式 | .app | 自动移除旧版并原子替换到 /Applications，清除隔离标记 |
| 安装格式 | .dmg | 自动挂载（随机挂载点）、定位内部 .app 后走同一安装流程，用完即卸载 |
| 安装格式 | .pkg | 调用系统 installer 安装到根目录 |
| 传输方向 | 上传 | 本机多个文件 / 文件夹 → 远端任意目录（默认对方下载文件夹） |
| 传输方向 | 下载 | 远端文件 / 文件夹 → 本机；远端为文件夹时二次确认后递归下载 |
| 认证方式 | SSH 密钥 / 密码 | 密钥支持自定义路径；密码经 SSH_ASKPASS 机制传递，不写磁盘 |

### 差异化亮点

- 🖱 **告别命令行**：不用敲一行 ssh / scp / hdiutil，拖进去、点一下就装好。
- 🧷 **原子替换安装**：先暂存再替换，失败自动回滚旧版，目标机不会出现「应用被删了却没装上」的中间态。
- 📁 **远端也能浏览选择**：下载路径不再靠手敲，连接后可直接浏览对方文件系统点选文件或文件夹。
- 🔒 **密码零落盘**：登录密码与 sudo 密码只在内存里；askpass 助手写在随机 0700 临时目录、退出即清理。
- ⏱ **超时兜底不卡死**：所有 SSH / scp 操作带分层超时，网络挂起时自动终止并给出明确错误。
- 📜 **日志全程可回溯**：安装 / 传输每一步都进日志区，出问题一眼定位到哪一步。

### 已知限制

- 目标机需要开启「远程登录」（系统设置 → 通用 → 共享），且写 /Applications 时需要管理员权限（sudo 密码或免密 sudo）。
- 当前版本的 DMG 为 arm64 构建，Intel Mac 需从源码构建。

## English

### Highlights

- Native SwiftUI interface: host / port / user / auth configured in one place, remembered on successful connection (except passwords).
- Drag-and-drop remote install: drop multiple `.app` / `.dmg` / `.pkg` files and install them to the remote `/Applications` in one click; other formats are rejected with an instant notice.
- Smart install strategy: DMGs are auto-mounted and their .app located; installs use a staging-then-swap atomic replace that rolls back on failure.
- Two-way transfer: upload multiple local files/folders; download defaults to the remote Downloads folder, with a confirmation dialog when the remote path is a directory.
- Two auth modes: SSH key (custom path supported) or password; the sudo password required for /Applications is entered separately and never written to disk.
- Full log visibility: every step (upload / mount / copy / quarantine removal) is logged with auto-scrolling, plus toast notifications for success and failure.

> **Platform Note: this is a native macOS app (SwiftUI + AppKit, compiled with swiftc and packaged as `.app` / `.dmg`). There is no Windows / Linux build.**

### Quick start

1. Download the DMG for your system from [Releases](https://github.com/hwl513782273/SSHAppInstaller/releases/latest) (see "Choose a macOS build" below).
2. Open the DMG and drag `SSHAppInstaller.app` into "Applications".
3. First launch: right-click → Open (or run `xattr -dr com.apple.quarantine /Applications/SSHAppInstaller.app`).
4. Fill in the target Mac's host / username and test the connection, then drop installers into the Install tab and click the install button.

Build from source (requires macOS 12+ and the Swift toolchain from Xcode Command Line Tools):

```
git clone https://github.com/hwl513782273/SSHAppInstaller.git
cd SSHAppInstaller
bash build.sh
```

Package the DMG (requires only the built-in hdiutil):

```
bash make_dmg.sh
```

### Choose a macOS build

- **Apple Silicon (M1 or newer) — Recommended**: download `15-SSHAppInstaller-1.0-beta4-universal.dmg` (arm64 build, runs on macOS 12+).
- **Intel Mac**: no prebuilt x86_64 artifact yet; please build from source (`swiftc --target x86_64-apple-macos12`).

> The DMG is ad-hoc signed and **not notarized**. Right-click → Open on first launch to pass Gatekeeper.

> Release naming format: `minimum-macOS-version-SSHAppInstaller-version-arch`. The first number is the minimum macOS version the package actually supports.

### Supported features

| Category | Item | Description |
|----------|------|-------------|
| Install | .app | Removes the old copy and atomically replaces it in /Applications, clearing quarantine |
| Install | .dmg | Auto-mounts at a random mount point, locates the inner .app, then follows the same install flow |
| Install | .pkg | Invokes the system installer against the root volume |
| Transfer | Upload | Multiple local files/folders → any remote directory (defaults to the remote Downloads folder) |
| Transfer | Download | Remote file/folder → local; directories require an explicit confirmation before recursive download |
| Auth | SSH key / password | Custom key path supported; passwords go through the SSH_ASKPASS mechanism, never written to disk |

### Why this tool

- 🖱 **No command line**: not a single ssh / scp / hdiutil invocation — drop files, click a button.
- 🧷 **Atomic replace**: staging first, then swap; failures roll back so the remote Mac is never left with the app deleted but nothing installed.
- 📁 **Remote path picker**: pick remote files or folders visually instead of typing paths.
- 🔒 **Zero on-disk secrets**: login and sudo passwords live only in memory; the askpass helper sits in a random 0700 temp directory and is cleaned up on exit.
- ⏱ **Timeout guardrails**: every SSH / scp operation has tiered timeouts, so a hung network terminates with a clear error instead of freezing the UI.
- 📜 **Traceable logs**: each step lands in the log panel with auto-scroll for quick diagnosis.

### Known limitations

- The target Mac must have Remote Login enabled (System Settings → General → Sharing), and installing into /Applications requires administrator rights.
- The current DMG is an arm64 build; Intel Mac users need to build from source.

## 隐私与安全 / Privacy and security

- 全程只在本机与目标机之间直连（ssh / scp），不经过任何第三方服务器；登录密码与 sudo 密码仅驻留内存，从不写盘、不随配置持久化。/ All traffic goes directly between your Mac and the target over ssh/scp; passwords stay in memory only and are never persisted.
- 连接配置（主机 / 端口 / 用户名 / 密钥路径）保存在本机 UserDefaults，可随时清除；askpass 助手脚本位于随机命名的 0700 临时目录并在退出时删除。/ Connection settings live in local UserDefaults; the askpass helper uses a random 0700 temp directory removed on exit.
- 应用未公证（notarized），请仅从你信任的来源获取，并在首次打开时右键放行。/ The app is not notarized — obtain it only from sources you trust and allow it via right-click on first launch.

## 许可证 / License

> **MIT License** — 版权归 **banqiu** 所有（2026）。
>
> - 允许个人与商业免费使用、修改、再分发，须保留版权与许可声明。
> - 完整条款见 [LICENSE](https://github.com/hwl513782273/SSHAppInstaller/blob/main/LICENSE)。

## 支持 / Support

SSHAppInstaller 是一款免费开源工具，基于 MIT 许可发布，离线、无广告。如果你觉得好用，欢迎在 GitHub 上点个 Star，或反馈问题 / 提交 PR 帮它变得更好 —— 纯自愿。 SSHAppInstaller is free, open-source, and ad-free under the MIT License. If it helps you, a GitHub Star or an issue/PR is warmly welcome — entirely optional.

import SwiftUI
import AppKit

// MARK: - 成功浮窗类型（决定浮窗显示位置）
enum ToastTarget { case window, transferBox }
struct ToastInfo: Equatable {
    let message: String
    let target: ToastTarget
    let id = UUID()      // 每条提示唯一,确保 SwiftUI 一定识别为变化并重播动画
}

// MARK: - 远端文件条目（浏览器用）
struct RemoteEntry: Identifiable, Equatable, Hashable {
    let name: String
    let isDir: Bool
    let size: Int64      // 字节；目录无意义但 ls -l 仍会给值，仅列表视图展示用
    var id: String { name }
}

// MARK: - 传输进度（value=nil 表示不确定进度/转圈；sizeText 如 "12.3 MB / 28.6 MB"）
struct TransferProgress: Equatable {
    let label: String
    let value: Double?
    let sizeText: String?
}

// MARK: - 远端操作系统类型（决定远端命令分支与默认路径）
enum RemoteOS: String {
    case macOS = "Mac"
    case windows = "Windows"
    case linux = "Linux"
    case unknown = "未知"
}

// MARK: - 连接历史（主机/IP/用户名自动保存，可下拉切换/删除）
struct ConnHistoryItem: Codable, Identifiable, Equatable {
    var id: String { "\(user)@\(host):\(port)" }
    var host: String
    var port: String
    var user: String
    var useKey: Bool
}

// MARK: - SSH 执行核心
final class SSHClient: ObservableObject {
    @Published var isBusy: Bool = false
    @Published var log: String = ""
    @Published var connectionOK: Bool = false
    @Published var toast: ToastInfo? = nil   // 成功浮窗(含显示位置)
    @Published var progress: TransferProgress? = nil   // 安装/上传/下载进度条
    @Published var remoteOS: RemoteOS = .unknown   // 连接测试成功后探测
    @Published var history: [ConnHistoryItem] = [] // 连接历史（测试连接成功自动保存）
    private var windowsDownloadsPath: String = ""  // Windows 探测到的真实下载目录（如 E:/下载）
    private var windowsHasDDrive: Bool = false     // Windows 是否存在 D 盘（上传默认落 D 盘）
    private var toastDismissWork: DispatchWorkItem? = nil

    func setProgress(_ label: String, _ value: Double?, sizeText: String? = nil) {
        DispatchQueue.main.async { self.progress = TransferProgress(label: label, value: value, sizeText: sizeText) }
    }
    func clearProgress() {
        DispatchQueue.main.async { self.progress = nil }
    }

    // 自动消失:新提示先取消上一条的清除任务,清除时只清自己那条(id 比对),彻底避免竞态残留
    func showToast(_ s: String, target: ToastTarget = .window) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let info = ToastInfo(message: s, target: target)
            self.toast = info
            self.toastDismissWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if self.toast?.id == info.id { self.toast = nil }
            }
            self.toastDismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
        }
    }

    // 连接配置（均为内存态，密码不落盘）
    var host: String = ""
    var port: String = "22"
    var user: String = ""
    var useKey: Bool = true          // true = 密钥, false = 密码
    var keyPath: String = ""
    var password: String = ""        // 仅在内存,从不明文写文件
    var sudoPassword: String = ""      // sudo 提权密码(写 /Applications 需要)

    private func portStr() -> String { port.isEmpty ? "22" : port }

    // 记住上次连接成功的配置(密码不持久化)
    func saveConnection() {
        let d = UserDefaults.standard
        d.set(host, forKey: "ssh_host")
        d.set(port, forKey: "ssh_port")
        d.set(user, forKey: "ssh_user")
        d.set(useKey, forKey: "ssh_useKey")
        d.set(keyPath, forKey: "ssh_keyPath")
    }

    func loadConnection() {
        let d = UserDefaults.standard
        if let h = d.string(forKey: "ssh_host"), !h.isEmpty { host = h }
        if let p = d.string(forKey: "ssh_port"), !p.isEmpty { port = p }
        if let u = d.string(forKey: "ssh_user"), !u.isEmpty { user = u }
        if d.object(forKey: "ssh_useKey") != nil { useKey = d.bool(forKey: "ssh_useKey") }
        if let k = d.string(forKey: "ssh_keyPath") { keyPath = k }
    }

    init() {
        loadConnection()
        loadHistory()
    }

    // MARK: 连接历史（UserDefaults JSON 数组，去重置顶，上限 20 条）
    private let historyKey = "conn_history"

    private func loadHistory() {
        if let d = UserDefaults.standard.data(forKey: historyKey),
           let arr = try? JSONDecoder().decode([ConnHistoryItem].self, from: d) {
            history = arr
        }
    }

    private func persistHistory() {
        if let d = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(d, forKey: historyKey)
        }
    }

    private func addHistory() {
        let ep = trimmedEndpoint(host: host, user: user, port: port)
        guard !ep.host.isEmpty, !ep.user.isEmpty else { return }
        history.removeAll { $0.host == ep.host && $0.port == ep.port && $0.user == ep.user }
        history.insert(ConnHistoryItem(host: ep.host, port: ep.port, user: ep.user, useKey: useKey), at: 0)
        if history.count > 20 { history = Array(history.prefix(20)) }
        persistHistory()
    }

    func deleteHistory(_ item: ConnHistoryItem) {
        history.removeAll { $0.id == item.id }
        persistHistory()
    }

    /// 切换到某条历史连接（填充全部连接字段，旧连接状态作废）
    func applyHistory(_ item: ConnHistoryItem) {
        host = item.host
        port = item.port
        user = item.user
        useKey = item.useKey
        connectionOK = false
        remoteOS = .unknown
    }

    private func append(_ s: String) {
        DispatchQueue.main.async {
            self.log += s + "\n"
            // 限长：长任务会持续追加，超大字符串会让 SwiftUI 渲染明显变卡
            let limit = 20000
            if self.log.count > limit { self.log = String(self.log.suffix(limit)) }
        }
    }
    func clearLog() { DispatchQueue.main.async { self.log = "" } }

    // MARK: askpass 助手（脚本只回显环境变量里的密码，自身不含密码）
    // 安全要求：路径不可预测 + 仅本人可访问。
    // 原实现写在固定路径、且不校验已有文件的内容与属主，任何人抢先创建该文件
    // 就能通过 SSH_ASKPASS_PASSWORD 截获密码（CWE-377 不安全的临时文件）。
    private var askpassDir: URL? = nil
    private var askpassScript: String? = nil

    private func askpassHelperPath() -> String? {
        if let s = askpassScript { return s }
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sshappinstaller_\(UUID().uuidString)", isDirectory: true)
        let scriptURL = base.appendingPathComponent("askpass.sh")
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let script = "#!/bin/sh\necho \"$SSH_ASKPASS_PASSWORD\"\n"
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            askpassDir = base
            askpassScript = scriptURL.path
            return scriptURL.path
        } catch {
            append("✗ askpass 助手创建失败:\(error.localizedDescription)")
            return nil
        }
    }

    // 退出时清理自己创建的临时目录（仅本人生前创建的那个，路径随机、权限 0700）
    deinit {
        if let d = askpassDir { try? FileManager.default.removeItem(at: d) }
    }

    private func sshArgs() -> [String] {
        var a: [String] = ["-o", "StrictHostKeyChecking=no",
                           "-o", "UserKnownHostsFile=/dev/null",
                           "-o", "LogLevel=ERROR",
                           "-p", portStr()]
        if useKey {
            if !keyPath.isEmpty { a += ["-i", keyPath] }
            a += ["-o", "BatchMode=yes"]
        } else {
            a += ["-o", "BatchMode=no"]
        }
        return a
    }

    private func scpArgs() -> [String] {
        // -s 强制 SFTP 子系统协议：绕开 legacy scp 模式（伪 tty 下默认走 legacy，需远端有 /usr/bin/scp，
        // Windows OpenSSH 7.7 的 scp.exe 在 C:\Windows\System32\OpenSSH\ 下，legacy 走 cmd 解析易在含空格/中文/盘符冒号的路径上挂）
        var a: [String] = ["-s",
                           "-o", "StrictHostKeyChecking=no",
                           "-o", "UserKnownHostsFile=/dev/null",
                           "-o", "LogLevel=ERROR",
                           "-r",
                           "-P", portStr()]
        if useKey {
            if !keyPath.isEmpty { a += ["-i", keyPath] }
            a += ["-o", "BatchMode=yes"]
        } else {
            a += ["-o", "BatchMode=no"]
        }
        return a
    }

    /// 统一子进程执行：并发抽干 out/err（避免管道写满死锁）+ 超时终止（避免网络挂起卡死）
    /// onOutput：stdout 每读到一块就实时回调（scp 进度解析用），不影响最终返回值
    private func run(launch: String, args: [String], usePassword: Bool, timeout: TimeInterval = 600,
                     onOutput: ((Data) -> Void)? = nil) -> (Bool, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launch)
        proc.arguments = args
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        var env = ProcessInfo.processInfo.environment
        if usePassword && !password.isEmpty {
            guard let helper = askpassHelperPath() else {
                return (false, "密码助手创建失败，无法使用密码认证")
            }
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["SSH_ASKPASS"] = helper
            env["SSH_ASKPASS_PASSWORD"] = password
            env["DISPLAY"] = ":0"
        }
        proc.environment = env
        let startedAt = Date()
        do {
            try proc.run()
        } catch {
            return (false, "启动失败: \(error)")
        }

        // 顺序关键：先并发抽干两个管道，再 waitUntilExit。
        // 若先 waitUntilExit，子进程输出一旦超过管道缓冲区(约 64KB)就会阻塞写入，
        // 而父进程正卡在 waitUntilExit 等它退出 —— 双向死等，界面永久卡死。
        let group = DispatchGroup()
        let lock = NSLock()
        var outBuf = Data()
        var errBuf = Data()

        group.enter()
        DispatchQueue.global().async {
            var buf = Data()
            while true {
                let d = out.fileHandleForReading.availableData
                if d.isEmpty { break }
                buf.append(d)
                onOutput?(d)
            }
            lock.lock(); outBuf = buf; lock.unlock()
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            var buf = Data()
            while true {
                let d = err.fileHandleForReading.availableData
                if d.isEmpty { break }
                buf.append(d)
            }
            lock.lock(); errBuf = buf; lock.unlock()
            group.leave()
        }

        // 超时保护：到点仍未结束就终止子进程（管道随即 EOF，上面的读取循环会自然退出）
        let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        group.wait()
        proc.waitUntilExit()
        killer.cancel()

        lock.lock()
        let o = String(data: outBuf, encoding: .utf8) ?? ""
        let e = String(data: errBuf, encoding: .utf8) ?? ""
        lock.unlock()

        let text = o + e
        if proc.terminationStatus == 0 { return (true, text) }
        if Date().timeIntervalSince(startedAt) >= timeout - 0.5 {
            return (false, "✗ 操作超时（超过 \(Int(timeout)) 秒已终止）\n" + text)
        }
        return (false, text)
    }

    // 在远端执行命令；sudo=true 时需要管理员权限。
    // command 里所有来自外部的路径/文件名，调用方必须先用 shellQuote() 包过。
    func remote(_ command: String, sudo: Bool = false, timeout: TimeInterval = 300) -> (Bool, String) {
        let ep = trimmedEndpoint(host: host, user: user, port: port)
        var a = sshArgs()
        a.append("\(ep.user)@\(ep.host)")
        let wrapped: String
        if sudo {
            let pw = !sudoPassword.isEmpty ? sudoPassword : (!useKey ? password : "")
            wrapped = pw.isEmpty
                ? "sudo \(command)"
                : "printf '%s\\n' \(shellQuote(pw)) | sudo -S \(command)"
        } else {
            wrapped = command
        }
        a.append(wrapped)
        return run(launch: "/usr/bin/ssh", args: a, usePassword: !useKey, timeout: timeout)
    }

    // 远端路径不额外加引号：新版 scp 走 SFTP 协议，路径由 sftp-server 按字面处理，
    // 额外转义反而会把反斜杠当真实字符。本地路径经 Process 参数直传，也不经 shell。
    func scpUp(local: String, remote: String, timeout: TimeInterval = 1800) -> (Bool, String) {
        scpTransfer(download: false, remotePath: remote, localPath: local, timeout: timeout)
    }

    func scpDown(remote: String, local: String, timeout: TimeInterval = 1800) -> (Bool, String) {
        scpTransfer(download: true, remotePath: remote, localPath: local, timeout: timeout)
    }

    /// scp 传输（带进度条）：scp 只在 tty 下输出进度，用 `script` 伪造伪 tty 激活它，
    /// 实时解析输出里的 "xx%" 更新进度条。密码认证依赖 SSH_ASKPASS_REQUIRE=force
    /// （OpenSSH 8.4+，macOS 12 自带 8.6 满足），有 tty 也会走 askpass 而不是交互提示。
    private func scpTransfer(download: Bool, remotePath: String, localPath: String, timeout: TimeInterval) -> (Bool, String) {
        let ep = trimmedEndpoint(host: host, user: user, port: port)
        var scpCmd = ["/usr/bin/scp"] + scpArgs()
        if download {
            scpCmd += ["\(ep.user)@\(ep.host):\(remotePath)", localPath]
        } else {
            scpCmd += [localPath, "\(ep.user)@\(ep.host):\(remotePath)"]
        }
        let label = "\(download ? "下载" : "上传") \((localPath as NSString).lastPathComponent)"
        setProgress(label, 0)
        let (ok, out) = run(launch: "/usr/bin/script",
                            args: ["-q", "/dev/null"] + scpCmd,
                            usePassword: !useKey, timeout: timeout) { [weak self] data in
            guard let s = String(data: data, encoding: .utf8) else { return }
            // scp 伪 tty 进度行形如: "文件名  42%  12MB  5.2MB/s  00:05"（\r 原地刷新）
            // 提取百分比 + 已传大小；总大小 = 已传 ÷ 百分比
            for line in s.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
                let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).filter { !$0.isEmpty }
                guard let i = tokens.firstIndex(where: { tok in
                    tok.hasSuffix("%") && Double(tok.dropLast()) != nil
                }) else { continue }
                guard let v = Double(tokens[i].dropLast()), v >= 0, v <= 100 else { continue }
                var sizeText: String? = nil
                if i + 1 < tokens.count {
                    let transferred = Self.parseSizeBytes(String(tokens[i + 1]))
                    if transferred > 0, v > 0 {
                        let total = Double(transferred) / (v / 100.0)
                        sizeText = "\(Self.formatBytes(transferred)) / \(Self.formatBytes(Int64(total)))"
                    } else if transferred > 0 {
                        sizeText = Self.formatBytes(transferred)
                    }
                }
                self?.setProgress(label, min(v / 100.0, 1.0), sizeText: sizeText)
            }
        }
        clearProgress()
        return (ok, out)
    }

    /// "12.3MB" / "512KB" / "4B" → 字节数（scp 进度用 1024 进制近似）
    private static func parseSizeBytes(_ s: String) -> Int64 {
        let units: [(String, Double)] = [("GB", 1_073_741_824.0), ("MB", 1_048_576.0), ("KB", 1_024.0), ("B", 1.0)]
        for (u, f) in units where s.hasSuffix(u) {
            let num = Double(s.dropLast(u.count)) ?? 0
            return Int64(num * f)
        }
        return Int64(Double(s) ?? 0)
    }

    private static func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    func test() -> Bool {
        if let err = validateEndpoint(host: host, user: user, port: port) {
            append("✗ \(err)")
            connectionOK = false
            return false
        }
        let ep = trimmedEndpoint(host: host, user: user, port: port)
        append("· 测试连接 \(ep.user)@\(ep.host) ...")
        let (ok, out) = remote("echo __ssh_ok__", timeout: 15)   // 连接测试不该久等
        connectionOK = ok
        if ok {
            append("✔ 连接成功")
            saveConnection()
            addHistory()
            probeRemoteOS()
        } else {
            append("✗ 连接失败:\(out)")
        }
        return ok
    }

    /// 远端系统探测：Windows 的 sshd 默认 shell 是 cmd.exe，`echo %OS%` 会展开为 Windows_NT，
    /// POSIX shell 则原样输出字面量 —— 据此区分；POSIX 再用 uname 细分 macOS/Linux。
    /// Windows 顺带探测真实下载目录（用户可能把"下载"重定向到其他盘，如 E:\下载）。
    func probeRemoteOS() {
        let (ok1, out1) = remote("echo %OS%", timeout: 15)
        let o1 = out1.trimmingCharacters(in: .whitespacesAndNewlines)
        if ok1, o1.contains("Windows_NT") {
            remoteOS = .windows
            // shell:Downloads 是系统认定的下载文件夹，重定向后仍准确
            let ps = "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; " +
                     "Write-Output ((New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path)"
            let cmd = "powershell -NoProfile -EncodedCommand \(encodePSCommand(ps))"
            let (_, out) = remote(cmd, timeout: 30)
            let p = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.contains(":") {
                windowsDownloadsPath = p.replacingOccurrences(of: "\\", with: "/")
                append("· Windows 下载目录：\(windowsDownloadsPath)")
            }
            // D 盘存在性（Windows 上传默认落 D 盘）
            let ps2 = "Write-Output (Test-Path 'D:\\')"
            let cmd2 = "powershell -NoProfile -EncodedCommand \(encodePSCommand(ps2))"
            let (_, out2) = remote(cmd2, timeout: 30)
            windowsHasDDrive = out2.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("true")
            append("· Windows 上传默认目录：\(windowsHasDDrive ? "D:/" : (windowsDownloadsPath.isEmpty ? "C:/" : windowsDownloadsPath))")
        } else {
            let (_, out2) = remote("uname -s", timeout: 15)
            let u = out2.trimmingCharacters(in: .whitespacesAndNewlines)
            remoteOS = u.contains("Darwin") ? .macOS : (u.contains("Linux") ? .linux : .unknown)
        }
        append("· 远端系统：\(remoteOS.rawValue)")
    }

    /// 远端默认下载目录（按探测到的系统分支；Windows 优先用探测到的真实路径）
    func defaultRemoteDownloads() -> String {
        if remoteOS == .windows {
            if !windowsDownloadsPath.isEmpty {
                return windowsDownloadsPath.hasSuffix("/") ? windowsDownloadsPath : windowsDownloadsPath + "/"
            }
            if !user.isEmpty {
                return "C:/Users/\(user)/Downloads/"
            }
        }
        if user.isEmpty { return "" }
        return "/Users/\(user)/Downloads/"
    }

    /// Windows 浏览根：虚拟"此电脑"视图，列出所有硬盘
    static let pcRoot = "此电脑"

    /// 浏览框初始目录：Windows 显示所有硬盘（虚拟"此电脑"视图）；macOS/Linux 落到下载目录
    func initialBrowsePath() -> String {
        if remoteOS == .windows { return Self.pcRoot }
        let d = defaultRemoteDownloads()
        return d.isEmpty ? "." : d
    }

    /// 上传默认目标目录：Windows 优先 D 盘（无 D 盘回落下载目录）；macOS/Linux 用下载目录
    func defaultUploadFolder() -> String {
        if remoteOS == .windows, windowsHasDDrive { return "D:/" }
        return defaultRemoteDownloads()
    }

    /// PowerShell 单引号字符串转义（内部单引号翻倍）
    func shellQuotePS(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// PowerShell -EncodedCommand 需要 UTF-16LE Base64（避开 cmd.exe 引号地狱）
    func encodePSCommand(_ s: String) -> String {
        var bytes: [UInt8] = []
        for unit in s.utf16 {
            let v = UInt16(unit)
            bytes.append(UInt8(v & 0xFF))
            bytes.append(UInt8(v >> 8))
        }
        return Data(bytes).base64EncodedString()
    }

    // 安装本地软件包到远端 /Applications
    func install(localPath: String) {
        if remoteOS == .windows {
            append("✗ 远端是 Windows，不支持安装 macOS 应用（.app/.dmg/.pkg），仅支持双向传文件")
            return
        }
        let name = (localPath as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        append("▶ 开始安装:\(name)")

        if let err = validateEndpoint(host: host, user: user, port: port) {
            append("✗ \(err)")
            return
        }
        guard ["app", "dmg", "pkg"].contains(ext) else {
            append("✗ 不支持的格式:\(ext)(仅支持 .app/.dmg/.pkg)")
            return
        }

        // 临时包名加 UUID，避免与远端 /tmp 下同名文件冲突
        let tmpRemote = "/tmp/sshai_\(UUID().uuidString)_\(name)"
        defer {
            // 成功失败都清理远端临时包，不再出现失败分支漏删导致 /tmp 堆积
            let _ = remote("rm -rf \(shellQuote(tmpRemote))", timeout: 60)
            clearProgress()   // 安装结束(无论成败)都撤掉进度条
        }

        append("· 上传到目标机 ...")
        let (ok1, o1) = scpUp(local: localPath, remote: tmpRemote)
        if !ok1 { append("✗ 上传失败:\(o1)"); return }

        // 上传完成，远端安装阶段无法量化，显示转圈
        setProgress("在远端安装 \(name) …", nil)

        switch ext {
        case "app": installAppBundle(fromRemote: tmpRemote, name: name)
        case "dmg": installDMG(fromRemote: tmpRemote)
        default:    installPKG(fromRemote: tmpRemote, name: name)
        }
    }

    /// 把远端某处的 .app 原子地装进 /Applications：
    /// 先复制到隐藏暂存区 → 旧版 mv 成备份 → 暂存区 mv 成正式名 → 成功才删备份。
    /// 任何一步失败都回滚，绝不会出现「旧的删了、新的没装上」。
    private func installAppBundle(fromRemote source: String, name: String) {
        let dest = "/Applications/\(name)"
        let staging = "/Applications/.sshai_staging_\(UUID().uuidString)"
        let backup = "/Applications/.sshai_old_\(UUID().uuidString)"
        var backupMade = false

        defer { let _ = remote("rm -rf \(shellQuote(staging))", sudo: true, timeout: 120) }

        append("· 清理暂存区 ...")
        let (okClean, oClean) = remote("rm -rf \(shellQuote(staging))", sudo: true, timeout: 120)
        if !okClean { append("⚠ 清理暂存区失败:\(oClean)") }

        append("· 复制到 /Applications (暂存) ...")
        let (okCopy, oCopy) = remote("cp -R \(shellQuote(source)) \(shellQuote(staging))", sudo: true, timeout: 900)
        guard okCopy else {
            append("✗ 暂存复制失败:\(oCopy)")
            append("· 已中止，目标机上的原应用未被改动")
            return
        }

        // 旧版本先移走而不是删除，保证失败可回滚
        let (_, oExist) = remote("test -e \(shellQuote(dest)) && echo __EXIST__ || true", timeout: 60)
        if oExist.contains("__EXIST__") {
            append("· 移走旧版本(可回滚) ...")
            let (okBackup, oBackup) = remote("rm -rf \(shellQuote(backup)) && mv \(shellQuote(dest)) \(shellQuote(backup))",
                                             sudo: true, timeout: 300)
            if okBackup { backupMade = true } else { append("⚠ 备份旧版本失败:\(oBackup)") }
        }

        append("· 就位 ...")
        let (okMove, oMove) = remote("mv \(shellQuote(staging)) \(shellQuote(dest))", sudo: true, timeout: 300)
        if !okMove {
            append("✗ 就位失败:\(oMove)")
            if backupMade {
                append("· 回滚旧版本 ...")
                let (okRoll, oRoll) = remote("mv \(shellQuote(backup)) \(shellQuote(dest))", sudo: true, timeout: 300)
                if okRoll { append("✔ 已回滚，原应用完好") } else { append("✗ 回滚失败:\(oRoll)") }
            }
            return
        }

        let (okX, oX) = remote("xattr -dr com.apple.quarantine \(shellQuote(dest))", sudo: true, timeout: 300)
        if !okX { append("⚠ 去隔离标记失败(可能不影响运行):\(oX)") }

        if backupMade { let _ = remote("rm -rf \(shellQuote(backup))", sudo: true, timeout: 300) }
        append("✔ 安装完成:\(dest)")
        showToast("✔ 安装成功：\(name)")
    }

    /// 挂载 dmg 并把其中的 .app 交给 installAppBundle 原子安装。
    /// 挂载点用随机路径，避免固定 /tmp/dmgmount 在异常退出后残留导致再也挂不上。
    private func installDMG(fromRemote tmpRemote: String) {
        let mount = "/tmp/sshai_dmg_\(UUID().uuidString)"
        var mounted = false
        defer {
            if mounted { let _ = remote("hdiutil detach \(shellQuote(mount))", timeout: 180) }
            let _ = remote("rmdir \(shellQuote(mount))", timeout: 60)
        }

        append("· 挂载 dmg ...")
        let (okMk, oMk) = remote("mkdir -p \(shellQuote(mount))", timeout: 60)
        if !okMk { append("⚠ 创建挂载点失败:\(oMk)") }
        let (okm, om) = remote("hdiutil attach \(shellQuote(tmpRemote)) -nobrowse -mountpoint \(shellQuote(mount))",
                               timeout: 300)
        guard okm else { append("✗ 挂载失败:\(om)"); return }
        mounted = true

        // 优先取挂载根目录下的 .app，找不到再往下一层找
        var appInDmg = ""
        for depth in ["1", "2"] {
            let (_, out) = remote("find \(shellQuote(mount)) -maxdepth \(depth) -name '*.app' -print 2>/dev/null | head -1",
                                  timeout: 120)
            let line = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { appInDmg = line; break }
        }
        if appInDmg.isEmpty { append("✗ dmg 内未找到 .app"); return }

        append("· 找到 \(appInDmg)")
        installAppBundle(fromRemote: appInDmg, name: (appInDmg as NSString).lastPathComponent)
    }

    private func installPKG(fromRemote tmpRemote: String, name: String) {
        append("· 安装 pkg (installer -target /) ...")
        let (okp, op) = remote("installer -pkg \(shellQuote(tmpRemote)) -target / -allowUntrusted",
                               sudo: true, timeout: 1800)
        if !okp { append("✗ pkg 安装失败:\(op)"); return }
        append("✔ pkg 安装完成")
        showToast("✔ 安装成功：\(name)")
    }

    /// 远端目录列举：cd 进目标目录后用 pwd 取真实绝对路径（支持 "~"、"."、相对路径等输入），
    /// 再用 `ls -lp` 列举（-l 长格式带大小 / -p 目录带 / 后缀，POSIX 选项，macOS/Linux 通用）。
    /// 默认不列隐藏文件，showHidden=true 时用 -A 包含。
    /// 返回 (是否成功, 条目列表, 真实绝对路径, 错误信息)。
    func remoteList(_ path: String, showHidden: Bool = false) -> (Bool, [RemoteEntry], String, String) {
        if remoteOS == .windows {
            return remoteListWindows(path, showHidden: showHidden)
        }
        let ls = showHidden ? "ls -lAp" : "ls -lp"   // -l 长格式(带文件大小)，POSIX 选项
        let cmd = "cd \(shellQuote(path)) 2>/dev/null && echo __PWD__$(pwd) && \(ls)"
        let (ok, out) = remote(cmd, timeout: 30)
        guard ok else { return (false, [], "", out) }
        var realPath = path
        var entries: [RemoteEntry] = []
        // ls -l 行格式: 权限 链接 属主 组 大小 月份 日 时间/年份 文件名
        // 宽松正则：首字符取权限类型（macOS 扩展属性会追加 @/+，不能对权限串后段做严格匹配，
        // 否则带 @ 的普通文件全部解析失败），前 8 字段锚定后文件名整段保留（含空格安全）
        let re = try? NSRegularExpression(
            pattern: #"^(\S)\S*\s+\S+\s+\S+\s+\S+\s+(\d+)\s+\S+\s+\S+\s+\S+\s(.+)$"#
        )
        for line in out.components(separatedBy: "\n") {
            guard !line.isEmpty else { continue }
            if line.hasPrefix("__PWD__") {
                realPath = String(line.dropFirst("__PWD__".count))
                continue
            }
            guard let re,
                  let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  m.numberOfRanges >= 4 else { continue }   // "total xx" 等行跳过
            let perms = String(line[Range(m.range(at: 1), in: line)!])
            let size = Int64(line[Range(m.range(at: 2), in: line)!]) ?? 0
            var name = String(line[Range(m.range(at: 3), in: line)!])
            if let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }  // 符号链接只取链接名
            if name.hasSuffix("/") { name.removeLast() }
            entries.append(RemoteEntry(name: name, isDir: perms.hasPrefix("d"), size: size))
        }
        return (true, entries, realPath, "")
    }

    /// Windows 远端目录列举：PowerShell -EncodedCommand 输出 tab 分隔行
    /// （__PWD__行 + 每条目 "是否目录\t大小(目录为空)\t名称"），避开 cmd.exe 引号地狱。
    /// ⚠️ 脚本必须拼成单行：PowerShell 的续行符是反引号而非 \，多行 \ 会解析失败（真机实测）。
    private func remoteListWindows(_ path: String, showHidden: Bool) -> (Bool, [RemoteEntry], String, String) {
        // 虚拟"此电脑"视图：置顶"对方的下载文件夹"，随后列出所有硬盘盘符
        if path == Self.pcRoot {
            let ps = "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; " +
                "Get-PSDrive -PSProvider FileSystem | ForEach-Object { " +
                "Write-Output (\"True`t`t\" + $_.Name + ':\\') }"
            let cmd = "powershell -NoProfile -EncodedCommand \(encodePSCommand(ps))"
            let (ok, out) = remote(cmd, timeout: 30)
            guard ok else { return (false, [], "", out) }
            var items: [RemoteEntry] = []
            if !windowsDownloadsPath.isEmpty {
                items.append(RemoteEntry(name: windowsDownloadsPath, isDir: true, size: 0))
            }
            for raw in out.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n \u{FEFF}"))
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 3, parts[0] == "True" else { continue }
                let name = parts[2...].joined(separator: "\t").replacingOccurrences(of: "\\", with: "/")
                guard !name.isEmpty else { continue }
                items.append(RemoteEntry(name: name, isDir: true, size: 0))
            }
            return (true, items, Self.pcRoot, "")
        }
        let force = showHidden ? "-Force " : ""
        let ps = "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; " +
            "$ErrorActionPreference='Stop'; " +
            "$WarningPreference='SilentlyContinue'; " +
            "$InformationPreference='SilentlyContinue'; " +
            "$ProgressPreference='SilentlyContinue'; " +
            "try { Set-Location -LiteralPath \(shellQuotePS(path)) } catch { Write-Output '__CD_FAIL__'; exit 1 }; " +
            "Write-Output ('__PWD__' + (Get-Location).Path); " +
            "Get-ChildItem \(force)| ForEach-Object { " +
            "$sz = if ($_.PSIsContainer) { '' } else { $_.Length }; " +
            "Write-Output ($_.PSIsContainer.ToString() + \"`t\" + $sz + \"`t\" + $_.Name) }"
        let cmd = "powershell -NoProfile -EncodedCommand \(encodePSCommand(ps))"
        let (ok, out) = remote(cmd, timeout: 180)   // 首连 PowerShell 需 .NET 模块预热,放宽超时避免 __CD_FAIL__
        guard ok else { return (false, [], "", out) }
        var realPath = path
        var entries: [RemoteEntry] = []
        for raw in out.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n \u{FEFF}"))
            guard !line.isEmpty else { continue }
            if line.hasPrefix("__PWD__") {
                // Windows 反斜杠路径统一成正斜杠（scp 目标用正斜杠）
                realPath = String(line.dropFirst("__PWD__".count)).replacingOccurrences(of: "\\", with: "/")
            } else if line == "__CD_FAIL__" {
                return (false, [], "", "无法访问 \(path)")
            } else {
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 3 else { continue }
                let isDir = parts[0] == "True"
                let size = isDir ? 0 : (Int64(parts[1]) ?? 0)
                let name = parts[2...].joined(separator: "\t")
                guard !name.isEmpty else { continue }
                entries.append(RemoteEntry(name: name, isDir: isDir, size: size))
            }
        }
        return (true, entries, realPath, "")
    }

    // 通用文件传输
    func transfer(local: String, remote: String, download: Bool) {
        if let err = validateEndpoint(host: host, user: user, port: port) {
            append("✗ \(err)")
            return
        }
        let ep = trimmedEndpoint(host: host, user: user, port: port)
        if download {
            append("▶ 下载 \(remote) → \(local)")
            let (ok, o) = scpDown(remote: remote, local: local)
            if ok { append("✔ 下载完成"); showToast("✔ 下载成功", target: .transferBox) } else { append("✗ 失败:\(o)") }
        } else {
            let dest = remote.isEmpty ? "/Users/\(ep.user)/Downloads/" : remote
            append("▶ 上传 \(local) → \(dest)")
            let (ok, o) = scpUp(local: local, remote: dest)
            if ok { append("✔ 上传完成"); showToast("✔ 上传成功", target: .transferBox) } else { append("✗ 失败:\(o)") }
        }
    }
}

// MARK: - 远端文件浏览器（Sheet：文件/文件夹都能选，双击文件夹进入）
private struct RemoteFileBrowser: View {
    let client: SSHClient
    @Binding var selectedPath: String
    @Environment(\.dismiss) private var dismiss
    @State var currentPath = ""
    @State private var entries: [RemoteEntry] = []
    @State private var selection: RemoteEntry? = nil
    @State private var loading = false
    @State private var errorText = ""
    @State private var pathInput = ""
    @State private var loadSeq = 0     // 防乱序：快速连点"前往/上级"时只采纳最后一次请求的结果
    @State private var showHidden = false   // 默认不显示隐藏文件

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("远端文件浏览").font(.headline)
                Spacer()
                Toggle("显示隐藏文件", isOn: Binding(
                    get: { showHidden },
                    set: { showHidden = $0; if !currentPath.isEmpty { load(currentPath) } }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                Button("关闭") { dismiss() }
            }
            HStack(spacing: 8) {
                TextField("远端路径", text: $pathInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { load(pathInput) }
                Button("前往") { load(pathInput) }
                Button { up() } label: { Image(systemName: "chevron.up") }
                    .help("上级目录")
                Button { load(currentPath) } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新")
                    .disabled(currentPath.isEmpty || loading)
            }
            ZStack {
                if loading {
                    ProgressView("加载中 ...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !errorText.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title)
                            .foregroundStyle(.yellow)
                        Text(errorText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重试") { load(pathInput) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty {
                    Text("（空目录）").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(sortedEntries) { e in
                            HStack(spacing: 8) {
                                Image(systemName: e.isDir ? "folder.fill" : "doc")
                                    .foregroundStyle(e.isDir ? Color.accentColor : Color.secondary)
                                    .frame(width: 20)
                                Text(e.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if selection == e {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                            // 顺序关键：双击手势必须写在单击之前，否则单击会先吞掉双击导致进不了文件夹
                            .onTapGesture(count: 2) {
                                if e.isDir { load(join(currentPath, e.name)) }
                            }
                            .onTapGesture(count: 1) { selection = e }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minHeight: 300)
            HStack {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("取消") { dismiss() }
                Button("选择") {
                    selectedPath = selection.map { join(currentPath, $0.name) } ?? currentPath
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(currentPath.isEmpty || loading)
            }
        }
        .padding(16)
        .frame(width: 560, height: 480)
        .onAppear { initialLoad() }
    }

    private var sortedEntries: [RemoteEntry] {
        entries.sorted {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var hint: String {
        if let e = selection {
            return "已选中\(e.isDir ? "文件夹" : "文件")：\(e.name)"
        }
        return "未选中时「选择」将使用当前目录"
    }

    func join(_ dir: String, _ name: String) -> String {
        if dir == SSHClient.pcRoot { return name }   // "此电脑"根下选中的就是盘符本身
        return dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    // 初始目录：已有输入像文件（带扩展名）则落到其父目录；为空则默认落到对方的下载目录
    private func initialLoad() {
        let r = selectedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        var start = r
        if !r.isEmpty, r != "/", !(r as NSString).pathExtension.isEmpty {
            start = (r as NSString).deletingLastPathComponent
        }
        if start.isEmpty {
            start = client.initialBrowsePath()
        }
        load(start)
    }

    private func up() {
        if currentPath == SSHClient.pcRoot { return }   // 已在"此电脑"根
        let parent = (currentPath as NSString).deletingLastPathComponent
        load(parent.isEmpty ? "/" : parent)
    }

    func load(_ p: String) {
        let target = p.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        loadSeq += 1
        let seq = loadSeq
        let hidden = showHidden
        selection = nil
        errorText = ""
        loading = true
        pathInput = target
        Task.detached {
            let (ok, list, realPath, err) = client.remoteList(target, showHidden: hidden)
            await MainActor.run {
                guard seq == loadSeq else { return }
                loading = false
                if ok {
                    currentPath = realPath
                    pathInput = realPath
                    entries = list
                } else {
                    errorText = err.isEmpty ? "无法访问 \(target)" : "✗ \(err)"
                    currentPath = ""
                    entries = []
                }
            }
        }
    }
}

// MARK: - 内嵌远端浏览框（下载方向：直接在框里浏览远端文件，替代弹出窗口）
// 支持：单击选中 / ⌘单击多选 / 拖拽框选多选 / 双击进入文件夹 / 图标·列表视图 / 列表显示文件大小
private struct RemoteBrowserBox: View {
    let client: SSHClient
    let initialPath: String                       // 初始目录（通常为当前已填的下载路径）
    var onSelect: ([String]) -> Void = { _ in }   // 多选变化回调，传出完整路径数组

    @State var currentPath = ""
    @State private var entries: [RemoteEntry] = []
    @State private var selection: Set<RemoteEntry> = []
    @State private var viewMode: InstallViewMode = .list
    @State private var loading = false
    @State private var errorText = ""
    @State private var pathInput = ""
    @State private var showHidden = false
    @State private var loadSeq = 0

    // 框选状态
    @State private var itemFrames: [String: CGRect] = [:]   // 条目名 -> 在内容坐标系中的 frame
    @State private var dragStart: CGPoint? = nil
    @State private var dragCurrent: CGPoint? = nil

    private var dragRect: CGRect? {
        guard let s = dragStart, let c = dragCurrent else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                      width: abs(c.x - s.x), height: abs(c.y - s.y))
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                TextField("对方路径(回车前往)", text: $pathInput)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .onSubmit { load(pathInput) }
                Button { up() } label: { Image(systemName: "chevron.up").font(.caption) }
                    .buttonStyle(.borderless)
                    .help("上级目录")
                Button { load(currentPath) } label: { Image(systemName: "arrow.clockwise").font(.caption) }
                    .buttonStyle(.borderless)
                    .help("刷新")
                    .disabled(currentPath.isEmpty || loading)
                Picker("", selection: $viewMode) {
                    ForEach(InstallViewMode.allCases) { m in
                        Image(systemName: m == .icon ? "square.grid.2x2" : "list.bullet").tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: 56)
                Toggle("显示隐藏文件", isOn: Binding(
                    get: { showHidden },
                    set: { showHidden = $0; if !currentPath.isEmpty { load(currentPath) } }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
            }
            Divider()
            ZStack {
                if loading {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !errorText.isEmpty {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if entries.isEmpty {
                    Text("（空目录）").font(.caption).foregroundStyle(.secondary)
                } else {
                    browserList
                }
            }
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor).opacity(0.5)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
        )
        .onAppear { initialLoad() }
    }

    // 内容区：图标网格 / 列表 两视图，均支持单击/⌘多选/框选
    private var browserList: some View {
        ScrollView {
            Group {
                if viewMode == .icon {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 8)], spacing: 8) {
                        entryRows
                    }
                    .padding(4)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        entryRows
                    }
                    .padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) {
                // 框选矩形
                if let r = dragRect {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.15))
                        .overlay(Rectangle().stroke(Color.accentColor.opacity(0.6), lineWidth: 0.5))
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.origin.x, y: r.origin.y)
                }
            }
            .contentShape(Rectangle())
            .gesture(boxSelectGesture)
            .coordinateSpace(name: "browserBoxSpace")
        }
        .onPreferenceChange(ItemFramesKey.self) { itemFrames = $0 }
    }

    @ViewBuilder private var entryRows: some View {
        ForEach(sortedEntries) { e in
            entryRow(e)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ItemFramesKey.self,
                                           value: [e.id: geo.frame(in: .named("browserBoxSpace"))])
                })
        }
    }

    @ViewBuilder private func entryRow(_ e: RemoteEntry) -> some View {
        let isSel = selection.contains(e)
        if viewMode == .icon {
            VStack(spacing: 3) {
                Image(systemName: e.isDir ? "folder.fill" : "doc")
                    .font(.title3)
                    .foregroundStyle(e.isDir ? Color.accentColor : Color.secondary)
                Text(e.name)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(4)
            .frame(maxWidth: .infinity)
            .background(isSel ? Color.accentColor.opacity(0.18) : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(isSel ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
            .cornerRadius(5)
            .rowTapGestures(e, box: self)
        } else {
            HStack(spacing: 5) {
                Image(systemName: e.isDir ? "folder.fill" : "doc")
                    .font(.caption2)
                    .foregroundStyle(e.isDir ? Color.accentColor : Color.secondary)
                    .frame(width: 14)
                Text(e.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                // 列表视图后方显示文件大小（目录显示 —）
                Text(e.isDir ? "—" : Self.formatSize(e.size))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
                if isSel {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 1.5)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .background(isSel ? Color.accentColor.opacity(0.15) : Color.clear)
            .rowTapGestures(e, box: self)
        }
    }

    // 单击(⌘=切换多选) / 双击进文件夹 —— 双击手势必须先注册
    func handleTap(_ e: RemoteEntry, multi: Bool) {
        if multi {
            if selection.contains(e) { selection.remove(e) } else { selection.insert(e) }
        } else {
            selection = [e]
        }
        syncSelection()
    }

    private var boxSelectGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("browserBoxSpace"))
            .onChanged { g in
                if dragStart == nil { dragStart = g.startLocation }
                dragCurrent = g.location
            }
            .onEnded { _ in
                if let rect = dragRect, !rect.isEmpty {
                    let hit = Set(itemFrames.filter { $0.value.intersects(rect) }.map(\.key))
                    // 框选命中的条目按排序顺序取回 RemoteEntry
                    selection = Set(sortedEntries.filter { hit.contains($0.id) })
                    syncSelection()
                }
                dragStart = nil
                dragCurrent = nil
            }
    }

    private var sortedEntries: [RemoteEntry] {
        entries.sorted {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var hint: String {
        if selection.isEmpty {
            return "单击选中，⌘单击多选，拖拽框选，双击进入文件夹；不选则默认对方下载目录"
        }
        let paths = sortedEntries.filter { selection.contains($0) }.map { join(currentPath, $0.name) }
        if paths.count == 1, let p = paths.first {
            return "已选中：\(p)"
        }
        return "已选中 \(paths.count) 项，将依次下载"
    }

    private func syncSelection() {
        onSelect(sortedEntries.filter { selection.contains($0) }.map { join(currentPath, $0.name) })
    }

    static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func join(_ dir: String, _ name: String) -> String {
        if dir == SSHClient.pcRoot { return name }   // "此电脑"根下选中的就是盘符本身
        return dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    private func initialLoad() {
        let r = initialPath.trimmingCharacters(in: .whitespacesAndNewlines)
        var start = r
        if !r.isEmpty, r != "/", !(r as NSString).pathExtension.isEmpty {
            start = (r as NSString).deletingLastPathComponent
        }
        if start.isEmpty {
            start = client.initialBrowsePath()
        }
        load(start)
    }

    private func up() {
        if currentPath == SSHClient.pcRoot { return }   // 已在"此电脑"根
        let parent = (currentPath as NSString).deletingLastPathComponent
        load(parent.isEmpty ? "/" : parent)
    }

    func load(_ p: String) {
        let target = p.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        loadSeq += 1
        let seq = loadSeq
        let hidden = showHidden
        selection = []
        syncSelection()
        errorText = ""
        loading = true
        pathInput = target
        Task.detached {
            let (ok, list, realPath, err) = client.remoteList(target, showHidden: hidden)
            await MainActor.run {
                guard seq == loadSeq else { return }
                loading = false
                if ok {
                    currentPath = realPath
                    pathInput = realPath
                    entries = list
                } else {
                    errorText = err.isEmpty ? "无法访问 \(target)" : "✗ \(err)"
                    currentPath = ""
                    entries = []
                }
            }
        }
    }

    // 收集条目 frame 用于框选命中测试
    private struct ItemFramesKey: PreferenceKey {
        static var defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { $1 })
        }
    }
}

// 单击/双击手势复用（tap 事件里读当前事件判断是否按住 ⌘）
private struct RowTapGestures: ViewModifier {
    let entry: RemoteEntry
    let box: RemoteBrowserBox

    func body(content: Content) -> some View {
        content
            .onTapGesture(count: 2) {
                if entry.isDir { box.load(box.join(box.currentPath, entry.name)) }
            }
            .onTapGesture(count: 1) {
                let cmd = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
                box.handleTap(entry, multi: cmd)
            }
    }
}

private extension View {
    func rowTapGestures(_ e: RemoteEntry, box: RemoteBrowserBox) -> some View {
        modifier(RowTapGestures(entry: e, box: box))
    }
}
// MARK: - 主 App
@main
struct SSHAppInstallerApp: App {
    // 默认窗口 900×744；屏幕不够大时按可用区域自适应缩小（但不小于可交互的最小尺寸）
    private static func idealFrame() -> (w: CGFloat, h: CGFloat) {
        let vf = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let w = max(760, min(900, vf.width - 80))
        let h = max(600, min(744, vf.height - 80))
        return (w, h)
    }

    var body: some Scene {
        WindowGroup {
            let size = Self.idealFrame()
            ContentView()
                .preferredColorScheme(.dark)
                .tint(Color.accentColor)
                .frame(width: size.w, height: size.h)
                .frame(minWidth: 760, minHeight: 600)
        }
        // .windowResizability 是 macOS 13+ API，为兼容 12 不使用
        .commands {
            // 标准「关于」面板：版本号与版权取自 Info.plist
            CommandGroup(replacing: .appInfo) {
                Button("关于 SSH App Installer") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [:])
                }
            }
        }
    }
}

// MARK: - 主界面
private enum InstallViewMode: String, CaseIterable, Identifiable {
    case icon = "图标"
    case list = "列表"
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var client = SSHClient()
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2.0"
    @State private var droppedInstalls: [String] = []
    @State private var transferLocal: String = ""
    @State private var uploadRemote: String = ""      // 上传目标路径(远端)，与下载路径相互独立
    @State private var downloadRemote: String = ""    // 下载远端路径(初始起点/记录用)
    @State private var downloadItems: [String] = []   // 下载框多选的完整路径列表(空=默认对方 Downloads)
    @State private var transferDownload: Bool = false
    @State private var showKeyPicker = false
    @State private var installViewMode: InstallViewMode = .icon
    @State private var transferViewMode: InstallViewMode = .icon
    @State private var droppedTransfers: [String] = []
    @State private var showDirConfirm: Bool = false       // 下载文件夹二次确认
    @State private var pendingDownloadRemote: String = ""
    @State private var pendingDownloadLocal: String = ""
    @State private var showRemoteBrowser: Bool = false    // 远端文件浏览器
    @State private var showConnHistory: Bool = false      // 连接历史弹层

    var body: some View {
        // 整体固定布局不可滚动（需求）；日志框自身可滚动；高度靠弹性 TabView 适配
        VStack(alignment: .leading, spacing: 10) {
            // 顶部品牌头：左上角图标+应用名+版本号，右上角关于按钮（macos-app-header 规范）
            HStack(spacing: 10) {
                if let img = NSImage(named: NSImage.Name("AppIcon")) {
                    Image(nsImage: img)
                        .resizable()
                        .frame(width: 36, height: 36)
                        .cornerRadius(8)
                }
                Text("SSH App Installer")
                    .font(.title2.bold())
                Text("v\(appVersion)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { NSApplication.shared.orderFrontStandardAboutPanel(options: [:]) }) {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help("关于")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.windowBackgroundColor))
            )
            connectionSection
            Divider()
            TabView {
                installTab.tag(0)
                    .tabItem { Label("安装软件", systemImage: "square.and.arrow.down.on.square") }
                transferTab.tag(1)
                    .tabItem { Label("传文件", systemImage: "arrow.left.arrow.right") }
            }
            .frame(minHeight: 300)
            Divider()
            logSection
        }
        .padding(14)
        .overlay(alignment: .bottom) {
            if client.toast?.target == .window, let msg = client.toast?.message {
                ToastView(message: msg)
                    .padding(.bottom, 18)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: client.toast)
        .onAppear {
            // 安装/更新后自动弹出关于界面验证版权（OPEN_ABOUT=1 触发，避免依赖辅助功能授权）
            if ProcessInfo.processInfo.environment["OPEN_ABOUT"] != nil {
                NSApplication.shared.orderFrontStandardAboutPanel(options: [:])
            }
        }
    }

    // MARK: 连接配置
    // MARK: 连接历史弹层（点击行=切换连接，垃圾桶=删除该条）
    private var connHistoryList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("历史连接").font(.headline)
                Spacer()
                Text("点击切换 · 桶删除").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            List(client.history) { item in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.host).font(.callout).lineLimit(1)
                        Text("\(item.user)  ·  端口 \(item.port)  ·  \(item.useKey ? "密钥" : "密码")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        client.applyHistory(item)
                        showConnHistory = false
                    } label: {
                        Image(systemName: "arrow.up.left.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.borderless)
                    .help("切换到此连接")
                    Button {
                        client.deleteHistory(item)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("删除此记录")
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .listStyle(.plain)
        }
        .frame(width: 340, height: min(CGFloat(client.history.count) * 46 + 40, 340))
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SSH 连接").font(.headline)
                if client.remoteOS != .unknown {
                    Text(client.remoteOS.rawValue)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Button(action: {
                    client.isBusy = true
                    Task.detached {
                        let _ = client.test()
                        await MainActor.run { client.isBusy = false }
                    }
                }) {
                    if client.isBusy { ProgressView().controlSize(.small) } else { Text("测试连接") }
                }
                .disabled(client.isBusy)
                Image(systemName: client.connectionOK ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(client.connectionOK ? .green : .gray)
            }
            HStack(spacing: 10) {
                // 连接参数一改，先前的连接成功状态立即作废（避免换主机后还显示绿勾）
                TextField("主机 / IP", text: Binding(get: { client.host }, set: { client.host = $0; client.connectionOK = false; client.remoteOS = .unknown }))
                    .textFieldStyle(.roundedBorder)
                Button {
                    showConnHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.borderless)
                .help("历史连接（点击切换，垃圾桶删除）")
                .disabled(client.history.isEmpty)
                .popover(isPresented: $showConnHistory, arrowEdge: .bottom) {
                    connHistoryList
                }
                TextField("端口", text: Binding(get: { client.port }, set: { client.port = $0; client.connectionOK = false; client.remoteOS = .unknown }))
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                TextField("用户名", text: Binding(get: { client.user }, set: { client.user = $0; client.connectionOK = false; client.remoteOS = .unknown }))
                    .textFieldStyle(.roundedBorder).frame(width: 120)
            }
            Picker("认证方式", selection: Binding(get: { client.useKey }, set: { client.useKey = $0; client.connectionOK = false; client.remoteOS = .unknown })) {
                Text("SSH 密钥").tag(true)
                Text("密码").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            if client.useKey {
                HStack {
                    TextField("密钥路径(默认 ~/.ssh/id_ed25519)", text: Binding(get: { client.keyPath }, set: { client.keyPath = $0; client.connectionOK = false }))
                        .textFieldStyle(.roundedBorder)
                    Button("选择") {
                        if let p = chooseFile() { client.keyPath = p }
                    }
                }
            } else {
                SecureField("密码(仅内存,不保存)", text: Binding(get: { client.password }, set: { client.password = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                SecureField("sudo 密码(安装到 /Applications 需要)", text: Binding(get: { client.sudoPassword }, set: { client.sudoPassword = $0 }))
                    .textFieldStyle(.roundedBorder)
                Text("写 /Applications 必须").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
    }

    // MARK: 安装软件 Tab
    private var installTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("把 .app / .dmg / .pkg 拖到下方,或点「选择文件」,再点「安装到远端」").font(.subheadline).foregroundStyle(.secondary)
            installDropZone
            HStack {
                Button("选择文件") {
                    if let p = chooseFile() { addInstallFile(p) }
                }
                Spacer()
                Button(action: {
                    guard !droppedInstalls.isEmpty else { return }
                    let paths = droppedInstalls
                    client.isBusy = true
                    Task.detached {
                        for p in paths { client.install(localPath: p) }
                        await MainActor.run { client.isBusy = false }
                    }
                }) {
                    if client.isBusy { ProgressView().controlSize(.small) } else { Text("安装到远端 /Applications（\(droppedInstalls.count)）").bold() }
                }
                .disabled(client.isBusy || droppedInstalls.isEmpty || client.remoteOS == .windows)
                .help(client.remoteOS == .windows ? "远端是 Windows，不支持安装 macOS 应用，请使用传文件" : "")
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
    }

    // 安装页拖放区（独立成子视图，避免巨型表达式拖慢编译）
    private var installDropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.06))
            // 兼容 macOS 12：带样式描边用旧 API stroke(style:)+foregroundColor
            RoundedRectangle(cornerRadius: 12)
                .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundColor(Color.accentColor)
            VStack(spacing: 8) {
                if droppedInstalls.isEmpty {
                    Image(systemName: "tray.and.arrow.down").font(.title).foregroundColor(.accentColor)
                    Text("拖入软件包（可多个）").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        Picker("显示模式", selection: $installViewMode) {
                            ForEach(InstallViewMode.allCases) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                        Spacer()
                        Button("清除全部") { droppedInstalls.removeAll() }.font(.caption)
                    }
                    if installViewMode == .icon {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 16)], spacing: 16) {
                                ForEach(droppedInstalls, id: \.self) { p in
                                    DropItemView(path: p) {
                                        droppedInstalls.removeAll { $0 == p }
                                    }
                                }
                            }
                            .padding(12)
                        }
                        .frame(maxHeight: 106)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(droppedInstalls, id: \.self) { p in
                                    HStack(spacing: 8) {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: p))
                                            .resizable()
                                            .frame(width: 20, height: 20)
                                        Text((p as NSString).lastPathComponent)
                                            .font(.caption)
                                            .lineLimit(1)
                                        Spacer()
                                        Button(action: { droppedInstalls.removeAll { $0 == p } }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 15))
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                            .padding(12)
                        }
                        .frame(maxHeight: 106)
                    }
                }
            }
            .padding(10)
        }
        .frame(height: 168)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers) { addInstallFile($0) }
            return true
        }
    }

    // MARK: 传文件 Tab
    private var transferTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("方向", selection: Binding(get: { transferDownload }, set: { transferDownload = $0 })) {
                Text("上传 (本机 → 远端)").tag(false)
                Text("下载 (远端 → 本机)").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()   // 完整显示文案,不出现"..."截断

            if transferDownload {
                // 下载:内嵌远端浏览框(像上传的拖放框一样嵌在界面里,不弹窗) + 本机保存路径
                RemoteBrowserBox(client: client, initialPath: downloadRemote) { downloadItems = $0 }
                    .frame(height: 168)
                HStack {
                    TextField("保存到本机路径", text: $transferLocal, prompt: Text("默认本机 ~/Downloads/")).textFieldStyle(.roundedBorder)
                    Button("选择") { if let p = chooseFile(allowDir: true) { transferLocal = p } }
                }
            } else {
                // 上传:拖入本机文件/文件夹(支持多个,图标/列表切换,x 删除)
                HStack {
                    Picker("", selection: $transferViewMode) {
                        ForEach(InstallViewMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    Spacer()
                    Button("选择文件") {
                        if let p = chooseFile(allowDir: true) {
                            if !droppedTransfers.contains(p) { droppedTransfers.append(p) }
                        }
                    }
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.4))
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    VStack(spacing: 8) {
                        if droppedTransfers.isEmpty {
                            Image(systemName: "tray.and.arrow.down").font(.title).foregroundColor(.accentColor)
                            Text("拖入本机文件/文件夹（可多个）").foregroundStyle(.secondary)
                        } else {
                            ScrollView {
                                if transferViewMode == .icon {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 16)], spacing: 16) {
                                        ForEach(droppedTransfers, id: \.self) { p in
                                            DropItemView(path: p) { droppedTransfers.removeAll { $0 == p } }
                                        }
                                    }
                                    .padding(12)
                                } else {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(droppedTransfers, id: \.self) { p in
                                            HStack(spacing: 8) {
                                                Image(nsImage: NSWorkspace.shared.icon(forFile: p))
                                                    .resizable()
                                                    .frame(width: 20, height: 20)
                                                Text((p as NSString).lastPathComponent)
                                                    .font(.caption)
                                                    .lineLimit(1)
                                                Spacer()
                                                Button(action: { droppedTransfers.removeAll { $0 == p } }) {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .font(.system(size: 15))
                                                        .foregroundStyle(.secondary)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                            .padding(.vertical, 2)
                                        }
                                    }
                                    .padding(12)
                                }
                            }
                            .frame(maxHeight: 128)
                            HStack {
                                Button("清除全部") { droppedTransfers.removeAll() }.font(.caption)
                                Spacer()
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(height: 168)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers) { p in
                        if !droppedTransfers.contains(p) { droppedTransfers.append(p) }
                    }
                    return true
                }
                HStack {
                    TextField("远端目标路径", text: $uploadRemote, prompt: Text("默认 /Users/\(client.user)/Downloads/")).textFieldStyle(.roundedBorder)
                    Button("浏览") { showRemoteBrowser = true }
                }
            }
            HStack {
                Spacer()
                Button(action: {
                    if transferDownload {
                        // 远端源/本机保存路径都允许留空：默认对方的下载文件夹 → 本机的下载文件夹
                        let l = transferLocal.isEmpty
                            ? (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
                            : transferLocal
                        let items = downloadItems.isEmpty
                            ? [client.defaultRemoteDownloads()]
                            : downloadItems
                        client.isBusy = true
                        Task.detached {
                            if items.count == 1, let r = items.first {
                                // 单路径：先判断远端路径是文件夹还是文件（Windows 用 PowerShell Test-Path）
                                var isDir = false
                                if client.remoteOS == .windows {
                                    let ps = "(Test-Path -LiteralPath \(client.shellQuotePS(r)) -PathType Container)"
                                    let cmd = "powershell -NoProfile -EncodedCommand \(client.encodePSCommand(ps))"
                                    let (okDir, outDir) = client.remote(cmd, timeout: 30)
                                    isDir = okDir && outDir.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("true")
                                } else {
                                    let safeR = r.replacingOccurrences(of: "'", with: "'\\''")
                                    let (okDir, outDir) = client.remote("test -d '\(safeR)' && echo __DIR__ || true")
                                    isDir = okDir && outDir.contains("__DIR__")
                                }
                                if isDir {
                                    // 文件夹:弹二次确认,询问是否下载全部
                                    await MainActor.run {
                                        client.isBusy = false
                                        pendingDownloadRemote = r
                                        pendingDownloadLocal = l
                                        showDirConfirm = true
                                    }
                                } else {
                                    client.transfer(local: l, remote: r, download: true)
                                    await MainActor.run { client.isBusy = false }
                                }
                            } else {
                                // 多选：逐个下载（文件夹整夹下载，不再逐个确认）
                                for r in items {
                                    client.transfer(local: l, remote: r, download: true)
                                }
                                await MainActor.run { client.isBusy = false }
                            }
                        }
                    } else {
                        guard !droppedTransfers.isEmpty else { return }
                        let items = droppedTransfers
                        let r = uploadRemote.isEmpty ? client.defaultUploadFolder() : uploadRemote
                        client.isBusy = true
                        Task.detached {
                            for p in items { client.transfer(local: p, remote: r, download: false) }
                            await MainActor.run { client.isBusy = false }
                        }
                    }
                }) {
                    if client.isBusy { ProgressView().controlSize(.small) } else { Text(transferDownload ? "开始下载" : "开始上传（\(droppedTransfers.count)）").bold().fixedSize() }
                }
                .disabled(client.isBusy || (!transferDownload && droppedTransfers.isEmpty))
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .overlay(alignment: .center) {
            if client.toast?.target == .transferBox, let msg = client.toast?.message {
                ToastView(message: msg)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: client.toast)
        // 远端路径留空 = 使用默认的对方 ~/Downloads（占位符已提示），不再自动代填
        .alert("下载文件夹确认", isPresented: $showDirConfirm) {
            Button("下载全部文件") {
                let r = pendingDownloadRemote, l = pendingDownloadLocal
                client.isBusy = true
                Task.detached {
                    client.transfer(local: l, remote: r, download: true)
                    await MainActor.run { client.isBusy = false }
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("远端路径是一个文件夹：\n\(pendingDownloadRemote)\n\n是否下载该文件夹内的所有文件？")
        }
        .sheet(isPresented: $showRemoteBrowser) {
            // 按当前方向决定浏览器把选中结果填回哪个输入框
            RemoteFileBrowser(client: client, selectedPath: transferDownload ? $downloadRemote : $uploadRemote)
        }
    }

    // MARK: 日志
    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("日志").font(.headline)
                // 安装/上传/下载进度条：百分比进度条+数字+已传/总大小；远端操作阶段显示转圈
                if let p = client.progress {
                    if let v = p.value {
                        ProgressView(value: v)
                            .frame(width: 150)
                        Text("\(Int((v * 100).rounded()))%")
                            .font(.caption)
                            .monospacedDigit()
                            .frame(width: 38, alignment: .leading)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if let st = p.sizeText {
                        Text(st)
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(p.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("清空") { client.clearLog() }.font(.caption)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(client.log.isEmpty ? "（操作日志会显示在这里）" : client.log)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("logTop")
                    Spacer().id("logBottom")
                }
                .frame(height: 88)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .onChange(of: client.log) { _ in
                    proxy.scrollTo("logBottom", anchor: .bottom)
                }
            }
        }
    }

    // MARK: 文件选择
    private func chooseFile(allowDir: Bool = false) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true            // 始终允许选文件（修复上传界面选不中文件）
        panel.canChooseDirectories = allowDir  // 传文件场景同时允许选文件夹
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            return url.path
        }
        return nil
    }

    // 仅允许 .app/.dmg/.pkg 进入安装列表,其他格式即时提示不支持
    private func addInstallFile(_ p: String) {
        let ext = (p as NSString).pathExtension.lowercased()
        guard ["app", "dmg", "pkg"].contains(ext) else {
            let label = ext.isEmpty ? "无扩展名" : ext
            client.showToast("✗ 不支持的格式：\(label)（仅支持 .app/.dmg/.pkg）", target: .window)
            return
        }
        if !droppedInstalls.contains(p) { droppedInstalls.append(p) }
    }

    private func handleDrop(_ providers: [NSItemProvider], set: @escaping (String) -> Void) {
        guard !providers.isEmpty else { return }
        for p in providers {
            p.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                var path: String?
                if let data = item as? Data {
                    path = URL(dataRepresentation: data, relativeTo: nil)?.path
                } else if let u = item as? URL {
                    path = u.path
                }
                if let path { DispatchQueue.main.async { set(path) } }
            }
        }
    }

    // MARK: 拖入项图标卡片（悬停显示删除）
    private struct DropItemView: View {
        let path: String
        var onRemove: () -> Void
        @State private var hovered = false

        var body: some View {
            VStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .frame(width: 48, height: 48)
                Text((path as NSString).lastPathComponent)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 84)
            }
            .frame(width: 100)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(alignment: .topTrailing) {
                if hovered {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color(nsColor: .secondaryLabelColor))
                            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 18, height: 18))
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                    .frame(width: 28, height: 28)
                    .offset(x: -2, y: 2)
                }
            }
            .onHover { hovered = $0 }
        }
    }

    // MARK: 成功/提示浮窗
    private struct ToastView: View {
        let message: String
        private var isError: Bool { message.hasPrefix("✗") }
        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? .red : .green)
                    .font(.title3)
                Text(message)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            )
            .overlay(
                Capsule().stroke(isError ? Color.red.opacity(0.5) : Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
    }
}

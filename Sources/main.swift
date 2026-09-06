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
struct RemoteEntry: Identifiable, Equatable {
    let name: String
    let isDir: Bool
    var id: String { name }
}

// MARK: - SSH 执行核心
final class SSHClient: ObservableObject {
    @Published var isBusy: Bool = false
    @Published var log: String = ""
    @Published var connectionOK: Bool = false
    @Published var toast: ToastInfo? = nil   // 成功浮窗(含显示位置)
    private var toastDismissWork: DispatchWorkItem? = nil

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

    init() { loadConnection() }

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
        var a: [String] = ["-o", "StrictHostKeyChecking=no",
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
    private func run(launch: String, args: [String], usePassword: Bool, timeout: TimeInterval = 600) -> (Bool, String) {
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
        let ep = trimmedEndpoint(host: host, user: user, port: port)
        var a = scpArgs()
        a.append(local)
        a.append("\(ep.user)@\(ep.host):\(remote)")
        return run(launch: "/usr/bin/scp", args: a, usePassword: !useKey, timeout: timeout)
    }

    func scpDown(remote: String, local: String, timeout: TimeInterval = 1800) -> (Bool, String) {
        let ep = trimmedEndpoint(host: host, user: user, port: port)
        var a = scpArgs()
        a.append("\(ep.user)@\(ep.host):\(remote)")
        a.append(local)
        return run(launch: "/usr/bin/scp", args: a, usePassword: !useKey, timeout: timeout)
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
        } else {
            append("✗ 连接失败:\(out)")
        }
        return ok
    }

    // 安装本地软件包到远端 /Applications
    func install(localPath: String) {
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
        }

        append("· 上传到目标机 ...")
        let (ok1, o1) = scpUp(local: localPath, remote: tmpRemote)
        if !ok1 { append("✗ 上传失败:\(o1)"); return }

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
    /// 再用 `ls -1Ap` 列举（-1 单列 / -A 含隐藏 / -p 目录带 / 后缀，POSIX 选项，macOS/Linux 通用）。
    /// 返回 (是否成功, 条目列表, 真实绝对路径, 错误信息)。
    func remoteList(_ path: String) -> (Bool, [RemoteEntry], String, String) {
        let cmd = "cd \(shellQuote(path)) 2>/dev/null && echo __PWD__$(pwd) && ls -1Ap"
        let (ok, out) = remote(cmd, timeout: 30)
        guard ok else { return (false, [], "", out) }
        var realPath = path
        var entries: [RemoteEntry] = []
        for line in out.components(separatedBy: "\n") {
            guard !line.isEmpty else { continue }
            if line.hasPrefix("__PWD__") {
                realPath = String(line.dropFirst("__PWD__".count))
            } else if line.hasSuffix("/") {
                entries.append(RemoteEntry(name: String(line.dropLast()), isDir: true))
            } else {
                entries.append(RemoteEntry(name: line, isDir: false))
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
    @State private var currentPath = ""
    @State private var entries: [RemoteEntry] = []
    @State private var selection: RemoteEntry? = nil
    @State private var loading = false
    @State private var errorText = ""
    @State private var pathInput = ""
    @State private var loadSeq = 0     // 防乱序：快速连点"前往/上级"时只采纳最后一次请求的结果

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("远端文件浏览").font(.headline)
                Spacer()
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

    private func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    // 初始目录：已有输入像文件（带扩展名）则落到其父目录；为空则落到远端家目录(".")
    private func initialLoad() {
        let r = selectedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        var start = r
        if !r.isEmpty, r != "/", !(r as NSString).pathExtension.isEmpty {
            start = (r as NSString).deletingLastPathComponent
        }
        if start.isEmpty { start = "." }
        load(start)
    }

    private func up() {
        let parent = (currentPath as NSString).deletingLastPathComponent
        load(parent.isEmpty ? "/" : parent)
    }

    private func load(_ p: String) {
        let target = p.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        loadSeq += 1
        let seq = loadSeq
        selection = nil
        errorText = ""
        loading = true
        pathInput = target
        Task {
            let (ok, list, realPath, err) = client.remoteList(target)
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
    @State private var droppedInstalls: [String] = []
    @State private var transferLocal: String = ""
    @State private var uploadRemote: String = ""      // 上传目标路径(远端)，与下载路径相互独立
    @State private var downloadRemote: String = ""    // 下载远端路径
    @State private var transferDownload: Bool = false
    @State private var showKeyPicker = false
    @State private var installViewMode: InstallViewMode = .icon
    @State private var transferViewMode: InstallViewMode = .icon
    @State private var droppedTransfers: [String] = []
    @State private var showDirConfirm: Bool = false       // 下载文件夹二次确认
    @State private var pendingDownloadRemote: String = ""
    @State private var pendingDownloadLocal: String = ""
    @State private var showRemoteBrowser: Bool = false    // 远端文件浏览器

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                connectionSection
                Divider()
                TabView {
                    installTab.tag(0)
                        .tabItem { Label("安装软件", systemImage: "square.and.arrow.down.on.square") }
                    transferTab.tag(1)
                        .tabItem { Label("传文件", systemImage: "arrow.left.arrow.right") }
                }
                .frame(minHeight: 360)
                Divider()
                logSection
            }
            .padding(16)
        }
        .overlay(alignment: .bottom) {
            if client.toast?.target == .window, let msg = client.toast?.message {
                ToastView(message: msg)
                    .padding(.bottom, 18)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: client.toast)
    }

    // MARK: 连接配置
    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SSH 连接").font(.headline)
                Spacer()
                Button(action: {
                    client.isBusy = true
                    Task {
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
                TextField("主机 / IP", text: Binding(get: { client.host }, set: { client.host = $0; client.connectionOK = false }))
                    .textFieldStyle(.roundedBorder)
                TextField("端口", text: Binding(get: { client.port }, set: { client.port = $0; client.connectionOK = false }))
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                TextField("用户名", text: Binding(get: { client.user }, set: { client.user = $0; client.connectionOK = false }))
                    .textFieldStyle(.roundedBorder).frame(width: 120)
            }
            Picker("认证方式", selection: Binding(get: { client.useKey }, set: { client.useKey = $0; client.connectionOK = false })) {
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
                    Task {
                        for p in paths { client.install(localPath: p) }
                        await MainActor.run { client.isBusy = false }
                    }
                }) {
                    if client.isBusy { ProgressView().controlSize(.small) } else { Text("安装到远端 /Applications（\(droppedInstalls.count)）").bold() }
                }
                .disabled(client.isBusy || droppedInstalls.isEmpty)
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
                        .frame(maxHeight: 140)
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
                        .frame(maxHeight: 140)
                    }
                }
            }
            .padding(10)
        }
        .frame(height: 210)
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
                // 下载:远端路径 + 本机保存路径(远端文件可文本输入或点「浏览」图形化选择)
                HStack {
                    TextField("远端路径 (如 /tmp/a.txt)", text: $downloadRemote, prompt: Text("默认 /Users/\(client.user)/Downloads/")).textFieldStyle(.roundedBorder)
                    Button("浏览") { showRemoteBrowser = true }
                }
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
                            .frame(maxHeight: 162)
                            HStack {
                                Button("清除全部") { droppedTransfers.removeAll() }.font(.caption)
                                Spacer()
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(height: 210)
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
                        let r = downloadRemote.isEmpty
                            ? "/Users/\(client.user)/Downloads/"
                            : downloadRemote
                        client.isBusy = true
                        Task {
                            // 先判断远端路径是文件夹还是文件
                            let safeR = r.replacingOccurrences(of: "'", with: "'\\''")
                            let (okDir, outDir) = client.remote("test -d '\(safeR)' && echo __DIR__ || true")
                            let isDir = okDir && outDir.contains("__DIR__")
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
                        }
                    } else {
                        guard !droppedTransfers.isEmpty else { return }
                        let items = droppedTransfers
                        let r = uploadRemote.isEmpty ? "/Users/\(client.user)/Downloads/" : uploadRemote
                        client.isBusy = true
                        Task {
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
                Task {
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
            HStack {
                Text("日志").font(.headline)
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
                .frame(height: 132)
                .padding(8)
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
        panel.canChooseFiles = !allowDir
        panel.canChooseDirectories = allowDir
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

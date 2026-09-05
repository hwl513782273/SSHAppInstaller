import SwiftUI
import AppKit

// MARK: - 成功浮窗类型（决定浮窗显示位置）
enum ToastTarget { case window, transferBox }
struct ToastInfo: Equatable {
    let message: String
    let target: ToastTarget
}

// MARK: - SSH 执行核心
final class SSHClient: ObservableObject {
    @Published var isBusy: Bool = false
    @Published var log: String = ""
    @Published var connectionOK: Bool = false
    @Published var toast: ToastInfo? = nil   // 成功浮窗(含显示位置)

    func showToast(_ s: String, target: ToastTarget = .window) {
        DispatchQueue.main.async { self.toast = ToastInfo(message: s, target: target) }
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
        DispatchQueue.main.async { self.log += s + "\n" }
    }
    func clearLog() { DispatchQueue.main.async { self.log = "" } }

    // 通用 askpass 助手（只回显环境变量里的密码,脚本本身不含密码）
    private func askpassHelperPath() -> String {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("sshappinstaller_askpass.sh")
        if !FileManager.default.fileExists(atPath: path) {
            let script = "#!/bin/sh\necho \"$SSH_ASKPASS_PASSWORD\"\n"
            try? script.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        return path
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

    private func run(launch: String, args: [String], usePassword: Bool) -> (Bool, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launch)
        proc.arguments = args
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        var env = ProcessInfo.processInfo.environment
        if usePassword && !password.isEmpty {
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["SSH_ASKPASS"] = askpassHelperPath()
            env["SSH_ASKPASS_PASSWORD"] = password
            env["DISPLAY"] = ":0"
        }
        proc.environment = env
        do {
            try proc.run()
        } catch {
            return (false, "启动失败: \(error)")
        }
        proc.waitUntilExit()
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (proc.terminationStatus == 0, o + e)
    }

    // 在远端执行命令；sudo=true 时需要管理员权限
    func remote(_ command: String, sudo: Bool = false) -> (Bool, String) {
        var a = sshArgs()
        a.append("\(user)@\(host)")
        let wrapped: String
        if sudo {
            if !sudoPassword.isEmpty {
                let safe = sudoPassword.replacingOccurrences(of: "'", with: "'\\''")
                wrapped = "printf '%s\\n' '\(safe)' | sudo -S \(command)"
            } else if !useKey && !password.isEmpty {
                let safe = password.replacingOccurrences(of: "'", with: "'\\''")
                wrapped = "printf '%s\\n' '\(safe)' | sudo -S \(command)"
            } else {
                wrapped = "sudo \(command)"
            }
        } else {
            wrapped = command
        }
        a.append(wrapped)
        return run(launch: "/usr/bin/ssh", args: a, usePassword: !useKey)
    }

    func scpUp(local: String, remote: String) -> (Bool, String) {
        var a = scpArgs()
        a.append(local)
        a.append("\(user)@\(host):\(remote)")
        return run(launch: "/usr/bin/scp", args: a, usePassword: !useKey)
    }

    func scpDown(remote: String, local: String) -> (Bool, String) {
        var a = scpArgs()
        a.append("\(user)@\(host):\(remote)")
        a.append(local)
        return run(launch: "/usr/bin/scp", args: a, usePassword: !useKey)
    }

    func test() -> Bool {
        append("· 测试连接 \(user)@\(host) ...")
        let (ok, out) = remote("echo __ssh_ok__")
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
        guard !host.isEmpty, !user.isEmpty else { append("✗ 请先填写主机与用户名"); return }

        let tmpRemote = "/tmp/\(name)"
        append("· 上传到目标机 \(tmpRemote) ...")
        let (ok1, o1) = scpUp(local: localPath, remote: tmpRemote)
        if !ok1 { append("✗ 上传失败:\(o1)"); return }

        if ext == "app" {
            append("· 移除旧版本(若存在) ...")
            let (okr, or) = remote("rm -rf '/Applications/\(name)'", sudo: true)
            if !okr { append("⚠ 移除旧版本失败(可能权限不足):\(or)") }
            append("· 复制到 /Applications ...")
            let (ok2, o2) = remote("cp -R '\(tmpRemote)' '/Applications/'", sudo: true)
            if !ok2 { append("✗ 复制失败:\(o2)"); return }
            let (ok3, o3) = remote("xattr -dr com.apple.quarantine '/Applications/\(name)'", sudo: true)
            if !ok3 { append("⚠ 去隔离标记失败(可能不影响运行):\(o3)") }
            append("✔ 安装完成:/Applications/\(name)")
            showToast("✔ 安装成功：\(name)")
        } else if ext == "dmg" {
            append("· 挂载 dmg ...")
            let (okm, om) = remote("hdiutil attach '\(tmpRemote)' -nobrowse -mountpoint /tmp/dmgmount", sudo: false)
            if !okm { append("✗ 挂载失败:\(om)"); return }
            let (_, of) = remote("find /tmp/dmgmount -maxdepth 2 -name '*.app' | head -1")
            let appInDmg = of.trimmingCharacters(in: .whitespacesAndNewlines)
            if appInDmg.isEmpty { append("✗ dmg 内未找到 .app"); return }
            let destName = (appInDmg as NSString).lastPathComponent
            append("· 移除旧版本(若存在) ...")
            let (okr2, or2) = remote("rm -rf '/Applications/\(destName)'", sudo: true)
            if !okr2 { append("⚠ 移除旧版本失败(可能权限不足):\(or2)") }
            append("· 复制 \(destName) 到 /Applications ...")
            let (okc, oc) = remote("cp -R '\(appInDmg)' '/Applications/'", sudo: true)
            if !okc { append("✗ 复制失败:\(oc)"); return }
            let (okq, oq) = remote("xattr -dr com.apple.quarantine '/Applications/\(destName)'", sudo: true)
            if !okq { append("⚠ 去隔离标记失败:\(oq)")
            }
            let _ = remote("hdiutil detach /tmp/dmgmount")
            append("✔ 安装完成:/Applications/\(destName)")
            showToast("✔ 安装成功：\(destName)")
        } else if ext == "pkg" {
            append("· 安装 pkg (installer -target /) ...")
            let (okp, op) = remote("installer -pkg '\(tmpRemote)' -target / -allowUntrusted", sudo: true)
            if !okp { append("✗ pkg 安装失败:\(op)"); return }
            append("✔ pkg 安装完成")
            showToast("✔ 安装成功：\(name)")
        } else {
            append("✗ 不支持的格式:\(ext)(仅支持 .app/.dmg/.pkg)")
        }
        let _ = remote("rm -f '\(tmpRemote)'")
    }

    // 通用文件传输
    func transfer(local: String, remote: String, download: Bool) {
        guard !host.isEmpty, !user.isEmpty else { append("✗ 请先填写主机与用户名"); return }
        if download {
            append("▶ 下载 \(remote) → \(local)")
            let (ok, o) = scpDown(remote: remote, local: local)
            if ok { append("✔ 下载完成"); showToast("✔ 下载成功", target: .transferBox) } else { append("✗ 失败:\(o)") }
        } else {
            let dest = remote.isEmpty ? "/Users/\(user)/Downloads/" : remote
            append("▶ 上传 \(local) → \(dest)")
            let (ok, o) = scpUp(local: local, remote: dest)
            if ok { append("✔ 上传完成"); showToast("✔ 上传成功", target: .transferBox) } else { append("✗ 失败:\(o)") }
        }
    }
}

// MARK: - 主 App
@main
struct SSHAppInstallerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .tint(Color.accentColor)
                .frame(minWidth: 760, minHeight: 600)
        }
        .windowResizability(.contentSize)
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
    @State private var transferRemote: String = ""
    @State private var transferDownload: Bool = false
    @State private var showKeyPicker = false
    @State private var installViewMode: InstallViewMode = .icon
    @State private var transferViewMode: InstallViewMode = .icon
    @State private var droppedTransfers: [String] = []
    @State private var showDirConfirm: Bool = false       // 下载文件夹二次确认
    @State private var pendingDownloadRemote: String = ""
    @State private var pendingDownloadLocal: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            connectionSection
            Divider()
            TabView {
                installTab.tag(0)
                    .tabItem { Label("安装软件", systemImage: "square.and.arrow.down.on.square") }
                transferTab.tag(1)
                    .tabItem { Label("传文件", systemImage: "arrow.left.arrow.right") }
            }
            Divider()
            logSection
        }
        .padding(16)
        .overlay(alignment: .bottom) {
            if client.toast?.target == .window, let msg = client.toast?.message {
                ToastView(message: msg)
                    .padding(.bottom, 18)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: client.toast)
        .onReceive(client.$toast) { _ in
            guard client.toast != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                if client.toast != nil { client.toast = nil }
            }
        }
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
                TextField("主机 / IP", text: Binding(get: { client.host }, set: { client.host = $0 }))
                    .textFieldStyle(.roundedBorder)
                TextField("端口", text: Binding(get: { client.port }, set: { client.port = $0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                TextField("用户名", text: Binding(get: { client.user }, set: { client.user = $0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 120)
            }
            Picker("认证方式", selection: Binding(get: { client.useKey }, set: { client.useKey = $0 })) {
                Text("SSH 密钥").tag(true)
                Text("密码").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            if client.useKey {
                HStack {
                    TextField("密钥路径(默认 ~/.ssh/id_ed25519)", text: Binding(get: { client.keyPath }, set: { client.keyPath = $0 }))
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
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .fill(Color.accentColor.opacity(0.06))
                .frame(height: 210)
                .overlay(
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
                )
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers) { addInstallFile($0) }
                    return true
                }
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

    // MARK: 传文件 Tab
    private var transferTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("方向", selection: Binding(get: { transferDownload }, set: { transferDownload = $0 })) {
                Text("上传 (本机 → 远端)").tag(false)
                Text("下载 (远端 → 本机)").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 280)

            if transferDownload {
                // 下载:远端路径 + 本机保存路径(远端文件无法拖入,用文本框)
                TextField("远端路径 (如 /tmp/a.txt)", text: $transferRemote, prompt: Text("默认 /Users/\(client.user)/Downloads/")).textFieldStyle(.roundedBorder)
                HStack {
                    TextField("保存到本机路径", text: $transferLocal).textFieldStyle(.roundedBorder)
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
                        .stroke(Color(nsColor: .tertiaryLabelColor), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.4))
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
                TextField("远端目标路径", text: $transferRemote, prompt: Text("默认 /Users/\(client.user)/Downloads/")).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button(action: {
                    if transferDownload {
                        guard !transferLocal.isEmpty, !transferRemote.isEmpty else { return }
                        let l = transferLocal, r = transferRemote
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
                        let r = transferRemote.isEmpty ? "/Users/\(client.user)/Downloads/" : transferRemote
                        client.isBusy = true
                        Task {
                            for p in items { client.transfer(local: p, remote: r, download: false) }
                            await MainActor.run { client.isBusy = false }
                        }
                    }
                }) {
                    if client.isBusy { ProgressView().controlSize(.small) } else { Text(transferDownload ? "开始下载" : "开始上传（\(droppedTransfers.count)）").bold() }
                }
                .disabled(client.isBusy || (transferDownload ? (transferLocal.isEmpty || transferRemote.isEmpty) : droppedTransfers.isEmpty))
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .overlay(alignment: .center) {
            if client.toast?.target == .transferBox, let msg = client.toast?.message {
                ToastView(message: msg)
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .onChange(of: transferDownload) {
            if transferRemote.isEmpty {
                transferRemote = "/Users/\(client.user)/Downloads/"
            }
        }
        .onChange(of: client.user) {
            if transferRemote.hasPrefix("/Users/") && transferRemote.hasSuffix("/Downloads/") {
                transferRemote = "/Users/\(client.user)/Downloads/"
            }
        }
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
                .frame(height: 150)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .onChange(of: client.log) {
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

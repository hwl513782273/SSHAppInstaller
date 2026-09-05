import Foundation

// MARK: - SSHAppInstaller 安全与健壮性自测
// 编译：swiftc -o /tmp/safetytests Sources/ShellQuote.swift tests/SafetyTests.swift
// 说明：只依赖 Sources/ShellQuote.swift（纯函数，与 App 共用同一份源码），不依赖 UI。

var passed = 0
var failed = 0

func check(_ cond: Bool, _ name: String, _ detail: String = "") {
    if cond { passed += 1; print("  ✅ \(name)") }
    else { failed += 1; print("  ❌ \(name)\n     \(detail)") }
}

func eq(_ actual: String, _ expected: String, _ name: String) {
    check(actual == expected, name, "期望: \(expected)\n     实际: \(actual)")
}

@main
struct SafetyTests {
    static func main() {
        print("=== 1. shellQuote：远端命令注入防护 ===")
        eq(shellQuote("MyApp.app"), "'MyApp.app'", "普通名称")
        eq(shellQuote("Bob's App.app"), "'Bob'\\''s App.app'", "合法但含单引号的名称（原本会让命令错乱）")
        eq(shellQuote("/Applications/My App.app"), "'/Applications/My App.app'", "路径含空格")
        eq(shellQuote("a$(whoami)b"), "'a$(whoami)b'", "含命令替换符")
        eq(shellQuote("back`id`tick"), "'back`id`tick'", "含反引号")
        eq(shellQuote("semi;colon"), "'semi;colon'", "含分号")
        eq(shellQuote(""), "''", "空字符串")

        print("\n=== 2. 真跑 /bin/sh 验证转义语义（确认不会被注入执行）===")
        // 恶意样本用 echo 而不是破坏性命令：万一转义失效，也只是打印而不会造成破坏
        roundTrip("Bob's App.app")
        roundTrip("Foo'; echo __PWNED__; '")
        roundTrip("/tmp/My 'weird' name.app")

        print("\n=== 3. validateEndpoint：连接参数校验 ===")
        check(validateEndpoint(host: "192.168.2.234", user: "banqiu", port: "22") == nil, "合法参数放行")
        check(validateEndpoint(host: "", user: "banqiu", port: "22") != nil, "空主机被拒")
        check(validateEndpoint(host: "1.2.3.4", user: "", port: "22") != nil, "空用户名被拒")
        check(validateEndpoint(host: "1.2.3.4", user: "banqiu", port: "abc") != nil, "非数字端口被拒")
        check(validateEndpoint(host: "1.2.3.4", user: "banqiu", port: "99999") != nil, "超范围端口被拒")
        check(validateEndpoint(host: "1.2.3.4", user: "banqiu", port: "0") != nil, "端口 0 被拒")
        check(validateEndpoint(host: "host; rm -rf /", user: "banqiu", port: "22") != nil, "主机含分号被拒")
        check(validateEndpoint(host: "1.2.3.4", user: "ban qiu", port: "22") != nil, "用户名含空格被拒")
        check(validateEndpoint(host: "  1.2.3.4  ", user: " banqiu ", port: " 22 ") == nil, "首尾空白被容忍")
        let t = trimmedEndpoint(host: "  1.2.3.4  ", user: " banqiu ", port: " 22 ")
        check(t.host == "1.2.3.4" && t.user == "banqiu" && t.port == "22", "trimmedEndpoint 正确去空白")

        print("\n=== 4. Process 管道读取：P0-2 死锁修复验证 ===")
        testPipeDrain()

        print("\n=== 5. 对照实验：修复前的写法确实会死锁 ===")
        testLegacyPatternDeadlocks()

        print("\n———— 通过 \(passed) 项，失败 \(failed) 项 ————")
        exit(failed == 0 ? 0 : 1)
    }

    /// 把转义结果交给真实 shell 执行，确认输出与原文完全一致。
    /// 若引号被提前闭合，注入的命令会被执行，输出就会对不上。
    static func roundTrip(_ raw: String) {
        let script = "printf '%s' \(shellQuote(raw))"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        let out = Pipe()
        p.standardOutput = out
        do { try p.run() } catch { check(false, "shell 往返: \(raw)", "启动失败 \(error)"); return }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let got = String(data: data, encoding: .utf8) ?? ""
        check(got == raw, "shell 往返未被注入: \(raw)", "期望: \(raw)\n     实际: \(got)")
    }

    /// 用远超管道缓冲区(约 64KB)的输出量，验证「先并发抽干管道再 waitUntilExit」不会死锁且数据完整。
    static func testPipeDrain() {
        let probe = "/tmp/sshai_deadlock_probe.txt"
        let line = String(repeating: "0123456789", count: 100)      // 1000 字节
        var content = ""
        for _ in 0..<300 { content += line + "\n" }                 // 约 301KB，远超 64KB 缓冲区
        do { try content.write(toFile: probe, atomically: true, encoding: .utf8) }
        catch { check(false, "构造探针文件", "\(error)"); return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/cat")
        proc.arguments = [probe]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()

        let started = Date()
        do { try proc.run() } catch { check(false, "启动 /bin/cat", "\(error)"); return }

        // 与 SSHClient.run 相同的新方案：后台并发抽干 + 超时兜底
        let group = DispatchGroup()
        let lock = NSLock()
        var buf = Data()
        group.enter()
        DispatchQueue.global().async {
            var b = Data()
            while true {
                let d = out.fileHandleForReading.availableData
                if d.isEmpty { break }
                b.append(d)
            }
            lock.lock(); buf = b; lock.unlock()
            group.leave()
        }
        let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: killer)

        let result = group.wait(timeout: .now() + 12)   // 12 秒内读不完就判定为死锁
        killer.cancel()
        proc.waitUntilExit()
        lock.lock(); let gotLen = buf.count; lock.unlock()

        let expected = content.data(using: .utf8)!.count
        check(result == .success, "大输出(约 \(expected/1024)KB)未阻塞 —— 无死锁")
        check(gotLen == expected, "输出完整无损", "期望 \(expected) 字节，实际 \(gotLen)")
        print("     耗时 \(String(format: "%.2f", Date().timeIntervalSince(started)))s，读回 \(gotLen) 字节")

        try? FileManager.default.removeItem(atPath: probe)
    }

    /// 对照实验：复现修复前的写法（先 waitUntilExit，再读管道）。
    /// 预期结果是 5 秒内进程根本退不出来 —— 子进程写满约 64KB 管道后阻塞等待读取，
    /// 父进程却卡在 waitUntilExit 等它退出，两边互相死等。
    /// 这里用超时 + terminate 兜底，避免测试进程自己被拖死。
    static func testLegacyPatternDeadlocks() {
        let probe = "/tmp/sshai_legacy_probe.txt"
        let line = String(repeating: "0123456789", count: 100)
        var content = ""
        for _ in 0..<300 { content += line + "\n" }
        try? content.write(toFile: probe, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/cat")
        proc.arguments = [probe]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try? proc.run()

        let exitedFlag = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            proc.waitUntilExit()      // 修复前的写法：先等进程退出，再读管道
            exitedFlag.signal()
        }
        let exited = exitedFlag.wait(timeout: .now() + 5) == .success
        if !exited { proc.terminate() }

        check(!exited, "修复前的写法(先 wait 后 read)确实卡死 —— 证明该修复必要",
              "此项为对照：子进程 5 秒内都没退出，正是原实现的死锁表现")
        try? FileManager.default.removeItem(atPath: probe)
    }
}

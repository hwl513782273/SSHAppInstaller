import Foundation

// MARK: - 命令构造安全工具（纯函数，可独立单测）

/// 把任意字符串安全地包进单引号，供远端 shell 使用。
/// 内部单引号按 shell 规则替换为 '\''（结束引号 + 转义单引号 + 重开引号）。
///
/// 所有拼进远端命令的路径/文件名都必须过这一层。漏掉会有两个后果：
/// 1. 合法命名也会让命令错乱，例如 `Bob's App.app` 会提前闭合引号；
/// 2. 恶意命名可闭合引号后追加任意命令，且这些命令带 sudo 执行。
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// 校验连接参数。合法返回 nil，否则返回可直接展示给用户的错误描述。
/// host / user 会在此去掉首尾空白，并拒绝空白与 shell 元字符
/// （它们既会破坏 ssh/scp 的参数结构，也可能被远端 shell 解释）。
func validateEndpoint(host: String, user: String, port: String) -> String? {
    let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
    let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
    let p = port.trimmingCharacters(in: .whitespacesAndNewlines)

    if h.isEmpty { return "请填写主机 / IP" }
    if u.isEmpty { return "请填写用户名" }

    let forbidden = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ";&|`$<>()!*?[]{}~^#\"'\\"))
    if h.rangeOfCharacter(from: forbidden) != nil {
        return "主机名含非法字符（不能有空格或 ; & | $ 等）"
    }
    if u.rangeOfCharacter(from: forbidden) != nil {
        return "用户名含非法字符（不能有空格或 ; & | $ 等）"
    }
    if !p.isEmpty {
        guard let n = Int(p), (1...65535).contains(n) else {
            return "端口必须是 1-65535 的整数"
        }
    }
    return nil
}

/// 返回去掉首尾空白的连接参数（配合 validateEndpoint 使用）
func trimmedEndpoint(host: String, user: String, port: String) -> (host: String, user: String, port: String) {
    (host.trimmingCharacters(in: .whitespacesAndNewlines),
     user.trimmingCharacters(in: .whitespacesAndNewlines),
     port.trimmingCharacters(in: .whitespacesAndNewlines))
}

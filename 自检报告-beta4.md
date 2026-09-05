# SSHAppInstaller 安全加固与健壮性修复 · 自检报告

- 版本：beta4（内部版本仍为 1.0，未经真机确认前不打正式版号）
- 日期：2026-09-06
- 提交：`259e5be`
- 范围：代码审查发现的 5 项 P0 + 主要 P1 + 「关于」界面与版权

---

## 一、修复清单

### P0 · 安全与卡顿（5 项，全部已修）

| # | 问题 | 根因 | 改法 |
|---|---|---|---|
| 1 | **远端命令注入** | `install()` 把本地文件名直接拼进远端命令（`rm -rf '/Applications/\(name)'`），未转义单引号。文件名含 `'` 即可闭合引号执行任意命令，且带 sudo；`Bob's App.app` 这类合法命名也会让命令错乱 | 新增 `shellQuote()`，所有远端命令里的路径与文件名统一过这一层 |
| 2 | **Process 死锁** | `run()` 里 `waitUntilExit()` 写在 `readDataToEndOfFile()` 之前，子进程输出超过管道缓冲区（约 64KB）就阻塞写，父进程却在等它退出 → 双向死等。scp 未加 `-q`，传大文件时必现卡死 | 改为后台并发抽干 out/err，读完再 `waitUntilExit` |
| 3 | **askpass 脚本可劫持** | 脚本写在固定路径 `NSTemporaryDirectory()/sshappinstaller_askpass.sh`，不校验内容与属主，`try?` 吞掉写入和 chmod 错误。他人抢先建该文件即可截获密码（CWE-377） | 改为 UUID 随机目录（0700）+ 脚本 0700，仅创建一次，失败明确报错，退出时清理 |
| 4 | **安装失败会丢应用** | 先 `rm -rf /Applications/X` 再 `cp -R`，cp 一旦失败，目标机上旧版已删、新版没装上 | 改为原子替换：暂存区 → 旧版 mv 成备份 → 就位 → 成功才删备份；任一步失败自动回滚 |
| 5 | **无超时、无取消** | `Process` 无超时，网络挂起时 `isBusy` 永远为 true，界面卡死且无法中止 | 分层超时：默认 600s、连接测试 15s、scp 1800s；超时终止并给出明确错误 |

### P1 · 健壮性（7 项，全部已修）

- dmg 挂载点由固定 `/tmp/dmgmount` 改为随机路径，并 `defer` detach，避免异常退出残留后再也挂不上
- `install()` 用 `defer` 统一清理远端临时包，失败分支不再遗漏（原先多个 `return` 会跳过清理）
- dmg 内 `.app` 查找改为优先 `maxdepth 1`、找不到再退 `maxdepth 2`
- 临时上传包名加 UUID，避免与远端 `/tmp` 同名文件冲突
- 新增 `validateEndpoint()`：主机/用户名去空白并拒绝 shell 元字符，端口须为 1–65535 整数
- 连接参数（主机/端口/用户名/认证方式/密钥路径）任一变更，`connectionOK` 立即重置，不再出现换主机后仍显示绿勾
- 日志加上限（20000 字符），避免长任务后 SwiftUI 渲染超大字符串卡顿

### P2 · 规范（2 项，已修）

- 新增标准「关于 SSH App Installer」面板（菜单 → 关于）
- `Info.plist` 版权由 `WorkBuddy` 改为 `Copyright © 2026 banqiu. Released under the MIT License.`

---

## 二、自测结果

新增 `tests/SafetyTests.swift`，与 App 共用同一份 `Sources/ShellQuote.swift` 源码（不是副本）。
编译运行：`swiftc -O -o /tmp/safetytests Sources/ShellQuote.swift tests/SafetyTests.swift`

**结果：通过 23 项，失败 0 项**

```
1. shellQuote 注入防护            7/7  ✅  普通名 / Bob's App.app / 空格 / $() / 反引号 / 分号 / 空串
2. 真跑 /bin/sh 往返验证           3/3  ✅  转义后交给真实 shell 执行，输出与原文完全一致，未被注入
3. validateEndpoint 参数校验      10/10 ✅  空主机、空用户名、非法字符、端口 abc/0/99999 均被拒；首尾空白被容忍
4. 管道读取（死锁修复）            2/2  ✅  293KB 输出 0.07s 读完，300300 字节完整无损
5. 对照实验（证明修复必要）        1/1  ✅  复现修复前写法：5 秒内子进程未退出 = 死锁确实存在
```

> 恶意测试样本使用 `echo __PWNED__` 而非破坏性命令，即使转义失效也不会造成破坏。
> 对照实验用超时 + terminate 兜底，测试进程本身不会被拖死。

---

## 三、构建与安装验证

| 检查项 | 结果 |
|---|---|
| `swiftc` 编译 | ✅ 零错零警，arm64 Mach-O |
| ad-hoc 签名 | ✅ `Signature=adhoc` |
| 安装到 `/Applications` | ✅ 已替换并刷新 LaunchServices |
| 启动冒烟 | ✅ 进程存活，PID 19513 |
| 「关于」菜单项 | ✅ 二进制内含 UTF-8 中文串，且引用 `orderFrontStandardAboutPanel` |
| Info.plist 版权 | ✅ `Copyright © 2026 banqiu. Released under the MIT License.` |
| DMG 内容 | ✅ `.app` + Applications 替身均正确，无上次那种 `ln` 告警 |
| 二进制一致性 | ✅ build / DMG 内 / 已安装 三处 md5 均为 `ce4d3590...` |
| DMG 打包方式 | ✅ 改用 `mktemp -d` 临时目录，不再依赖会残留的 `staging/` |

---

## 四、未覆盖项与已知限制（如实说明）

1. **未做 SSH 端到端连通测试。** 本机 22 端口未监听（未开启「远程登录」），需要一台真实对端才能验证连接、上传、下载、安装的完整链路。我**没有擅自开启**系统级远程登录服务——如要补测，你确认后我再开，测完可关闭。
   → 受此限制，以下改动仅做了代码级与单元级验证，**尚未经过真机验证**：原子替换流程、dmg 随机挂载点、超时行为、参数校验的实际拦截效果。
2. **sudo 密码仍出现在远端命令行**（`printf '%s\n' <pw> | sudo -S ...`）。同机其他用户理论上可从进程列表看到。改用 ssh stdin 管道喂密码可根治，但会与现有 askpass 机制冲突，本轮未动。
3. **关闭了主机密钥校验**（`StrictHostKeyChecking=no` + `UserKnownHostsFile=/dev/null`）。局域网自用可接受，但密码模式下存在中间人风险（密钥模式不泄露私钥）。
4. `install()` 的 pkg 分支依赖 `installer` 自身行为，无原子性保证。

---

## 五、产物

- 新包：`15-SSHAppInstaller-1.0-beta4-universal.dmg`（1.1M）
- 历史保留（未覆盖）：`1.0-universal`（正式版）、`1.0-universal-20260906-pre`、`1.0-beta`、`1.0-beta2`、`1.0-beta3`
- 新增源码：`Sources/ShellQuote.swift`、`tests/SafetyTests.swift`
- git：提交 `259e5be`，工作区干净，DMG 与 build 产物已被 `.gitignore` 排除

**真机确认 OK 后，我再去掉 `-beta` 定正式版。**

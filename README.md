# OrbitTerm Client

OrbitTerm 是面向 macOS 与 iOS 的 SSH 客户端和运维工作台，不是堡垒机或 SSH 网关。

## 当前安全基线

- SSH 首次连接必须确认 Host Key 指纹。
- 已信任记录保存在 OrbitTerm 自己的本地 `known_hosts`。
- Host Key 变化、撤销或无法验证时连接会被阻断。
- Terminal、SFTP、Monitor、Docker 和 Batch 复用已验证 SSH 会话。
- Release 构建不会回退到 legacy SSH、SFTP、channel 或 exec 路径。
- 不提供 Trust All 或“仍然接受已变化 Host Key”。

## Telnet 兼容模式

Telnet 只用于必须维护的旧网络设备，并默认关闭。它不提供加密或服务器身份验证，用户名、密码、命令和终端内容可能被监听或篡改。

启用步骤：

1. 打开“设置 > 终端与连接”。
2. 开启“启用 Telnet”，阅读并确认明文传输警告。
3. 添加或编辑资产时选择 Telnet。
4. 每个目标首次连接时再次确认目标地址和风险。

关闭 Telnet 会断开现有 Telnet 会话并清除目标确认。SSH 不会在连接失败后自动切换到 Telnet，Telnet 也不提供 SFTP、Monitor、Docker、Batch 或 Quick Key。

## 本地验证构建

```bash
scripts/security/check_all.sh
ORBITTERM_RUN_OPENSSH_SMOKE=1 scripts/security/run_openssh_smoke.sh
scripts/make_release.sh
```

`make_release.sh` 生成的 DMG 和 IPA 均为 `unsigned` 本地验证产物，不得作为正式客户端分发。正式发布还需要 Apple Distribution / Developer ID 签名、macOS notarization 和 App Store validation。

## 已知限制

- Docker rename/update 尚未开放。
- Quick Key 远程部署尚未开放。
- Batch 只执行已有 verified session 的目标。
- Android SSH 不在当前 Apple 客户端发布范围。
- Known Hosts 管理界面尚未提供。

发布检查见 [RC1-LAUNCH-CHECKLIST.md](docs/release/RC1-LAUNCH-CHECKLIST.md)。

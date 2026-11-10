# 五端删除墓碑验收准备（2026-11-09）

本轮产品源码候选为 `c7d9672938a997d041f8f50274965a3948366a47`；它相对 `dea67fd135f71843ae89b09f66070261189a0b25` 仅增加预检台账，产品源码完全相同，包含 iOS `848b2eb` 修复。Mac 外置盘干净检出、Ubuntu VM 独立检出均精确固定该提交。原集成工作树两份来源未核实的 Android JNI `.so` 改动仍保留且未进入候选。用户本轮确认使用同一专用非生产测试账户，并允许新建、编辑、可恢复软删除纯虚构资产；所有真实资产和正式客户端数据均不纳入操作。

## 候选与门禁

| 平台 | 候选准备与当前边界 |
| --- | --- |
| macOS | `c7d9672` 本地 Rust arm64 Release 构建成功。首次 Xcode 构建缺 QA 描述文件、补自动签名后缺 Rust 目标库、补库后缺审计 FreeRDP 运行时；三次失败保留。使用与源码相同版本的既有 FreeRDP 3.26.0／OpenSSL 3.6.0 运行时并核对上游归档摘要，隔离运行时测试通过。独立 QA 检出仅改精确 QA Bundle ID 与私有 Application Support 目录两处，补丁 SHA-256 `8b2e43246c4ec57c79b8048312cfc0993d9d65bb348a6a242b51ce8286a9f5c9`；Release 签名包 `com.orbitterm.tombstone.macos`／`20261109.9` 严格验签通过，主程序 SHA-256 `a4b77294581a80680ba7fad64c2ce5547dee57bf22ff0f3faa4af042f4a0bcc9`。实体 Mac GUI 已进入专用账户登录，停在首次设置主密码，尚无资产 GUI 结果。正式包和旧 QA 保留。 |
| iOS | 新 Bundle ID 的 Release QA 严格验签且描述文件覆盖 iPhone 13 mini，但设备安装被个人开发签名的应用数量上限拒绝，失败保留。随后用已安装的独立 `com.orbitterm.performance.ios` 身份从同一产品源码重新签名构建 `20261109.9`，严格验签通过，主程序 SHA-256 `b1878bf9fe99434b3df90d26bef78689e4ba8d8031c68a558ef553257487be6c`；USB 原位更新成功，设备应用清单确认版本。旧 `.8` 在更新前由操作者在真机确认：同意框初始未勾选，打开条款再返回仍未勾选。此项仅补 iOS 条款专项，不算墓碑矩阵。新 `.9` 的账户、资产和墓碑 GUI 尚未验。 |
| Android | 从干净检出构建 arm64 独立 QA APK，首次缺 Android SDK 路径失败；指定既有 SDK 后 `assembleQa` 成功。APK ID `com.orbitterm.android.qa`、SHA-256 `8473c839f36a94dd2e5c600d37ddf351844fdedad4361b1b0112e234165df4c3`，签名证书与 K60 旧 QA 相同；原位安装成功，从设备回取的 `base.apk` 与候选字节一致。构建临时写入的 JNI 二进制只在独立检出内恢复，检出再次干净。K60 账户及可见资产 GUI 尚未验；受保护 QA 不以黑屏镜像代替界面观察。 |
| Windows | 同提交 PR 合并测试树 `dc1efce9fdd20d7306035a28f0168cc004a1c52c` 与 `c7d9672` Git tree 完全相同。Windows CI 首轮安全测试报告 412／412 通过，但 xUnit/VSTest 退出清理空引用导致作业失败、未产包；重跑 attempt 2 成功并生成测试 MSIX，首轮失败保留。归档 SHA-256 `01a2b91bfcab388a158dbbdededef393ce9ee9cd32f07f7e26cd3b6c0e9b3588`，MSIX SHA-256 `b8a6f316f3e5bf6c2341ee13fb3bae9c75369f3efa1ab42a1f2f5ec8dbd511c6`，与随包摘要一致；ZIP 完整，清单为 `OrbitTerm.Client`／`0.3.0.33`／x64，含签名文件。Windows App 已进入 Win10 桌面，但本机包验签、安装、账户解锁和 P0 操作未完成。 |
| Linux | Ubuntu 24.04 VM 通过既有 SSH 信任与密钥认证，独立干净检出及项目墓碑预检通过；原有两个 VM 工作目录未改。原生 Release 二进制构建成功，SHA-256 `82b9a83c5a268a3c666411aca029c756d57f92d1b5cf262026ad467cc964ac49`。图形桌面 RDP 连接遇自签名证书警告，等待操作者亲自核对；独立 XDG／D-Bus／密钥环 QA 尚未启动，账户、墓碑和冲突选择未验。 |

Linux CI 对 `c7d9672` 首轮成功；Windows CI 为上述失败→重跑成功。Security Gates 当次查询仍运行中，Android instrumentation／Release、Rust、依赖和桌面视觉 job 已成功，Apple checked-path 尚未完成；两个条件式 RC job 被跳过，不计通过。旧 `eb06f24` 回执不归本候选。以上自动化与构建不替代真实设备 GUI。

## P0-1 当前矩阵

| 场景 | 状态 | 五端活动列表 | 最近删除恰一条 | 本机凭据移除 | 三次重复同步不复活 |
| --- | --- | --- | --- | --- | --- |
| `delete_then_pull` | 未开始 | 未验证 | 未验证 | 未验证 | 未验证 |
| `delete_after_edit` | 未开始 | 未验证 | 未验证 | 未验证 | 未验证 |
| `offline_delete_then_reconnect` | 未开始 | 未验证 | 未验证 | 未验证 | 未验证 |
| `repeat_sync_no_resurrection` | 未开始 | 未验证 | 未验证 | 未验证 | 未验证 |

下一步先完成五端同源独立 QA 的安装、解锁及账户归属核对，再新建唯一虚构同步资产并执行 `delete_then_pull`。Linux 若出现墓碑冲突，必须明确选择“接受删除”并记录选择。原始包、构建日志和详细证据留在受限外置盘，不向仓库提交账号、密码、端点、完整资产信息或设备标识。完整矩阵通过前，`cross-platform-asset-tombstones` 保持 `in-progress`。

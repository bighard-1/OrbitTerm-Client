# 2026-10-13 外置盘加密与本地开发环境验收

本记录只涉及本机开发环境和 GitHub 代码快照，不是客户端功能发布或五端真机放行证据。仓库均为**公开仓库**；快照分支保存未完成的工作树状态，不合并 `main`，不代表代码审查、CI 或正式签名通过。没有记录磁盘密码、测试账户凭据、资产地址或设备标识。

## 加密前代码快照

通过独立临时 Git 索引创建快照提交，原工作树及其索引未清空或切换。每条分支推送后均以 `git ls-remote` 核对远端 SHA。

| 仓库 | 公开快照分支 | 远端提交 | 纳入本地未提交文件数 |
| --- | --- | --- | ---: |
| OrbitTerm-Client | `codex/storage-snapshot-20261013-client-integration` | `805a7511f54ab30d9db3a61f1b8380563e62fccf` | 1 |
| OrbitTerm-Client | `codex/storage-snapshot-20261013-client-main` | `6d055067f2b134f78f6b121d25b85352142fcff7` | 106 |
| OrbitTerm-Client | `codex/storage-snapshot-20261013-client-maturity` | `34b02d7a82eaa473143580f5e7ba652475be16be` | 12 |
| OrbitTerm-Master | `codex/storage-snapshot-20261013-server-main` | `cee58f907311be3a068044bd753aafcbbe75a84b` | 4 |
| OrbitTerm-Master | `codex/storage-snapshot-20261013-server-maturity` | `35634cae94e6bb643f6decb57e1884936339b7b2` | 已提交分支 |

服务端主工作树另外两份 `.DS_Store` 未纳入快照。客户端已提交的 `main`、`codex/five-platform-integration`、`codex/linux-client-phase28` 和服务端已提交的 `main`、`codex/canonical-asset-uuid` 当时均与远端一致。Git 不保存被忽略的 SDK、AVD 本机状态、签名材料、Keychain 或测试凭据。

## 原地加密与加密后验证

- 用户本人在 Finder 为现有 APFS `ExternalSSD` 卷设置密码并点击“加密磁盘”；没有使用“抹掉磁盘”。系统先显示 22% 至 92% 的加密进度，随后不再显示进度，报告 `FileVault: Yes (Unlocked)`。卷名仍为 `ExternalSSD`，挂载路径仍为 `/Volumes/ExternalSSD`，保持读写。
- 用户 SDK、项目专用 SDK、AVD 和 Windows 测试归档四个路径分别用临时探针完成创建、读取比对、覆盖、重命名和删除；探针已清理。三个 SDK/AVD 入口仍解析到外置盘。
- Windows 归档的 10 个 MSIX 均与各自 `SHA256.txt` 一致，且逐个与同盘 Recovery 副本一致；ZIP 完整性检查及与 Recovery 副本比较通过。专用 SDK 的 `adb`、模拟器、NDK 属性文件和三个有效 AVD 配置抽样与 Recovery 副本一致。**同盘 Recovery 不是独立备份**，这些比较也不是全盘逐字节审计。
- 第一次 SDK 抽样脚本误用 zsh 特殊变量 `path`，覆盖命令搜索路径后退出 127；改用普通变量重跑，SDK/AVD 抽样比较通过。此失败是验证脚本错误，不是磁盘或文件损坏证据。
- 加密后再次运行 `scripts/security/check_android_release_gates.sh`，完整脚本通过；Gradle 417 项中 3 项执行、414 项复用缓存，未签名 arm64/x86_64 Release APK 哈希与加密前相同。该本地门禁**不等于生产签名或 Android 实体机验收**。
- Android 16 `OrbitTerm_API36_ARM` 和 Android 15 `OrbitTerm_API35_ARM` 分别使用对应 SDK 的只读、禁用快照模式冷启动，均报告系统启动完成并正常关闭；ADB 最终无遗留设备。
- `diskutil verifyVolume` 对该卷执行只读 `fsck_apfs -n`，退出码 0，报告文件系统正常；校验后自动恢复原挂载状态。内置盘约余 34 GiB，外置盘约余 865 GiB。

## 尚未覆盖的边界

未主动弹出磁盘并以密码重新解锁，也未检验磁盘丢失后的恢复。密码须由用户自行安全保管；若遗失，GitHub 代码快照只能恢复代码，不能恢复外置盘上的 AVD 本机状态或未备份凭据。仍建议后续用第二块物理盘或 NAS 对活动数据做独立备份，并实测还原。Android/Windows 实体设备、生产签名和五端完整验收均未因本次本机检查而完成。

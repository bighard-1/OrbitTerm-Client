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

## 常驻外置盘的构建缓存减压

用户明确主要目标是给 256G 内置盘减压，外置盘固定用于本机，且不要求主动弹出后重新输入密码的测试。以下是**本地环境路径调整**，不是项目源码或五端功能变更：

| 原调用路径 | 外置盘实际位置 | 迁移前大小 | 切换后验证 |
| --- | --- | ---: | --- |
| 当前 `3c20` 工作树 `orbit-core/target` | `Development/BuildCaches/OrbitTerm-Client-3c20/orbit-core-target` | 约 14 GiB | 内容核对 0 差异；离线 `cargo check --lib` 通过 |
| 用户 `~/.gradle` | `Development/BuildCaches/gradle-user-home` | 约 1.7 GiB | 内容核对 0 差异；Gradle 8.13 离线 `help` 通过 |
| `~/Library/Developer/Xcode/DerivedData` | `Development/BuildCaches/Xcode-DerivedData` | 约 6.8 GiB | 内容核对 0 差异；默认 DerivedData 的 macOS Debug 无签名构建通过 |

三处均先用 `ditto` 复制、再用普通文件内容校验 `rsync -acn --delete` 比对为 0 差异，之后将旧路径改为指向外置盘的符号链接，验证工具链可运行后才删除内置盘原有的**可重建缓存副本**。Rust 目录两边各有 45,611 个普通文件。首次 Rust 比对误用 macOS `rsync -E`，工具尝试读取不存在的 `._` 资源分叉并出现大量错误，已中止；不带 `-E` 的完整内容比对通过，失败结果未抹除。另一次 Xcode `-list` 诊断曾使用不存在的项目子路径而退出，改用仓库根目录 `OrbitTerm.xcodeproj` 后，构建设置读取及实际 Debug 构建通过；该首次路径错误不是项目构建故障。

完成三处缓存初始迁移时，内置盘可用空间由本轮开始时约 35 GiB 增至约 56 GiB；这是**当时状态**，下节记录了 Xcode 测试发现不兼容后回退的最终状态。Android 的用户 SDK、项目专用 SDK、AVD 及 Windows 测试归档仍保持先前已验收的外置盘路径。没有移动正在运行的 CoreSimulator 设备数据、Xcode 应用、其他 Codex 工作树的 Rust 缓存、桌面主工作树构建产物、Rust 工具链或签名材料。部分脚本会显式把构建目录放在 `/private/tmp` 或工作树 `build`，不走默认 DerivedData；因此**不能保证所有后续文件或应用安装都自动进入外置盘**。使用这些脚本时应单独指定并核对输出路径与空余空间。若外置卷未挂载或卷名变化，仍在外置盘的链接会失效；用户选择不做主动弹出/重解锁测试，此项不作为本轮完成条件。独立异盘备份仍是后续数据安全事项，不影响本次减压结果。

## Xcode 测试运行回退与 Apple 验收续测

恢复客户端验收时，在固定源码 `8fbe488`（本轮仅验收文档有未提交改动）上发现：`TMPDIR` 与 DerivedData 都指向外置盘的 Apple 全量门禁在 macOS checked-FFI `xctest` 创建 worker 前停滞，约 5 分钟无测试用例执行，主动终止，**不记为门禁通过**。改为内置 `/private/tmp` 后，同套件及生命周期、资源压力、HTTP 故障定向测试依次通过，随后 iOS 模拟器 UI 宿主持续报告 Xcode `DebuggerVersionStore.StoreError` / `no debugger version`，仍无 UI 用例执行，主动终止；这与之前本机的调试器启动故障同类，不能冒充应用断言失败或 UI 通过。

为区分 `TMPDIR` 与 DerivedData，再保持 `/private/tmp` 在内置盘、仅把 macOS 单测 DerivedData 放外置盘，`xctest` 再次停在 worker 创建前；相同单测使用内置盘 DerivedData 后 **6/6 通过**。因此本机 Xcode 默认 DerivedData 从外置盘逐文件核对后恢复为内置盘普通目录，外置旧副本与失败路径的可重建缓存已清理；未动项目源码、Xcode 应用或模拟器设备目录。内置盘最终约余 **48–49 GiB**、加密外置盘约余 **850 GiB**。Rust `target`、Gradle 用户缓存、Android SDK/AVD 仍在外置盘，继续为内置盘减压。

在内置盘 DerivedData 上另行补验：完整 macOS checked-FFI XCTest 结果包 **339/339 通过、0 失败/跳过**；macOS UI 测试目标 `build-for-testing`、macOS Release、iPhoneOS Release、iOS Simulator Release **无签名源码构建通过**；静态安全扫描通过。macOS 编译仍有已知 FreeRDP 废弃接口警告。以上是分段结果，**不等于**这轮被中断的 Apple 全量门禁通过，也不等于签名发布包或 iPhone 实体设备验收。已签名 macOS UI 冒烟要求专用签名 runner；本机仅有 Apple Development 身份，且该脚本的普通 Bundle ID 不能当作隔离 QA 包在已有正式版数据的机器上随意运行。Android/Windows 真机与五端发布矩阵仍未完成。

## Xcode 26.6 iOS UI 门禁续验

在同一产品源码 `8fbe488`、内置盘 DerivedData 上继续定位。Xcode 26.6 `-checkFirstLaunchStatus` 退出 0，LLDB 可运行，iOS 26.5 模拟器运行时及目的地均可识别。不能仅凭 `DebuggerVersionStore.StoreError` 文本判定用例结果，故改用测试结果包核对真实执行情况。先以关闭并行的单条无账户启动用例验证，`.xcresult` 为 **1/1 通过**；再运行完整 iOS UI 套件，`.xcresult` 为 **12/12 通过、0 失败/跳过**。两次命令均仍打印该调试器警告，说明**本机这次警告与测试结果并存**。前节被主动终止的全量门禁仍是未通过/未取得 UI 结果的旧记录，不追认通过。

因此仅修改 Apple 验收脚本：UI 套件固定单模拟器串行运行，指定结果包并校验实际总数不少于 12、全部通过且无跳过；退出码或警告文字不单独充当通过证据。再以内置 `/private/tmp` 执行修改后的**完整** `check_apple_release_gates.sh`，脚本退出 0，最终输出 `[PASS] Apple release gates`，其中 iOS UI 结果再次为 **12/12**。macOS checked-FFI、生命周期/资源/HTTP 故障、macOS/iOS 源码构建、安全/ABI/生成工程检查均完成；既有 FreeRDP 废弃接口编译警告仍存在。签名 macOS UI 冒烟与真实设备性能证据不属于这条普通源码门禁，仍未执行，不能据此放行五端。

收尾检查发现脚本原有 XcodeGen 清理 `trap` 会覆盖最初的 DerivedData 清理，导致本轮 `/private/tmp` 留下约 **2.5 GiB** 的可重建构建目录；确认它是本轮脚本生成、归当前用户所有后精确删除。脚本已改为退出时同时清理 XcodeGen 临时目录和 DerivedData，`bash -n` 与 `git diff --check` 通过。没有清空模拟器、变更 iPhone 应用、触碰 Mac 正式版、测试账户或真实主机；Rust/Gradle/Android 外置盘路径保持不变。

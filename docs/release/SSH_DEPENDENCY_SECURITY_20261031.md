# SSH 依赖安全升级（2026-10-31）

## 门禁发现与范围

固定客户端提交 `0fdbc057e663c059c41b9b82601c4f0636627c55` 的 [Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/41274792018) 最终 **completed／failure**：依赖扫描命中 `orbit-core/Cargo.lock` 中 `russh 0.63.3` 的 HIGH `CVE-2026-116794`，修复版本 0.65；Apple checked-path、Android 仪器／发布、Rust Release、桌面契约五项常规作业成功，专用签名 macOS UI／OpenSSH RC 条件 skipped。Trivy 数据库下载和扫描实际完成、退出 1，不是执行器／网络失败。旧成功与本次真实失败分别保留。

上游 [Agent 确认约束公告](https://github.com/Eugeny/russh/security/advisories/GHSA-vp5q-ff62-jwqv) 指向 agent server。对本项目生产 Rust 源码检索，未发现 agent server、SSH_AUTH_SOCK 或 agent 认证入口；这只是当前调用面核查，不把整个依赖风险判为不适用。上游 [0.65.0 发布说明](https://github.com/Eugeny/russh/releases/tag/v0.65.0) 还修复了 [客户端 EXT_INFO 内存增长](https://github.com/Eugeny/russh/security/advisories/GHSA-4p9f-7p9m-5vfg) 和 [对端零包长使通道写入停滞](https://github.com/Eugeny/russh/security/advisories/GHSA-fw5c-8223-6h42)。因此采用升级，不添加忽略项、不降低 HIGH／CRITICAL 扫描和许可检查。没有在真实主机主动利用这些漏洞，也不把此前偶发长等待归因于新公告。

## 源码候选与首次失败

本条所在提交将核心依赖下限升至 `0.65.0`，同步更新核心和 Linux 两份 Cargo.lock，锁定相同 crates.io 校验摘要；未顺带升级其他依赖。新库 MSRV 1.89，低于 Linux 现有声明 1.92；许可证 Apache-2.0。适配隔离 OTP 服务器与单测的 `VerifiedPublicKey` 参数，仍比较已验证公钥的 key_data；不削弱原有 Host Key、第一因子、验证码或转发限制。

首次 `--all-targets` 编译在旧测试 handler 参数报 E0053，修正新接口后 Debug 库 334 通过／2 忽略、夹具 target 2 通过。首次严格 Clippy 因新 russh handle 增大、内部准备结果 Ready 变体达 312 字节而失败；改为 boxed Ready，在消费点移出值，不改对外 FFI／认证状态机／会话所有权，也没有添加 allow。修订后全 targets／all-features 严格 Clippy、格式与差异检查通过。初步 Release 脚本在正常 Debug／Release 和显式旧 ABI 拒绝测试通过后，为应用上述已知修订而主动结束，**不记完整通过**；最终完整脚本另收回执。首次编译／Clippy 失败日志保留。

## 验证状态与后续边界

以下为固定提交时状态，最终本地结果及远端检查状态见后续回执。

- **源码／本地自动化**：上述定向结果已有证据；最终完整 Rust Release 门禁、ABI 符号、真实回环 OpenSSH，以及新核心 Linux 工作区检查仍待本轮完成后追加。
- **Linux 隔离自动化**：在全新目录核对完整源码归档和七个变更文件摘要，复用仅构建缓存；不修改开发检出、原 Flatpak 或现有 QA 配置。新核心的 GTK／桥接／领域／应用工作区检查正在运行，尚不签收。
- **隔离 GUI／真实设备**：本轮升级候选没有新 GUI 或安装结果。Windows `0fdbc05` 的编号终端／窄面板验收属于旧原生核心，不能证明升级后的 SSH／SFTP／MFA。K60 只读检测在线锁屏，未解锁或更新；iPhone／Mac QA 未重装。
- **五端完整验收未完成，不放行发布**：推送固定候选后优先确认依赖扫描消除该漏洞并收 Windows／Linux／Security Gates；Android、Windows、iOS、macOS、Linux 均须重建核心，按真实签名包对照密码／密钥＋码、两跳、错码／取消、Host Key 变化、显式重连、SFTP 读写与取消清理。旧包成功不转记新库成功；原长等待根因、真实文件提供方、Linux 普通窗口／Flatpak、多标签和墓碑矩阵仍开放。

## 固定提交后的本地与依赖门禁回执

**固定源码**：修复及 `245` 已推送为 `dca539bccaa1759d729d3a8c7d4a33bdebb78fa8`，前置 Windows 设备回执为 `9b976e6`。Linux 隔离归档基于此前完整树叠加七个源码／锁文件，逐个 SHA-256 与本固定提交内容相同；没有把其他工作树的 Android 原生二进制改动加入本次提交。

**本地最终自动化**：完整 `check_rust_release_gates.sh` 退出 0。Debug 与 Release 各为库 **334 通过／0 失败／2 忽略**、夹具 target **2 通过／0 失败**；显式 Release 旧 C ABI 拒绝、内部 legacy policy、内部不同 handler 的三项定向检查均通过，严格 Clippy／all-features、Debug／Release 构建、格式及差异通过。`check_symbols.sh` 的 C11 canonical／forwarding headers 和 checked／legacy ABI 符号通过，静态安全扫描通过；桌面契约及既有 12 域稳定性基线校验通过，基线仍明确保留 2 项 P0，不把脚本通过当发布阻断归零。

**真实回环协议**：opt-in OpenSSH 脚本退出 0，可信公钥 SSH／SFTP及目标所有权、主机密钥变更、撤销、Release 旧接口无 socket 四场景分别实际运行通过；每场景 1 项，不与库测试累计成新的覆盖总数。两项在常规套件仍按 ignored 记录，显式场景通过单独列出。一次性 sshd 已退出、无相关残留进程；没有连接真实 TOTP 主机或读取验证码。

**Linux 隔离工作区**：完整 `check_linux.sh` 退出 0：格式／严格 Clippy、领域／桥接／平台／同步／应用等工作区测试合计 **170 通过／0 失败／5 忽略**，desktop-file／AppStream 验证成功。保留系统 FreeRDP C 头文件弃用警告，不称零警告构建。没有启动新 GUI、安装新包或修改原 Flatpak；原客户端进程复核仍在运行。该自动化不能代替正常窗口／Flatpak 或真实提供方 GUI。

**固定远端结果**：[新 Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/41277724326) 中 [依赖漏洞与许可扫描](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/41277724326/job/124763190813) 已 **success**，桌面契约 success；其余常规作业记录时尚运行、两条件任务 skipped。同提交 [Windows](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/41277724258)／[Linux](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/41277724277) CI 仍运行，**不提前记整门禁成功**。旧 `0fdbc05` Security failure 保留；没有加漏洞 ignore、改变扫描级别／exit-code或移除失败测试。新核心的五端 GUI／真实设备及完整矩阵仍待验，不发布。

**进度保存**：本回执先本地提交，待固定远端门禁结束后再同步到同一分支，避免纯文档推送取消仍运行的 Apple／Android 作业。下一步收齐固定 CI，核对签名／产物后先复测 Windows／Linux 的新核心连接、MFA／Host Key 与 SFTP；随后按总台账安排 Android／Apple 对照及 Linux 可读错误／普通窗口问题，不能借当前旧包结果签收新版。

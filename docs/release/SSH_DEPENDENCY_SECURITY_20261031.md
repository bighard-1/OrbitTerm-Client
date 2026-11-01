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

## 固定候选完整门禁与设备续验（2026-11-01）

**完整 CI**：固定 `dca539b` 的 [Windows](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/41277724258)、[Linux](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/41277724277)、[Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/41277724326) 最终均 completed／success。Windows 原生测试 **373 通过／0 失败／0 跳过**；六常规安全作业实际成功，两发布条件 skipped。打包保留 PRI263 的 RDP-host 资源及无 mspdbcmf 符号包警告，不称全过程零警告；旧 `0fdbc05` 漏洞扫描 failure 保留。

**Windows 产物与安装**：artifact `13072660430` 对应合并预览 `256bbe32dc07a96a17e6a30bf36310cea0a90890`，父含候选且完整树均为 `94fc02aae1b072654a94fad54a057273d116b9c7`。ZIP 为 142,717,501 字节、SHA-256 `3132dbfd1cc141fb48df7290e6b3a4350bb15e6be2fea333097106c1ca765e76`；MSIX 为 144,659,514 字节、SHA-256 `692fdee585bdb7216244ba74ff08ef2874b58d00b5e02b8433a60035a19d3520`，官方／Mac／SMB 完整回读／Windows 本机匹配，包内摘要一致。CER SHA-256 `dda903b3c24c1dac95c3e34ea6b80496d5dd8276d9c9c3e86e6f3232ee603050`、签名者匹配；信任前 UnknownError 不记 Valid，轮换项目测试叶证书后 Valid，同身份同版本 0.3.0.33／x64／Ok。正常退出后静止加密备份 **27 文件／320,252 字节／0 错误**，25 账户文件安装前后相同；三个 payload、运行 EXE 匹配，系统屏幕键盘独立解锁后原 **5 分组／7 资产**保持，才精确移除旧叶证书并复验 Valid。实际仍是 OrbitTerm.Client 身份，不宣称正式版可独立并装。

**Linux 隔离 GUI**：Release ELF SHA-256 `8ca396052b17b5bf328605583c0a6386b73648b14370aada680cde53122bd829`，新目录／私有 XDG／DBus／Keyring，只有既有一条虚构仅本机资产，原 Flatpak 未动。密码 SSH 后终端 checked／Host Key verified，SFTP 列项；**27 字节下载**摘要 `d7e0317c9429a76779b262f78fc5d747bf5ea47a8f62e1b1d0bb4e0243234724` 与源相同，**256 KiB 上传**摘要 `2312394bd99545d9de131c24efb781e765ac1aec243f2ed9347597a793a415e9` 与源相同，任务完成、无上传临时文件，原 27 字节文件保持。

私有 OTP 服务器副本只适配既有虚构密码／回环端口，沿用受信测试 Host Key，未改产品 ELF 或资产配置。显式重连出现空白二次验证；静态错码后显示认证失败且无终端，重新连接为全新空框，正确静态测试码后在线并显示 inert OTP 横幅。补验取消：空框直接取消，页面明确“已取消 SSH 二次验证”，失败标签、输入禁用。**这是静态回环代码夹具，不是真实 TOTP／密钥＋码／两跳或五端验收。** OTP 夹具无 SFTP，界面有读取失败但旧目录仍可见，列为后续陈旧列表展示检查，不把旧项当新 SFTP 成功。

**Windows GUI 范围**：新版普通密码虚构连接已在线、编号终端与唯一 32 字节 SFTP 文件可见；下载停在选择目录，尚无本候选目标摘要，不记完成。等待续接期间限时夹具／Linux 隔离桌面正常到期退出；恢复先核对进程、监听和网络端口。Windows App 初次提示 0x104，但测试机 RDP／SMB／RPC 端口均可达；后续远控窗口读取／定位异常，不将该辅助故障判为产品失败或盲点选择器。Windows 本候选完整下载／MFA 仍待补。

**首次准备失败保留**：备份 helper 嵌套拼接误成绝对路径，被 Mac 只读文件系统拒绝，首次副本标 incomplete、未据此安装；改为受控相对路径断言后完整备份。Linux 首次启动早于 ELF 复制完成而失败、所选 Python 缺 asyncssh，保留日志并停止私有会话，核对 ELF／依赖后再启。一次远控 Ctrl+A 未到文件名框导致追加路径，观察后完整替换并核对才保存。普通窗口远控不稳、最大化后完成；没有把旧帧或点击尝试直接记为结果。

**验收边界**：K60 仅查 USB 在线且锁屏，Apple QA 未更新。Linux 原 Flatpak 仍在，新核心 GUI 不能替代正常 Flatpak、真实提供方或五端矩阵。下一步完成 Windows 下载／MFA，再处理 Linux 可读错误／陈旧目录／普通窗口，多标签、真实 TOTP 与完整墓碑仍开放；不放行发布。服务及进程的最终清理状态另追加回执。

**续接与精确收尾**：Linux 补验验证码取消后正常退出 QA，监督器关闭私有 Xvfb／Openbox／D-Bus／VNC；各记录 PID 均已退出、私有两个监听关闭、原 Flatpak 为唯一存活客户端，原校验文件不变、上传临时文件零。私有 MFA 服务和 Mac SSH 隧道均精确结束，静态夹具及文件证据保留在加密开发盘。Windows 两轮限时只读服务亦均结束、监听关闭；第二轮因控制通道未恢复，没有提交下载目标或完成新传输。

Windows App 在现有 RDP 窗口与连接中心间定位异常，重读／按程序路径重绑／重置控制会话后仍连续超时；测试机 RDP、SMB、RPC 端口可达。没有关闭 RustDesk、重启测试机或绕过保护；已请求用户仅重开 Windows App 并保持远程桌面可见再续测。该项是明确的验收通道阻碍，**Windows 新版下载／MFA 仍未完成**；不得把 Linux 或 CI 的成功填到这些空项。纯文档回执将在既有固定门禁结束后同步，不再取消该次已完成门禁。


## Windows 完整下载与断开释放缺陷（2026-11-01）

**固定旧候选与真实设备结果**：仍用 `dca539b` 的已核验 Windows 原生包，经 Windows App 恢复控制，未退出 RustDesk、未重启系统。只连接既有虚构本机资产；普通密码连接、SFTP 列项、专用新目录下载 32 字节完成，目标 SHA-256 `dfbf48a61b083ffcc877af18c34000a727d446adb74ceeeb9d37740af4619be0` 与夹具一致。此结果补齐 `248` 的下载空项。

同一测试 Host Key、合成凭据及限时来源受限中继换到静态 OTP 夹具：错码显示“SSH 认证失败，请检查凭据或验证码后重试”，终端未连接；显式重试为空框，正确静态码后在线、显示只读横幅。该夹具故意不提供 SFTP／Docker；Windows 本轮清空了旧目录，未把旧项当新连接结果。连接诊断显示认证及终端打开约百毫秒，随后 SFTP 与 Docker 顺序各等待约 30 秒，总计约 59 秒；**附属初始化延迟仍开放**，不把测试夹具行为直接推定为真实服务器故障。

**真实失败保留**：在唯一活动测试会话点击“断开连接”后，界面未连接，但再点重新连接直接复用原已认证 SSH 通道、没有新验证码挑战。源码确认 `EndVerifiedSessionAsync` 仅移除托管登记，Windows 未调用既有原生 SSH／SFTP 释放 API。不是未认证攻击者绕过 MFA，而是显式断开未履行连接资源生命周期；本轮不能记为完整通过。停止夹具后又观察到空白挑战，取消后未连接，但页面给通用网络原因，不能借此补写“显式断开后重新索码／取消文案”通过。

**源码修复候选**：本条提交为 `dca539b` 的后继。NativeBridge 接入既有释放 API，沿用统一返回解码；Orchestrator 记录成功打开的 SFTP 子会话，按工作区／资产／base 精确释放子引用再释放 base，成功后才删除托管登记。每个已验证租约串行协调 SFTP 打开与结束，重复结束不重复释放；阻塞原生释放放在后台。释放失败保留所有权并返回失败，界面明确“断开连接未完成，请重试”，禁止继续重连或移除标签；不会输出原生错误细节。其他工作区合法共享的引用保留，因此“新挑战”验收须明确唯一活动所有者。

共享 Rust 核心修正 SFTP 先移除本地子会话后、远端 close 出错便漏减 base 引用的路径：本地撤销后远端 close 为尽力通知，限时 3 秒，随后始终释放持有的 base 引用；重复 SFTP close 幂等。最后 base 引用移除池与索引后，SSH close（含锁等待）亦限时 3 秒，避免已撤销资源被远端无限阻滞。关闭超时不代表已证明对端收到断开包；池内不可复用与远端通知是不同证据。该核心修改后 Apple／Android／Linux 需要相应新包对照。

**自动化与证据边界**：先加两项断言，旧 Orchestrator 均实际失败（无任何 SFTP／SSH 释放调用），原 TRX 保留；修复后定向 Windows 应用／编排／连接结果测试 165 通过。覆盖子先父后、同 base 的另一工作区不误释放、重复／并发结束、释放失败保留并可重试、失败不重连／不丢标签。此为 Mac 上假原生客户端的 .NET 应用层自动化，Windows 原生 crypto／实际 DLL 和完整 GUI 不由此证明。Rust Debug／Release 各 336 通过／2 忽略、严格 Clippy／Windows 静态检查通过；扩展 OpenSSH 可信流程／主机密钥变更／撤销／Release 旧网络接口无连接四场景均通过，临时 sshd 已退出。新远端 CI／签名包／真机复测未完成。后续 OpenSSH 断言包括关闭 SFTP 后子登记消失、重复关闭不误减 base、最后断开后新连接获得新 base。

**收尾与下一步**：本轮只读服务／OTP 中继均已停止、两个私有监听关闭；虚构结果与原始失败证据仅存加密开发盘，仓库只留脱敏记录，测试账户原资产未修改。K60 仅只读连接／锁屏检查，Apple 未操作。先核对新候选 CI／Windows 包来源、备份并更新，再用唯一测试会话验证“正确码在线→显式断开→重新索码→取消未连接”，随后排查附属初始化延迟与 Linux 陈旧目录；五端完整墓碑／真实 TOTP、密钥＋码、双跳与发行验收仍未完成。

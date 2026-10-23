# Windows 终端关闭、SFTP 断线反馈与窗口边框专项（2026-10-22）

## 基线证据（保留失败）

固定 `bf25a0d` 的 Windows 10 实体 QA 经 Mac RDP 操作，专项见 [SFTP 断线日志](SFTP_DOWNLOAD_TARGET_OWNERSHIP_20261021.md#windows-正常-shell-退出多终端及在途硬断线续验2026-10-22)：远端正常关闭 shell 后仍显示终端可输入，直到发送空输入才离线；下载约 2.8 MiB 时服务硬断线后连接可离线、专用目录无残留，但重连后旧任务仍显示在“进行中”，页顶仍为“正在批量下载”，静止速率与不可用的重试入口造成误导。两个存活终端共享一条基连接、移除分屏后首终端和 SFTP 可用，作为有限通过保留，不能覆盖上述失败。

另在同一 Windows 10 QA 的窗口化画面只读观察：自绘顶部与系统原生左、右、下三侧较宽的浅色缩放边框明显不一致。既有 `NativeWindowCornerService` 为保留 Windows 10 LTSC 的可靠横向/角落缩放，使用 `WS_THICKFRAME` 并在 Win10 不装自定义非客户区子类；这解释了外露色带，但并不能据此假定去掉样式仍可缩放。当前旧版窗口外观不合格，拖拽缩放能力未在本轮重新测量。

## 源码修订候选（待门禁与真机）

- Windows 原生桥注册 Rust 核心已有的 `orbit_connection_set_callback`，只接受 `ERR_CONNECTION_LOST` 和 `ERR_TERMINAL_CLOSED` 两种事件。应用层按基会话 ID / 终端通道 ID 路由，并从核心回调线程派发到 UI；未知或过期 ID 不修改当前窗口。基连接关闭撤销在线状态；单终端关闭仅移除该终端，SSH/SFTP 基连接仍可用。若主终端结束但有存活分屏，将首个存活分屏提升为主终端，避免其被隐藏。
- SFTP 断线复原分支取消仍在运行的任务时，清除旧传输速率并替换“正在下载”反馈为中断警告；没有可靠重试快照时明确要求重新选择文件，不虚称重试按钮可用。“进行中”标签改为“未完成”，与其包含运行、失败、取消任务的实际集合一致。此修订不声称底层原生传输一定已及时返回，仍需卡读/硬断线真机验证。
- Windows 10 仍保留 `WS_THICKFRAME` 和原生 `SC_SIZE` 缩放循环，安装非客户区子类，让窗口化客户区绘制覆盖左、右、下系统色带，同时显式保留边缘/角落命中测试；最大化时沿用系统非客户区计算。深浅主题切换均触发帧重算。Windows 11 原生圆角路径不改。**视觉一致和八方向实际可缩放尚未真机确认**，不能仅凭源码推断达标。

## 自动化与验收分级

新增 fake-core 单测覆盖未知终端/基会话 ID 忽略、被动终端关闭时 SFTP 保持及重开终端、主终端结束后分屏提升、被动基连接丢失立即撤销在线，以及断线后不再保留传输“进行中”反馈/速率。当前 Mac 无 .NET SDK，XAML XML 解析与 `git diff --check` 成功，**Windows 编译、单测和 CI 尚待远端运行**。本节没有安装新版 MSIX；上一节 Windows 10 的失败/通过仍属于旧候选，不能改写为新版真机结果。

2026-10-23 首轮远端门禁保留：源码提交 `e8f4802` 的 [Windows Client CI](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/39910244413) 在原生 Rust 和 Windows 产品层编译成功后，于测试项目两处 `ReadOnlyMemory<byte>` 的集合表达式触发 `CS9174`，因此测试与 MSIX 签名包**未生成**。已将两处调用改为显式 `byte[]`，后继提交及门禁结果待记录。同一提交的 [Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/39910244418) 中 Rust、Apple、Android Release、桌面契约和依赖检查成功，但 Android 15 模拟器启动历时约 6 分钟后，安装隔离夹具时 Android 系统 `PackageManagerInternal` 尚为空而报 `NullPointerException`；仪器测试**未执行**。这是模拟器安装服务故障的日志表象，不推定产品代码通过，也不以重跑结果覆盖此失败。

第二轮源码 `d96f12d` 的 [Windows Client CI](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/39939552482) 修复了 `CS9174`，Windows 产品层与测试层均编译成功，337 项测试中 336 通过、1 项原有批量下载取消测试在等待“恰好开始第一个下载”的 250 ms 时间窗时超时；MSIX 仍未生成。将该测试改用 fake-core 的下载入口和放行门闩，取消动作明确发生在第一个下载仍在途时，不变更生产取消行为。`d96f12d` 的 [Linux CI](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/39939552467) 成功；其 Security Gates 在本行记录时仍运行，不能记整体通过。后继提交/复测待填，Windows 真机仍是旧包。

第三轮固定 `870f97f` 的 [Windows Client CI](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/39940434590) 为 `completed/success`：安全测试 337/337（失败 0、跳过 0）、WinUI x64 Release 构建与内部测试签名 MSIX 上传成功；[Linux CI](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/39940434732) 亦成功。旧两轮编译/超时失败保持可追溯。GitHub artifact `12496235663` 属于该提交；加密外置盘接收的外层 ZIP SHA-256 `efb21ea83c4ec43850b5421b151ff528c80426f77b58ca21d577cdaf4c7270d7` 与 GitHub digest 相符，ZIP 和内层 MSIX 完整性检查成功；MSIX SHA-256 `3fd0ce3740b629b1597ddec6a644bc7a281c1d95ea4ef50af8a142d40668dcb5` 与包内 `SHA256.txt` 相符，清单为 `OrbitTerm.Client`/`0.3.0.33`/x64。随包测试证书的 SHA-1 指纹为 `76D8D3A2232C9EF5891E528789B7D143ECD01931`。Windows 10 测试机上仅传入 MSIX、证书和原名安装脚本，Mac 经共享回读及 Windows 本机 `Get-FileHash` 均与原件一致；导入前 Windows 签名者指纹与随包证书一致但状态为 `UnknownError`，**未写作 Valid**。远控第一次哈希命令的路径分隔符被输入通道丢失，命令未匹配文件；改为逐层切换到专用目录后取得 Windows 本机有效摘要，前次输入异常不计成功。旧 QA 正常关闭后，包外账户状态、包内 Settings 和 LocalState 已备份到加密外置盘且逐目录比较一致；不含系统 Helium，不能保证全量跨机可恢复。传输 SMB 挂载已卸载。新证书尚未导入、MSIX 尚未安装；本次安全敏感操作正在等待用户当次确认。`870f97f` 的 Security Gates 本行记录时仍运行，不能记为整体通过。

下一阶段：在 Windows CI 完整通过后取固定提交的内部测试 MSIX，核对归档、包签名和新证书；如需在测试机导入新的测试证书，须在实际更新动作前另行确认。更新独立 QA 后复测 shell 自然退出、SFTP 保持、多分屏、在途硬断线/任务状态，并在窗口化与最大化、浅色与深色下检查四边视觉和八方向缩放、标题栏按钮、拖动及贴靠。Android/K60 对照已有被动断开和硬断线记录；iOS/macOS/Linux 新候选 GUI 与五端完整验收仍开放。

## Windows 10 真机更新与边框失败保留（2026-10-23）

用户在实际导入时确认新测试证书、独立 QA 更新及旧证书清理。固定源码 `870f97f`，MSIX `0.3.0.33` 的 Mac、Windows 本机和包内 SHA-256 一致，更新前包外账户、包内 Settings/LocalState 已备份至加密外置盘且逐目录一致（不含系统 Helium）。在 Windows 10 专业版测试机导入随包新证书后，安装脚本记录 `SUCCESS`，`Get-AppxPackage OrbitTerm.Client` 显示 x64、`0.3.0.33`、`Status=Ok`，系统 MSIX 签名从导入前 `UnknownError` 变为 `Valid`。按精确 SHA-1 指纹仅移除旧 OrbitTerm 测试证书后，`TrustedPeople` 只剩新证书，再验 MSIX 仍为 `Valid`。用户亲自解锁 QA；窗口显示原有 6 项资产，状态栏为云端已同步、本机队列已处理。此处没有声称凭据跨机恢复或完整同步/墓碑矩阵通过。

固定 `870f97f` 的 [Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/39940434765) 随后最终为 `completed/success`：Rust Release、Apple checked-path、Android instrumentation/migration、Android Release、桌面视觉契约、依赖/许可检查成功；条件式 OpenSSH RC 与 macOS 签名 UI 冒烟为 skipped，不记通过。此结果与 Windows CI 337/337 成功同属旧候选，不覆盖下述真机缩放失败，也不包含后继 `1886bdd` 修订。

**窗口专项实际结果**：新包窗口化左、右、下的旧版宽浅色色带未再明显外露；标题栏可拖动，最大化/还原及按钮可用，最大化布局未见截断。但通过 Mac 的 Windows App RDP 输入对左、右、下边框和右下角多次拖动，均未观察到窗口尺寸改变；顶部边缘拖动移动了整个窗口，而非改变高度。由于远控输入链路也可能影响边缘拖拽，归类为**缩放未通过/未排除产品缺陷**，不能把视觉改善写成“保留八方向缩放”。旧版色带失败与本次缩放疑点均保留。

源码复查显示窗口化 `WM_NCHITTEST` 把鼠标坐标与 `GetWindowRect` 比较；Windows 10 的该矩形可能含不可见 DWM 缩放边距，绘制边缘上的命中区因而偏移。后续候选改用 `DWMWA_EXTENDED_FRAME_BOUNDS` 的可见矩形，失败时回退 `GetWindowRect`；这是**待编译/待真机复测的原因假设和源码修订**，不能在本行记为修复完成。仍须在新签名包上逐一确认四边/四角扩大与缩小、最小尺寸限制、标题栏/贴靠、最大化/还原、深浅主题，才能关闭窗口项。终端自然 EOF、SFTP 在途硬断线/队列终态尚未在此新包重跑；Android/K60 对照仍以既有结果为限。

## 可见边界命中修订候选的安装前核验（2026-10-23）

后继固定提交 `5d02429`（含源码修订 `1886bdd`）的 [Windows Client CI](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/39945854581) 已 `completed/success` 并产出独立测试包；[Linux CI](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/39945855049) 同提交 `completed/success`。[Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/39945855106) 在本行记录时仍运行，**不记整体通过**。前一候选的真机边缘拖拽失败不会被此次 CI 覆盖。

GitHub artifact `12497913632` 的外层 ZIP SHA-256 `b5d535f38704ae2e20576a56c5ac3b23e7183d4a0d24ae073d9c9c46cf0bdfb2` 与平台摘要一致；归档测试通过。内层 MSIX SHA-256 `f814af8e57e3b30dee677d5fb4bf4e93ba197df625f3dde7e793e29dce0b9494` 与包内 `SHA256.txt`、Windows 本机 `Get-FileHash` 一致；清单仍为 `OrbitTerm.Client`、x64、`0.3.0.33`。随包新测试证书 SHA-256 `66472ba064920f535102bee2c361510add90fc452ef6ac2962ac18742abde30e` 与 Windows 本机一致；签名者 SHA-1 为 `742D34E37337981D2F6DE93F1B7FFF1B369017AF`。在**未导入新证书前** Windows 的签名状态为 `UnknownError`，符合尚未建立本机信任的当前状态，不能写作 `Valid`；当前 `TrustedPeople` 只含上一版 OrbitTerm 测试证书。Windows 远控输入曾把含盘符/斜杠的 `cd` 路径损坏，报不存在；改用逐层进入专用目录后取到正确本机摘要，失败命令保留、不计核验通过。

旧独立 QA 已正常退出；包外账户目录、包内 Settings/LocalState 均复制到加密外置盘，逐目录比较无差异。此备份不包含 Windows 系统 Helium，不能声称全量可恢复。新包和证书已传至 Windows 测试机，尚未导入证书或安装。由于新签名证书与前一轮不同，已在实际操作点另行请求确认。**隔离 GUI/真实设备新候选尚无结果，五端完整验收未完成**。获得确认后，先验证签名及包状态，再核对原资产、八方向边框缩放及终端自然 EOF/SFTP 硬断线；Android/K60 应对照被动断开和任务终态。

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

## 可见边界候选的 Windows 10 实机缩放复测与新修订（2026-10-23）

用户在实际操作点确认了新测试证书导入、独立 QA 更新及旧证书精确清理。固定 `5d02429` 的 `0.3.0.33` 包安装脚本记录完成，Windows `Get-AppxPackage` 报 x64、`Status=Ok`，MSIX 的签名者为随包新证书且状态从导入前 `UnknownError` 变成 `Valid`。用户亲自解锁 QA；原有 6 项资产仍在 4 个分组，状态显示云端已同步、本机队列已处理。只按上一张测试证书完整 SHA-1 指纹从 `TrustedPeople` 移除旧证书，复查仅剩本次证书且 MSIX 仍为 `Valid`；不涉及正式版、其他证书或线上服务。一次远程输入焦点被新启动的 QA 主密码弹窗抢走，错误地触发了主密码失败提示，随即停止在该框输入；此失败保留，不计账户/凭据错误，后续由用户本人解锁。

**鼠标缩放仍未通过**：Mac Windows App 的 RDP 实操在 QA 左、右、下边及右下角均未观察到尺寸变化，扩大到最外侧像素后右边仍无变化。只读 Win32 探针确认该 QA 进程 `WS_THICKFRAME` 为真，`GetWindowRect` 与 `DWMWA_EXTENDED_FRAME_BOUNDS` 在此设备上都是同一矩形；四边/四角的 `WM_NCHITTEST` 分别返回预期的 `HTLEFT`/`HTRIGHT`/`HTTOP`/`HTBOTTOM` 和四个角值，中心为 `HTCLIENT`。探针首版 PowerShell 数组表达式错误导致执行中止，修正后才得到这些值，首轮失败未计为通过。通过系统菜单“大小”及方向键，QA 宽度真实增加约 33 像素；同一 RDP 通道拖动普通 PowerShell 窗口的精确右外缘也能真实增加宽度。因此既不能说远控完全不支持拖拽，也不能说 QA 鼠标缩放通过。可见边界矩形偏移的上一轮原因假设在这台设备上未成立。

源码复核指向 Windows 10 的 `WM_NCLBUTTONDOWN` 分支：它截获已命中的缩放边缘，释放捕获后自行发送 `SC_SIZE + 方向` 且 `lParam=0`；这可能启动系统大小模式但丢失原始鼠标按下位置/拖动语义。新源码候选改为把原始 `WM_NCLBUTTONDOWN`、命中值和屏幕坐标交给 `DefWindowProcW`，仍保留 `WS_THICKFRAME` 与仅在必要时恢复样式的保护。此修订**尚未编译、未生成新签名包、未在 GUI/真机验证**，不能关闭缺陷。下一轮须在新包上重跑鼠标四边四角拖拽、系统菜单大小、最大化/还原、深浅主题和最小尺寸，再补终端自然 EOF 与 SFTP 在途断线；Android/K60 对照被动断开与队列终态。

门禁按提交分开记录：`5d02429` 的 [Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/39945855106) 因后继提交触发而 `cancelled`，不能写成功；不改产品代码的记录提交 `8660fc8` 的 [Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/39948562148)、[Windows CI](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/39948562128)、[Linux CI](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/39948562130) 均 `completed/success`，但这些自动化不抵消上述鼠标真机失败。新修订需独立跑门禁及更新 QA。

首个原生鼠标修订提交 `587e7a3` 的 [Windows CI](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/39980761742) **失败**，未产出可安装 MSIX：337 项安全测试中 336 通过、1 项 `SftpBatchKeepsItsOriginalLeaseWhenVisibleWorkspaceChanges` 在 `WaitUntilAsync` 超时。该测试仍用 `Thread.Sleep(250)` 制造“恰好只有第一次下载已进入”的窗口，CI 机器调度下可能已经进入第二次下载，`DownloadSftpFileCallCount == 1` 不再成立。失败属于测试同步机制，不能写作产品新修订已编译/通过；原生 Rust 构建完成，但 WinUI Release 和签名包步骤未走到。后继测试修订改用 fake-core 下载进入/放行门闩，明确在第一次下载尚未返回时切换可见工作区；生产下载逻辑不变。需以新提交重跑 Windows CI，保留这次失败，不以重跑覆盖。`587e7a3` 的 Linux 与 Security Gates 若后续被取消或失败，须按最终状态另记。

## 原生按下候选的实机失败、子窗口归因与下一修订（2026-10-23）

`587e7a3` 的 [Linux CI](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/39980761773) 最终成功，[Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/39980761771) 最终取消，不能补记为通过。后继固定提交 `c35d196` 的 [Windows CI](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/39981925900)、[Linux CI](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/39981926012) 与 [Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/39981925852) 均 `completed/success`；它修正前述定时测试，**自动化成功不覆盖以下真机失败**。Windows artifact `12513069439` 的 ZIP SHA-256 `ec155b3002163316a79906a4212e59a58bf137f16609ab2ffbe1b7a2c3d29c0e` 与 GitHub digest 相符，归档自检无错误；包内 MSIX SHA-256 `4c6bc0d2b6df753fb29dbda942749881137cbbd95348c92b1732d7c298b04a47` 与 `SHA256.txt`、Mac 及 Windows 本机摘要一致。随包证书 SHA-256 `91c419782c4a9875bb6bc3594c4e2bfe6cab287c463d51e07be9ff58a86c9632`，SHA-1 指纹 `3D91FC0E97DBDB68B6F182668C2E2BDC08D6864E`；清单为独立 `OrbitTerm.Client`、x64、`0.3.0.33`。

用户在实际操作点确认新测试证书导入、独立 QA 更新和旧证书清理。旧 QA 正常退出后，包外账户状态、包内 Settings/LocalState 复制到加密外置盘并逐目录比较一致；不含系统 Helium，不能声称全量恢复能力。Windows 安装脚本记录 `SUCCESS`，系统注册为 x64、`Status=Ok`；新 MSIX 签名为 `Valid`。用户本人解锁后，原 4 个分组/6 条资产可见，状态显示云端已同步、本机队列已处理。只按完整 SHA-1 指纹移除上一张 OrbitTerm 测试证书 `742D34E37337981D2F6DE93F1B7FFF1B369017AF`，新证书仍在 `TrustedPeople`，再验 MSIX 仍为 `Valid`；正式版及其他设备未动。远控一条首次文件哈希命令因下划线被输入通道吞掉而找不到文件，改用目录内 `*.msix` 重新核对成功；首轮错误不计哈希通过。

**本候选窗口鼠标缩放仍未通过**：QA 标题栏拖动能移动窗口，但对左、右边及右下角拖动均没有尺寸变化；同一 RDP 通道把普通 PowerShell 窗口的精确右外缘拖宽成功。QA Win32 只读探针显示 `WS_THICKFRAME` 存在，主窗口 `WM_NCHITTEST` 在四边/四角分别返回正确原生命中值；然而 `WindowFromPoint` 在右边缘、下边缘和内部均命中同进程同 UI 线程的 `Microsoft.UI.Content.DesktopChildSiteBridge` 子窗口，顶部边缘命中 `InputNonClientPointerSource`，而非已装缩放子类的顶层 HWND。因而只把顶层 `WM_NCLBUTTONDOWN` 交给 `DefWindowProcW` 的 `587e7a3` 修订未触及真实鼠标目标；这是本设备上的**具体归因**，不是五端通用证明。目标窗口探针前几次分别因 PowerShell 数组算术、保留变量 `$PID`、未限定 `StringBuilder` 类型而中止，修正后才取得窗口归属；这些诊断失败保留，不视为产品错误。

下一**源码候选，尚未构建或安装**：在 Windows 10 同 UI 线程的上述 WinUI 子 HWND 上安装专用命中子类，边缘返回 `HTTRANSPARENT`，让命中继续到保有 `WS_THICKFRAME` 的父窗口；内部点击、标题栏按钮和 Windows 11 路径不变。依据 [Microsoft 的 `HTTRANSPARENT` 定义](https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-nchittest)，同线程下会继续查找下层窗口。此逻辑须经 Windows CI、签名 QA 包与 Windows 10 真机的四边四角缩放、最小尺寸、最大化/还原、标题栏按钮、贴靠、深浅主题复测，不能仅凭代码或主窗口命中值关闭缺陷。终端自然 EOF、SFTP 在途硬断线新候选 GUI 与 Android/K60 对照、Apple/Linux 同候选 GUI、五端完整墓碑矩阵均未由本轮覆盖。

## 子窗口命中候选的构建与安装前核验（2026-10-23）

上述源码候选固定为 `75f7830`。其 [Windows CI](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/40046987965) 与 [Linux CI](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/40046987880) 均 `completed/success`；[Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/40046987909) 在记录时仍运行，**不可提前记为通过**。Windows artifact `12541329800` 的 ZIP SHA-256 `4b2be8638f7e0380f00677f5d88fa36e6a98c198bf6aa7694143d9943f4db11b` 与 GitHub digest 相符，归档自检无错误。包内 MSIX SHA-256 `d03c0f0fc6e9ba85e79b6d6f3d7d6a3f08e033171728ee56a86a099fee759490` 与 `SHA256.txt`、Mac 及 Windows 本机摘要一致；随包证书 SHA-256 `7a3b64f8cbd06b6b0f33665becd4d65b50fdc8d8e96b94b06f6fc22abe2397de` 亦与两机一致，完整 SHA-1 指纹为 `BD23887F1F9AB03193B8FAAFE856429F7A7C041F`。MSIX 清单仍为独立 `OrbitTerm.Client`、x64、`0.3.0.33`。旧 QA 已正常退出，账户状态、包内 Settings/LocalState 已复制到加密外置盘并逐目录比较一致；同前，不含系统 Helium，不能声称全量恢复能力。新包已复制到 Windows 测试机，**尚未导入新证书、尚未更新 QA，也没有新候选真机缩放结果**。本轮操作前需要用户在实际操作点同意新证书信任范围与 QA 更新。`c35d196` 的真实鼠标缩放失败依然有效。

## 子窗口透明命中的 Windows 10 真机失败与后继候选（2026-10-23）

用户在实际操作点同意导入本次新测试证书、覆盖更新独立 QA，并在核对后移除旧测试证书。安装脚本记录 `SUCCESS`，Windows 包注册为 x64、`Status=Ok`；MSIX 签名者完整 SHA-1 指纹为 `BD23887F1F9AB03193B8FAAFE856429F7A7C041F` 且状态 `Valid`。用户亲自解锁后，误入搜索框的诊断命令片段被清空，原 4 个分组/6 条资产可见，状态显示云端已同步、本机队列已处理。只按完整指纹 `3D91FC0E97DBDB68B6F182668C2E2BDC08D6864E` 清理上一张 OrbitTerm 测试证书；前后检查由旧/新 `True/True` 变成 `False/True`，本次包签名仍 `Valid`。一次远程 PowerShell 命令中的管道字符被输入通道吞掉，导致 `Get-AppxPackage` 参数错误；随后不带管道的命令返回正确注册状态，前次错误不计系统包失败。另一次直接在远控命令行输入证书路径时正斜杠被证书提供程序判为不存在，改用保存在测试机上的精确 PowerShell 脚本检查与清理成功；不把路径输入失败算成证书缺失。

**真机鼠标缩放仍未通过**：QA 右边、左边、右下角拖动均无尺寸变化；上沿拖动只移动整窗，不能算缩放。只读探针见主 HWND 四边命中为原生缩放值，前台 WinUI 子 HWND 在左、右、上、下边缘均返回 `HTTRANSPARENT (-1)`，内部返回 `HTCLIENT (1)`，说明新子类确已安装并运行，但透明命中没有把真实鼠标按下稳定交给主窗口的原生缩放路径。首版探针在 PowerShell 遮挡 QA 时，右缘取到了诊断窗口而非 QA；将 QA 置于前台后重测得到上述有效结果。此诊断失误保留，不能把首版混合窗口命中用作产品结论。`75f7830` 的 Windows/Linux CI 与包签名成功均不覆盖这一真实设备失败。

后继**源码候选，尚未构建或验证**：子 HWND 的 `WM_NCHITTEST` 在边缘直接返回对应原生命中码，并在子 HWND 收到原始 `WM_NCLBUTTONDOWN` 时把命中码与屏幕坐标交给顶层 `DefWindowProcW` 的尺寸拖拽循环；内部、最大化和 Windows 11 路径保持不变。依据 [微软的非客户区鼠标按下说明](https://learn.microsoft.com/en-us/windows/desktop/inputdev/wm-nclbuttondown)，`DefWindowProc` 会对该按下执行相应动作。此为从本机证据推导的修订，**不是已证实的修复**；下一固定提交仍需 Windows CI/签名及 Windows 10 实际鼠标四边四角、按钮、最小尺寸、最大化/还原、主题/贴靠复测。终端自然 EOF、SFTP 在途硬断线以及 Android/K60、Apple/Linux 同候选 GUI 和五端墓碑矩阵依然开放。

## 子窗口原生按下候选的构建与 Windows 10 更新（2026-10-23）

上述候选固定为 `ab00edb`。其 [Windows CI](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/40049205700) 和 [Linux CI](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/40049205723) 已 `completed/success`；[Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/40049205735) 记录时仍运行，不提前算通过。前一提交 `75f7830` 的 [Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/40046987909) 最终为 `cancelled`，不能把其部分步骤通过替代整个门禁。Windows artifact `12542917286` 的 ZIP SHA-256 `59a89f79f46d892ca9058fdefba9546f17ce8569e92fbba0334f669d76ed8ede` 与 GitHub digest 一致且归档自检无错误；包内 MSIX SHA-256 `1df5c8be61e9062ce3f019cf2453ebb30383809a352d1801ec6a973cf8cddc1c` 与 `SHA256.txt`、Mac 与 Windows 本机摘要一致。随包证书 SHA-256 `3d0ac3423e2d49a7720ce6e5aa83b3c9b17b5e214020eef8b0e322f58c36ee75` 在两机一致，SHA-1 指纹 `9BFFB74E65A6CF085304C1195977467BCD0ED0DC`；MSIX 清单仍为独立 `OrbitTerm.Client`、x64、`0.3.0.33`。旧 QA 正常退出，包外账户状态及包内 Settings/LocalState 已复制到加密外置盘并逐目录比对一致；不含系统 Helium，不能声称全量恢复能力。用户在实际操作点允许本次新证书导入、独立 QA 更新与旧证书清理；安装脚本已记录 `SUCCESS`。Windows 10 本机进一步只读核对 `Get-AppxPackage`：独立 QA `0.3.0.33`、x64、`Status=Ok`；`Get-AuthenticodeSignature` 对本次 MSIX 返回预期证书 `9BFF…D0DC` 且 `Valid`。通过 Windows App 键盘输入完整文件名时，下划线和反斜线被丢失，第一次命令 `FileNotFound`，改用精确目录内 `*msix` 后才取得有效验签结果；这个远控输入失败不算包签名失败。新版仍停在主密码页，**尚待用户解锁后核对原资产及四边四角真实拖拽**；旧证书尚未清理，不得把构建/安装记为鼠标缩放通过。前两候选的真机拖拽失败保持有效。

## 子窗口原生按下候选的 Windows 10 真机失败与原生边框回退（2026-10-23）

用户亲自解锁 `ab00edb` 独立 QA 后，原 4 分组/6 资产仍在，底部显示云端已同步、本机队列已处理；未触碰真实资产。Windows 10 同一 RDP 会话中只读 `GetWindowRect` 测得 QA 初始宽 1118、高 560；边/角拖动后视觉尺寸未变。用 PowerShell 系统窗口校准：标题栏拖动可移动，精确外侧缩放热区拖动可缩小宽度；QA 标题栏同样可移动。QA 右、左、下、右下角的内部/外侧命中位置均无尺寸改变。只读 `WM_NCHITTEST` 探针在 QA 前台返回：父/子左 `10/10`、右 `11/11`、上 `12/12`、下 `15/15`、内部 `1/1`，说明子窗口命中修订生效，却**仍不能证明真实按下被送入原生尺寸循环**。因此 `ab00edb` 的鼠标缩放仍判失败，前两版失败继续保留；不能把 CI、签名、合成命中或标题栏可拖当作缩放通过。

在原 4 分组/6 资产及新 MSIX `Valid` 核对后，按用户当次授权，仅从 Windows 10 测试机的“受信任的人”按完整指纹移除上一张 OrbitTerm 测试证书 `BD23…041F`；脚本前后输出由 `old=True/new=True/signature=Valid` 变为 `old=False/new=True/signature=Valid`。移除的是旧公钥证书，可从先前测试包重新导入；未清除账户、资产或 QA 数据。

后继**源码候选，尚未构建或验证**：Windows 10 不再以 `WM_NCCALCSIZE` 把 WinUI 客户区画满原生三侧边框，也不再给 WinUI 子 HWND 安装边缘命中子类；恢复系统拥有的 `WS_THICKFRAME` 尺寸框，保留 DWM 深浅主题设置和窗口圆角区域。Windows 11 的独立命中路径不变。这优先恢复真实自由缩放，可能使 Win10 三侧原生细框重新可见，外观需要真机评估；不能称为同时解决美观与缩放。下一固定提交须过 Windows CI、签名及 Windows 10 四边四角实际鼠标、最小尺寸、标题栏、最大化/还原、主题/贴靠核验；若原生边框仍太突兀，需在不遮挡非客户区的前提下单独迭代。Windows 终端 EOF/SFTP 硬断线、Android/K60、Apple/Linux GUI 与五端墓碑矩阵仍开放。

## 原生边框回退候选的安装前核验（2026-10-23）

上述源码已固定并推送为 `4c15188`。同提交的 [Windows Client CI](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/40051112095)、[Linux CI](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/40051112151)、[Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/40051112073) 均最终 `completed/success`。Security Gates 的六项常规作业成功，条件式 OpenSSH RC 与 macOS 签名 UI 冒烟 skipped。前一候选 `ab00edb` 的 Android ATD 安装失败和 Windows 真机缩放失败保持有效；CI 成功不能覆盖真机失败。

Windows artifact `12542789222` 的外层 ZIP SHA-256 `dcd49bf3a123f6816ba6a577740c439f67272a9cbdf36e495d9f73ebe9f62f02` 与 GitHub digest 一致，归档自检通过。包内 MSIX SHA-256 `699c2afd4d679231eb10ffba9c555187bf80ed9e928caa7f13beba09e6f3e074` 与 `SHA256.txt`、Windows 本机 `Get-FileHash` 一致；测试证书 SHA-256 `a19da1e23e9e9bf52bb008d5cdd14c59e3ceba6cf6e4f89b2c6b7a1d65306673` 也与 Windows 本机一致，SHA-1 指纹为 `48EE85AB401A09550656C26F3F9CE8F5FB4742B7`。清单保持独立 `OrbitTerm.Client`、x64、`0.3.0.33`。Windows 远控一次带反斜线的 `cd` 被输入通道吞掉路径分隔符、报不存在；改为逐层进入专用目录后取得有效 Windows 本机哈希，前次错误不计核验通过。

旧独立 QA 已正常退出；包外账户状态、包内 Settings 和 LocalState 复制到加密外置盘，逐目录比对一致。不含系统 Helium，不能声称全量可恢复。新包与证书已传至 Windows 测试机；导入前只读 `Get-AuthenticodeSignature` 显示预期新签名者 `48EE…42B7`、状态 `UnknownError`，因为该新测试证书当时尚未受信任，**不能记作 `Valid`**。用户在实际操作点确认新证书导入、独立 QA 覆盖更新及验后旧证书清理；经审查的安装脚本记录 `SUCCESS`，注册为 `OrbitTerm.Client_0.3.0.33_x64__xt8nwf3jj28g8`，新版已启动并停在主密码页。**新包安装后尚未完成独立系统签名复核、原资产核对和鼠标缩放实测；旧证书尚未清理**，等待用户亲自解锁。当前不能宣称原生边框已恢复鼠标缩放或外观达标。五端完整验收仍开放。

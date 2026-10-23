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

下一阶段：在 Windows CI 完整通过后取固定提交的内部测试 MSIX，核对归档、包签名和新证书；如需在测试机导入新的测试证书，须在实际更新动作前另行确认。更新独立 QA 后复测 shell 自然退出、SFTP 保持、多分屏、在途硬断线/任务状态，并在窗口化与最大化、浅色与深色下检查四边视觉和八方向缩放、标题栏按钮、拖动及贴靠。Android/K60 对照已有被动断开和硬断线记录；iOS/macOS/Linux 新候选 GUI 与五端完整验收仍开放。

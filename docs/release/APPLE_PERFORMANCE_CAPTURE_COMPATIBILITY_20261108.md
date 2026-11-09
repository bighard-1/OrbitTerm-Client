# Apple 性能采集兼容性与归属整改（2026-11-08）

## 起点与真实失败

在 `eb06f24` 的严格 JSON／完整轮次整改后，继续核查真实 Instruments 输出，而非只依赖合成 XML。macOS 的 Activity Monitor／Animation Hitches 模板和 Points of Interest instrument 可用；iPhone 13 mini 被开发工具识别为已配对可用，K60 未出现在 USB 列表。现有 Mac QA 为 `20261030.1`，未建立与本轮候选一致的构建证明，未将其当作本候选实机性能样本，也未启动正式版。

本轮仅启动独立、无账户或网络能力的辅助进程，原始 trace／工具日志存放加密外置盘私有证据目录，不进入仓库。首次 6 秒 Activity Monitor 真实导出显示：相同 footprint 的第二次观测是引用；旧摘要工具跳过该引用，误取随后共享内存列。原 footprint 两次均为 **13,254,920 字节**，旧工具却读为 **13,254,920／3,276,800**。重复 CPU 值同样可能漏算；等权平均也不能代表不等长采样区间。本反例与旧日志保留，不被后继成功覆盖。

采集脚本原先固定附加 `OrbitTerm` 名称，无法区分同名正式／QA，也无法测量已运行应用的冷启动。默认 Activity Monitor 模板未包含本应用的 Points of Interest 采集配置，不能仅因为代码有 signpost 就宣称捕获了响应区间。

## 源码／验收流程整改

- 生产者按 schema 的 `pid`、`duration`、`cpu-percent`、`memory-physical-footprint` 定位列，验证工程类型与每行结构，解析重复值引用；断链、类型不符、循环／重复标识、其他进程和缺失度量均拒绝。
- 显式要求 `--target-pid`，逐行核对但不写入发布 JSON；初始无 CPU 差值的 sentinel 不按零计算，开始采样后的缺口拒绝。CPU 按区间时长加权、保留精度，不将略超阈值的结果四舍五入成通过；footprint 取对应列的真实峰值。
- 采集器要求非冷启动使用显式 PID，冷启动使用显式 launch target，互斥且不再按共享进程名猜测。显式加入 Points of Interest，拒绝已有／符号链接输出、缺参、不支持模板和无效时长，不覆盖失败记录；原始 xctrace 非零退出保持失败，不以 trace 存在改成成功。
- [采集协议](APPLE_DEVICE_PERFORMANCE_SLO.md)同步区分冷启动、附加模式、构建归属和帧 trace 人工复核。候选签名／源码映射及真实 UI 读数仍需独立证明，新增参数不能替代这些证明。

## 分层验证

**本地自动化**：性能套件首轮 40／40；补入 CPU 临界精度回归后最终 41／41。含引用重复计数、加权平均、footprint 列顺序变化、错误进程、缺失列／结构／间隔、非法引用，以及采集器目标选择／冷启动分派／输出保护。安全 Python 22／22、静态安全扫描、桌面视觉合同与稳定性基线通过。一次检查命令误用不存在的视觉脚本路径，命令退出 2；改用仓库实际入口后通过，这不是产品测试失败或被跳过的检查。

**真实工具自动化，非产品性能验收**：12 秒受控辅助进程记录／导出退出 0；修复后读取 11 个 CPU 样本，时长加权约 35.019%（旧等权约 35.104%），峰值 footprint 17,481,992 字节，错误 PID 拒绝。显式 PID＋Points of Interest 入口另一次退出 0，真实 Activity 导出 7 行／6 个 CPU 样本；初次辅助进程区间恰在采集窗口外，Points of Interest 导出 0 行，不能算响应计时验证通过。后续重复发出区间的辅助进程回执另追加。

**保留未通过项**：三次显式冷启动 CLI 试采均退出 **54**（两次独立可执行文件、一次独立测试 app bundle）。虽然输出显示保存 trace，app bundle 的私有导出也有 14 行测试 signpost，仍不据此将非零退出改判成功，退出语义／稳定冷启动采集路径尚未闭环。未删除失败 trace，也未降低 SLO 或解除发布阻断。

重复区间补测：另一次显式 PID 采集退出 **0**；真实 Points of Interest 导出退出 0，共 **12 行**，包含预定测试标记。由此补齐“采集窗口内可收到标记”的工具证据，不把前次 0 行结果抹去；仍没有产品响应读数或冷启动成功结论。

**GUI／真实设备／五端**：没有在产品中执行场景，没有手机触控／解锁、真实账户／资产操作，也没有产品 CPU、内存、帧率结论。辅助进程在实体 Mac 运行只证明采集工具兼容性，不计作 macOS／iOS 产品实机性能通过；48 份 Apple 实测、九轮桌面并发、五端墓碑完整矩阵、专用签名 Mac UI 和实际多屏 DPI 仍待验。原有两份 Android JNI 未提交改动保持，未纳入本轮。

## 下一步与跨端对照

固定 QA 构建准备：外置盘建立干净、detached 的 `eb06f24dd1e8a19532595256ec1d9197747812fc` 检出，排除原工作树两份 JNI 变更；Rust macOS Release 锁定／离线构建成功。独立 Mac QA `20261108.1` 首次 Xcode 构建退出 65：缺少可用描述文件。只读核对发现旧 QA 的嵌入开发描述文件于 **2026-11-05** 过期，证书身份仍可用；允许 Xcode 自动更新描述文件后第二次仍退出 65，错误为钥匙串开发者账户凭据不完整及 `No Accounts`。未绕过签名、未安装／启动失败产物，也未改正式版或系统信任。此项需要用户在 Xcode Settings → Accounts 恢复原开发者账户认证，再重试开发描述文件更新；不在聊天索取 Apple 密码或双重验证码。两次构建失败日志留存，不能用 Rust 构建通过代替签名 QA 构建成功。

源码保存为 `940f23a17513830b7348021d3a6f956c54251895`，推送并核对独立分支 `codex/apple-performance-capture-20261108`，未更新原 PR 分支，避免取消原 `eb06f24` 的 Apple CI。41 项是本地结果；本次桌面接口只读确认 Mac 已锁屏，浏览器会话也不可用，新分支工作流**尚未触发**，不能写为托管通过。原候选 Windows／Linux／Rust／Android 已通过，Apple 最终回执仍待收，详见[前一提交回执](PERFORMANCE_EVIDENCE_VALIDATION_20261108.md)。

清理时发现一次 launch 试采留下测试辅助进程处于停止态 `T`；精确核对其私有可执行路径后只对该辅助进程发送 TERM／CONT，确认所有本轮辅助进程均退出。没有恢复／终止任何产品进程；失败 trace 和源码夹具保留在私有外置盘目录，后继应在解锁 Mac 后重新核查冷启动工具行为，不对退出 54 擅自归因或改判成功。

先收固定候选门禁最终回执，继续排查冷启动非零状态，再从干净检出构建、验签并私有记录 QA 产物与源码映射，才开始真实八场景采集；不把旧安装包改标为新候选。需要手机时再请用户解锁。Android／Windows 后续优先对照采集目标归属、重复观测不能漏算、CPU 时长权重、内存指标口径、失败不覆盖旧记录和原始证据复核，不能用本轮 Mac 辅助进程代替各端产品结果。

## 账户恢复后的签名与录制对照

Xcode 登录后按原团队重试仍退出 **65**：`No Account for Team`，原 QA 描述文件仍不可续签。Xcode 只显示另一个 Personal Team；用户确认只使用当前账户。保留原团队失败。在临时签名工程中选定个人团队，使用同类钥匙串 entitlement 的最小探针构建及严格验签通过；未修改正式工程的 Team、签名或能力。

在独立外置盘 worktree 构建 **OrbitTerm Performance QA `20261108.2`**：基线 `eb06f24` 加仅供私有构建的隔离补丁（SHA-256 `1e5487d9bb2c9045e2145b75dbc42736f28a570fade856f2d4d3d240e19d7a34`）。显式 QA 编译标记＋全新精确 Bundle ID、独立 Application Support 目录和旧式文件钥匙串迁移禁用；标记存在但身份不匹配时立即失败。补丁不进入发布源码。验签确认 arm64、Apple Development、Hardened Runtime、唯一自有钥匙串组、匹配且有效的嵌入描述文件（到期 `2026-11-16T01:05:54Z`），7 个内置运行库，无外置盘依赖路径。主执行文件 SHA-256 `97f0fb1ab713a2f746866e26ad84c713e10fd009fe28f3cb0f85fae7ab43f0ab`。产物、私有补丁和日志存于 `mac-personal-qa-eb06f24/` 私有证据目录；未启动／安装产品、未替换正式版或旧 QA。静态核对不代替实测凭据／路径隔离；个人团队签名不证明原团队升级、正式分发或同候选实机性能通过。

同一 Mac、同一无业务辅助 app、同一 `940f23a` 录制入口：32 秒上限下辅助进程先自然退出，录制返回 **0**，真实导出存在 Activity Monitor 与预期标记（40 行 signpost）；将上限改为 6 秒，达到时限后返回 **54**，虽保存 trace 仍按失败保留。原始三次失败不覆盖。仅建立停止方式与返回值的实测差异，不将其归因为任何产品故障。K60 已只读确认 USB 在线，未安装、触控或读取业务数据；iPhone 未操作。

第三组对照：32 秒上限，开始后只向采集器发送一次 SIGINT（对应 Ctrl-C 停止），同样返回 **54** 且保存 trace，按失败保留。只清理路径匹配的私有辅助进程。当前可验证的路径是目标先正常退出，下一步在完全隔离的 QA 上验证正常退出能否结束采集；不在收据中忽略或归一化 54。

原 `eb06f24` 现已收齐八项必跑 CI 结果，见[最终回执](PERFORMANCE_EVIDENCE_VALIDATION_20261108.md)。后续先用新身份做隔离启动／钥匙串冒烟，并建立适用于持续运行 app 的可靠录制停止路径，再执行固定签名候选产品实测。Android／Windows 继续分别验证安装身份、升级前后的数据归属和独立性能证据。

## 独立 Mac QA 首次启动与正常退出

使用 `20261108.2` 的原签名二进制和 `940f23a` 的采集入口。首次使用构建产物 `OrbitTerm.app` 的绝对路径时，Instruments 同时匹配正式版和 QA，退出 **20**，没有启动目标或生成 trace。为测试副本使用唯一文件名 `OrbitTerm Performance QA.app`，严格验签通过，主执行文件摘要仍为 `97f0fb1ab713a2f746866e26ad84c713e10fd009fe28f3cb0f85fae7ab43f0ab`。

实体 Mac 上出现空白登录根界面。QA 进程实际打开的两个应用数据文件都在新隔离目录。新数据目录和新偏好文件在本次启动后生成。正式版及旧 QA 的应用数据与偏好快照前后摘要一致。此轮数据证据限于启动阶段的打开文件和文件元数据，凭据写入／读取及旧身份升级待独立验收。

录制以 150 秒为上限。启动时同一路径出现一个录制目标和一个暂停的同包进程。连接 GUI 时两个进程都处于活跃状态，并各自产生 `AppLaunch` 区间。用 `Command+Q` 逐个正常退出后，Instruments 以 `Target app exited` 结束，返回 **0**。采集器核对了录制 PID 的 **36 个资源样本**和唯一成对的 `AppLaunch` Begin／End，类别为 `PointsOfInterest`。原始 signpost 导出共四行，其中两行属于录制目标。trace SHA-256 为 `e4345b0ba3af39bca6cda43623fb44590378f5cd839fd37d8365693c4b1f305b`，原始录制和快照保存在外置盘私有目录。复核时两份 QA 进程均已退出。

本轮通过的是隔离启动和录制正常收尾。双进程样本只保留为诊断，独立 QA 仍有私有补丁，本轮未采集帧数据或补齐重复轮次。产品性能 SLO 与五端验收继续开放。首次歧义失败和此前退出 54 的结果均保留。`9745d54` 的 Windows／Linux workflow 已 success，Security Gates `42544174276` 在本次读取时仍在执行。

## 单实例启动与帧采集复测

继续使用 `20261108.2` 同一签名 QA。启动前逐次校验包签名和二进制摘要。直接以同名可执行文件的绝对路径启动时，Instruments 再次报歧义并退出 20。使用唯一 `.app` 文件名时，Instruments 启动一个录制目标和一个暂停的同包进程。读取窗口唤醒了暂停进程，产生两份启动区间。该次录制和失败均留作诊断。

使用 Instruments 的命令与参数入口，以 `/usr/bin/env` 执行已核验的 QA 可执行文件。Activity Monitor 和 Animation Hitches 分别完成一次冷启动。约每 0.3 秒观察一次进程，两轮各只观测到一个活跃 QA 实例。两次均看到登录根界面并用 `Command+Q` 正常退出，采集器均返回 0。两份 `AppLaunch` 标记均为各自 PID 的 Begin／End 配对。

Activity Monitor 有 9 个归属明确的样本，录制期时长加权平均 CPU 为 **1.94%**，峰值物理内存为 **27.3 MiB**。应用内 `AppLaunch` 区间为 **165.3 ms**。该区间从应用标记开始计算，桌面图标点击到首帧呈现的时长仍待测。资源 trace SHA-256 为 `f6ad07c61381260529c9d59f1c84ef2753e61662cf12be13e130c778bf266dd0`。

Animation Hitches 录得 **187.4 ms** 的应用内启动区间。帧率、帧生命周期、卡顿和显示事件的导出表均为空。帧 trace SHA-256 为 `63f3cbe21eb7a9e26a63a9c944f2c96857ddae24b29911b1803d0641edca4a48`。追加 `Core Animation FPS` 的尝试在启动前退出 2，本机 Instruments 报告 macOS 上禁用该仪器。空表保留为缺测，最低帧率及卡顿次数仍待取得可归属的观测。对照仪器和帧轨的定义见 [Apple Instruments 文档](https://developer.apple.com/documentation/xcode/improving-app-responsiveness?changes=la%2Cla)。

为排查启动方式的影响，另用 Instruments 直接选择独立应用包，先清理路径、状态和启动批次均已核对的暂停同包进程，再观察录制目标并正常退出。该对照返回 0，只观测到一个活跃 QA，帧率、帧生命周期和卡顿表仍均为零行。资源与标记链路已验证，Mac 帧指标和正式三轮仍待验。所有尝试和原始 trace 保存在私有目录，采集结束后 QA 进程均已退出。

## 帧时间对照与首次显示后可响应时间

在实体 Mac 的 Xcode 26.6／macOS 26.5.1 环境中，以独立 AppKit 窗口持续绘制合成动画，并在主线程注入一次约 350 ms 的停顿。首次编译遇到主线程隔离错误。修正后第一次 Instruments 运行又阻塞在对照程序写外置盘日志，未进入动画，达到时限后退出 54。保留编译日志、采样和录制。将元数据输出改为 stdout，由外部命令保存后重跑，窗口实际绘制 191 次，人工停顿为 **351.0 ms**。Animation Hitches 正常收尾并返回 0，导出 `InjectedStall` 两个标记。帧率、帧生命周期和卡顿表仍为零行。

同一个合成窗口使用 ScreenCaptureKit 当前进程窗口接口，按窗口 ID 限定采集范围，只保存帧状态和显示时间。退出 0，获得 **186 个完整帧时间戳**。正常段的 70 个帧间隔中位数为 **17.4 ms**，最大值 **20.9 ms**。已知主线程停顿为 **351.2 ms**，跨越该停顿的帧间隔为 **351.6 ms**。这验证了合成窗口的帧时间来源及停顿识别。实际发布候选的启动窗口帧率、卡顿数及正式三轮仍待验。参见 [ScreenCaptureKit 显示时间定义](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/displaytime)。

另用独立 XCUITest runner 对现有签名 QA `20261108.2` 执行 `XCTApplicationLaunchMetric(waitUntilResponsive: true)`。按绝对路径启动并核对 Bundle ID、版本及单实例，测量后确认空白登录根界面，通过 `Command+Q` 正常退出。XCTest 执行一轮预热和一轮记账，测试 **1／1** 通过，无失败或跳过。`.xcresult` 的 `ApplicationFirstFramePresentationResponsive` 样本为 **263.355 ms**。前次 **165.3 ms** 的应用内 `AppLaunch` 区间继续单独留存。参见 [XCTest 启动指标定义](https://developer.apple.com/documentation/xctest/xctapplicationlaunchmetric/init%28waituntilresponsive%3A%29)。

对照源码、日志、trace、帧时间元数据和 XCTest 结果保存在 `mac-personal-qa-eb06f24/method-calibration-203056/` 私有证据目录。测量结束后，QA、测试窗口和测试 runner 均已退出。`9745d54` 的六项必跑 Security Gates 已全部通过，条件式 OpenSSH 和签名 Mac UI 仍为跳过。上述局部实测与 CI 回执共同提供诊断证据，Apple 正式 SLO 与五端验收保持待验。

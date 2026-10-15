# Android / Windows 排队删除与远端墓碑证据收敛（2026-10-15）

本专项接续 Apple 旧 `HTTP 409` 删除队列收敛。范围仅限源码、自动化与隔离 Android 模拟器；没有操作测试账户资产、服务端或线上部署。本行所在客户端提交为源码候选，不能当作五端完整验收。

## 原始缺口与修复

- Windows：原删除重试每次生成新操作 ID 和新向量钟；拉取同 ID 墓碑时直接清除本机待删除意图，未证明云端墓碑覆盖本次请求。现于网络请求前将操作 ID 与请求向量钟写入 DPAPI 保护的同步状态，重试复用；远端状态仅在同 ID、`deleted`/`purged`、正数服务端修订及严格向量钟覆盖时确认排队删除。旧队列无请求钟时不静默确认，下一次有本地有效基线时重新生成并持久化请求。缺失元数据但仍有排队删除时也不当作纯本机删除成功。
- Android：原 outbox 只有操作 ID，没有首次请求钟；重试会从可变同步元数据重新计算钟，且拉到远端墓碑时只更新元数据，不清除有充分证据的旧删除队列。现 Room 12→13 增加可空请求钟，用户发起软删时在同一数据库事务内捕获；旧队列首次投递前用操作 ID 条件写入并重读，重试发相同钟。拉取墓碑只在同 ID、墓碑态、正数修订、严格向量钟覆盖时用操作 ID 条件清除队列；无证据则保留。迁移不伪造旧队列证明。
- 两端均不把资产名称、响应正文、密码、令牌或完整地址写入判定字段。Android 活动清单与本机元数据同时缺席时，也不再把账户同步资产的排队删除当成“从未上云”直接清除，因为活动清单可能省略已删或无法解密的记录。较旧且已失去有效基线的排队删除、以及极短时间内新建后又删除而尚未上云的资产，可能保持阻断；需要后续可靠的云端缺席证明或人工安全处理。这是保守的未关闭项，不得以本次源码修复声称旧队列全部自动归零。

## 验证与失败保留

| 层级 | 结果 |
| --- | --- |
| Windows 源码/自动化 | `dotnet` 编译成功；直接运行已编译测试 DLL 并使用本机同架构 `liborbit_core.dylib`，`EncryptedAssetPublisherTests` 与 `EncryptedConfigSynchronizationServiceTests` **34/34 通过**，含重试操作 ID/钟稳定、覆盖/未覆盖/缺修订/损坏钟与旧队列无钟。常规 `dotnet test` 在 macOS 因测试项目要求 Windows `orbit_core.dll` 退出 1；该首次门禁失败保留，不能称为 Windows 原生测试。 |
| Android 源码/自动化 | data+app Debug 单测 **115 项、0 失败、1 跳过**；Debug AndroidTest 包构建通过；最终 data+app Debug 单测、QA 单测与 `assembleQa` 联合门禁 **357 个任务成功**。arm64 独立 QA APK SHA-256 `d46838a402d43940f77aeae023c33703194246c23dfde30145bb739bfdccc7f5`，仅已构建、未安装 K60。首次带 `--offline` 构建因测试依赖未缓存失败，联网重跑成功；失败保留。 |
| 隔离 Android GUI/设备测试 | Android 15 只读、无窗口模拟器上，Room 1/8/9/10/12→13 迁移 **5/5**，outbox 包含请求钟 CAS 在内 **6/6** 通过；这属于隔离设备仪器测试，不是账户 GUI/真机资产验证。测试后正常关闭模拟器。 |
| K60 实体设备 | K60 扩展坞 ADB 曾可识别，但两次 `connectedDebugAndroidTest` 在 Gradle 设备发现阶段均报 `No connected devices`；随后短暂可读又断开。未安装新 QA、未登录、未软删或永久删除资产，不能记为真机通过。 |
| Windows 实机/五端 | 尚无 Windows 10 KVM 客户端安装、原生 DLL、GUI、断网、队列重启或跨端墓碑验收；KVM 可承担虚拟 Windows 功能验收，但不等于实体 Windows 硬件。五端同版完整验收未完成。 |

## 后续对照清单

远端 CI 后续回执：固定提交 `3d10e8d` 的 [Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/38696613492)、[Linux Client](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/38696613493)、[Windows Client](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/38696613516) 均显示 `completed/success`。前一提交 `794b1e0` 的 Security Gates 因新推送被取消，不能记为通过或产品失败；同一旧提交的 Linux/Windows 工作流已成功。CI 不是 Android K60 或 Windows GUI 验收。

2026-10-15 连接续验：K60 改用 USB-C 对 USB-C 直连后，连续五轮 ADB 设备与系统版本读取稳定；核对现装独立 QA 包签名与新包相同，`adb install -r` 返回 `Success`，重新拉取已安装 APK 与候选 SHA-256 `d46838a402d43940f77aeae023c33703194246c23dfde30145bb739bfdccc7f5` 完全一致，正式版未安装/未覆盖。随后尝试在真机运行迁移与 outbox 仪器测试，系统拒绝另装临时 Debug 测试包：`INSTALL_FAILED_USER_RESTRICTED`、实际运行 **0 项**；此前模拟器 5/5 + 6/6 不变。K60 此时锁屏，尚未核对 QA 启动后资产或真实账户队列；已请求用户在手机本机解锁，未继续尝试 PIN，失败保留。

1. K60 解锁后，确认同签名新 QA 能打开、旧账户及虚构资产可见；再用唯一虚构资产验证离线软删、进程重启、409/已删除墓碑收敛、两次同步不复活；记录活动/最近删除、队列状态，不碰真实 Debian/RDP。真机仪器测试另需系统允许安装其隔离 Debug 包。
2. 用户现提供 RustDesk 内名为“个人笔记本”的 Windows 10 电脑；连接成功后在该机内构建或安装同提交候选，运行原生测试；用账户隔离 QA 验证同 ID 覆盖墓碑清队列、未覆盖/无修订不清队列、重启后幂等键稳定，和 K60/Mac 交叉同步。连接凭据仅用于临时会话，不写仓库。此前讨论的 KVM 未作为本轮目标。
3. 固定本提交的 Security Gates / Windows / Linux 成功结果；首次失败和条件跳过分别记账。Apple/Linux/iOS 本候选未重跑，不能由 Windows/Android 单元结果外推。

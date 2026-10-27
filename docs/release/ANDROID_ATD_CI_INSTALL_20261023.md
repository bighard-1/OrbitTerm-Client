# Android ATD 仪器测试安装服务启动竞态（2026-10-23）

`ab00edb` 的 [Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/40049205735) 中，`Android instrumentation and migration gates` 作业在 Android 15 软件渲染模拟器启动后、任何应用断言执行前失败。预构建的隔离 smoke APK 已成功生成；`sys.boot_completed=1`，但第一次 `adb install` 遇到瞬态传输失败，第二次提示系统服务未就绪，第三次在 Android 系统 `StorageManagerService.allocateBytes` 调用 `PackageManagerInternal.freeStorage` 时产生空引用。门禁明确记录 `isolated smoke fixture APK installation failed`，没有 Android connected test 结果，也没有报告 artifact。**此作业失败，不可写成客户端功能通过或仪器测试通过。**

源码候选仅修改 `scripts/security/run_android_smoke_fixtures.sh` 的隔离 APK 安装重试：原有传输/服务未就绪重试保留，针对 `aosp-atd-api35` 环境和上述精确系统服务启动签名，最多允许五次、有界间隔地重试；其他安装错误仍立即失败，最终同一错误仍原样输出并使门禁失败。未更改应用代码、测试断言或生产端安装路径。`bash -n` 用于本地语法核对；是否解决这次 CI 竞态，必须由新提交的完整 Android 仪器门禁及报告证明，不能由脚本语法或 Windows/Linux 构建替代。

Windows 10 独立 QA 更新与鼠标缩放验收另见 [Windows 专项日志](WINDOWS_SESSION_AND_FRAME_20261022.md)。五端完整验收仍未完成；Android/K60 真机、Windows QA、Apple/Linux GUI 与跨端墓碑对照继续作为开放项。

## 后继 Android 15 ATD 的另一项系统安装启动竞态（2026-10-25）

固定提交 `5162561` 的 [Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/40250699439/job/121341813975) 在 24 分 32 秒后，`Android instrumentation and migration gates` **失败**。预构建全部成功，但第一次安装隔离 smoke APK 时，Android 系统 `InstallLocationUtils.resolveInstallVolume` 对尚为空的 `StorageManager` 调用 `getVolumes()` 抛 `NullPointerException`；脚本随后报 `isolated smoke fixture APK installation failed`，没有进入应用断言，仪器报告 artifact 也没有生成。此为**模拟器系统服务启动竞态的证据推断**，不是客户端 APK 业务断言失败；作业本身必须保留为失败。该签名与先前 `PackageManagerInternal.freeStorage` 空引用不同，旧有精确重试未匹配。

后继源码候选仅在 `aosp-atd-api35` 的隔离 smoke APK 安装分支，把上述 `getVolumes()`/`resolveInstallVolume` 精确系统调用签名加入已有的最多五次、有界间隔重试；非 ATD 环境、其它安装失败及最终耗尽重试仍原样失败。没有修改生产 APK 安装、业务功能或仪器断言。本地 `bash -n`、真实日志签名匹配及无关异常不匹配均通过；首次临时测试命令的 shell 引号写错、尚未执行模式检查，修正后重跑通过，**不是产品脚本语法失败**。必须以后继固定提交的 Android 仪器门禁及 connected test 报告来判定此修订是否有效，不能借 K60 既有 12/12 或 Windows/Linux CI 替代。Android/Windows 后续仍对照受保护 QA、SFTP 文件目标和墓碑；五端完整验收未完成。

### 固定提交 `d02d27a` 的门禁结果

后继 [Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/40252952402) 最终为 `completed/success`。Android 15 ATD 作业预构建成功，隔离 smoke APK 安装越过上次 `getVolumes()` 失败点，锁定/浅色/深色、连接失败、离线、同步冲突、传输队列等夹具状态继续运行；`Android instrumentation and migration gates` 作业最终 `completed/success`，`android-instrumentation-results` 报告归档已生成。作业整体成功证明此固定提交的隔离夹具、连接测试及报告保存链路完成；它不证明每次启动都会触发或命中新增重试分支。旧 `5162561` 安装失败保持为独立失败证据。

同提交 [Windows Client](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/40252952331)、[Linux Client](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/40252952426) 均成功。Security Gates 其余实际执行的 Rust Release、Android Release、Apple checked-path、依赖/许可与桌面视觉作业成功；条件式 OpenSSH release-candidate 与 macOS signed UI smoke 为 `skipped`，不记通过。本轮没有新增 K60、iOS、macOS、Linux 或 Windows 产品 GUI 验收；五端完整验收仍未完成。

## 固定候选的门禁复核（2026-10-23）

修订已随固定提交 `4c15188` 推送。该提交的 [Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/40051112073) 最终为 `completed/success`；其中 `Android instrumentation and migration gates` 的 Android 15 模拟器 connected tests 与报告保存步骤均成功，生成 `android-instrumentation-results` artifact。Rust、Apple checked-path、Android Release、桌面视觉契约及依赖/许可作业也成功；条件式 OpenSSH RC 与 macOS 签名 UI 冒烟为 skipped，不记通过。原 `ab00edb` 安装失败仍保留，不能被这次成功改写。此项是自动化证据，**没有新增 K60 真实设备 GUI 结果**，也不是五端完整验收。

## `e00c023` 的隔离安装服务再次失联（2026-10-27）

[Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/40515205598/job/122227250975) 的 Android 仪器作业在软件模拟器报告 `sys.boot_completed=1` 后安装预构建 smoke APK。五次有界尝试先后遇到 ADB 传输失联、系统安装服务未就绪、已知存储服务初始化空引用、ADB 传输失联，最后返回 `cmd: Can't find service: package`；作业明确报 `isolated smoke fixture APK installation failed`。没有运行任何 smoke/connected 断言，也没有 Android 仪器报告。**该固定候选 Android 仪器门禁失败，旧成功不能替代。**

日志仅能证明托管模拟器的包服务在安装阶段反复失联，不能据此归因于 Android 产品代码。当前只记录失败并在后继固定提交重跑；若反复出现，应将模拟器启动稳定性与安装重试上限单独处理，保持非启动类安装错误立即失败。Windows/Linux CI 与其它 Security Gates 子作业的结果须各自列示，不得把整组门禁误记通过；K60 真机也未由本作业重新验证。

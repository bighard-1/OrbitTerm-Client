# Android ATD 仪器测试安装服务启动竞态（2026-10-23）

`ab00edb` 的 [Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/40049205735) 中，`Android instrumentation and migration gates` 作业在 Android 15 软件渲染模拟器启动后、任何应用断言执行前失败。预构建的隔离 smoke APK 已成功生成；`sys.boot_completed=1`，但第一次 `adb install` 遇到瞬态传输失败，第二次提示系统服务未就绪，第三次在 Android 系统 `StorageManagerService.allocateBytes` 调用 `PackageManagerInternal.freeStorage` 时产生空引用。门禁明确记录 `isolated smoke fixture APK installation failed`，没有 Android connected test 结果，也没有报告 artifact。**此作业失败，不可写成客户端功能通过或仪器测试通过。**

源码候选仅修改 `scripts/security/run_android_smoke_fixtures.sh` 的隔离 APK 安装重试：原有传输/服务未就绪重试保留，针对 `aosp-atd-api35` 环境和上述精确系统服务启动签名，最多允许五次、有界间隔地重试；其他安装错误仍立即失败，最终同一错误仍原样输出并使门禁失败。未更改应用代码、测试断言或生产端安装路径。`bash -n` 用于本地语法核对；是否解决这次 CI 竞态，必须由新提交的完整 Android 仪器门禁及报告证明，不能由脚本语法或 Windows/Linux 构建替代。

Windows 10 独立 QA 更新与鼠标缩放验收另见 [Windows 专项日志](WINDOWS_SESSION_AND_FRAME_20261022.md)。五端完整验收仍未完成；Android/K60 真机、Windows QA、Apple/Linux GUI 与跨端墓碑对照继续作为开放项。

## 后继 Android 15 ATD 的另一项系统安装启动竞态（2026-10-25）

固定提交 `5162561` 的 [Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/40250699439/job/121341813975) 在 24 分 32 秒后，`Android instrumentation and migration gates` **失败**。预构建全部成功，但第一次安装隔离 smoke APK 时，Android 系统 `InstallLocationUtils.resolveInstallVolume` 对尚为空的 `StorageManager` 调用 `getVolumes()` 抛 `NullPointerException`；脚本随后报 `isolated smoke fixture APK installation failed`，没有进入应用断言，仪器报告 artifact 也没有生成。此为**模拟器系统服务启动竞态的证据推断**，不是客户端 APK 业务断言失败；作业本身必须保留为失败。该签名与先前 `PackageManagerInternal.freeStorage` 空引用不同，旧有精确重试未匹配。

后继源码候选仅在 `aosp-atd-api35` 的隔离 smoke APK 安装分支，把上述 `getVolumes()`/`resolveInstallVolume` 精确系统调用签名加入已有的最多五次、有界间隔重试；非 ATD 环境、其它安装失败及最终耗尽重试仍原样失败。没有修改生产 APK 安装、业务功能或仪器断言。本地 `bash -n`、真实日志签名匹配及无关异常不匹配均通过；首次临时测试命令的 shell 引号写错、尚未执行模式检查，修正后重跑通过，**不是产品脚本语法失败**。必须以后继固定提交的 Android 仪器门禁及 connected test 报告来判定此修订是否有效，不能借 K60 既有 12/12 或 Windows/Linux CI 替代。Android/Windows 后续仍对照受保护 QA、SFTP 文件目标和墓碑；五端完整验收未完成。

## 固定候选的门禁复核（2026-10-23）

修订已随固定提交 `4c15188` 推送。该提交的 [Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/40051112073) 最终为 `completed/success`；其中 `Android instrumentation and migration gates` 的 Android 15 模拟器 connected tests 与报告保存步骤均成功，生成 `android-instrumentation-results` artifact。Rust、Apple checked-path、Android Release、桌面视觉契约及依赖/许可作业也成功；条件式 OpenSSH RC 与 macOS 签名 UI 冒烟为 skipped，不记通过。原 `ab00edb` 安装失败仍保留，不能被这次成功改写。此项是自动化证据，**没有新增 K60 真实设备 GUI 结果**，也不是五端完整验收。

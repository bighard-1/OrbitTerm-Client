# Android CI 模拟器磁盘前置条件（2026-11-02）

## 保留的失败

回执提交 `d169d9b` 的 Security Gates `41566378868`，Android instrumentation job `125689174624` 在启动模拟器时失败：可用 6949.83 MB，创建 userdata 分区需要 7372.80 MB。模拟器进程直接退出，后续 ADB 反复找不到设备，最终等待启动超时。APK 预构建成功，但连接测试、迁移、Compose 和 smoke 未运行，不能记为应用断言失败，也不能记为通过。

同次 Android release、Rust、Apple checked-path、依赖扫描、桌面视觉检查成功；条件式 OpenSSH RC／专用签名 Mac UI skipped。**整体安全门禁未通过**。不覆盖此前被后继提交取消的运行记录。

## 修订与限制

仅 instrumentation 的临时 Ubuntu 托管 job，在预构建前移除本任务不用的 .NET／Haskell 预装 SDK。保留 Java、Rust、Android、Gradle 缓存、JNI、APK、测试结果和源码。脚本要求 `GITHUB_ACTIONS=true`、`RUNNER_ENVIRONMENT=github-hosted` 且 Linux，否则在任何文件变动前拒绝执行；环境变量含义依据 [GitHub 官方变量文档](https://docs.github.com/en/actions/reference/workflows-and-actions/variables)。不用于本机或持久自托管 runner。

模拟器镜像安装和 APK 预构建完成后，再检查 AVD 所在文件系统至少 10 GiB 可用，并复查加速。检查失败立即退出，不再空等启动 10 分钟。清理前后和启动前的容量写入既有 `qa-instrumentation` 报告目录，由失败保留步骤一起上传。没有缩小 Android 测试范围、跳过断言、关闭保护或改动性能配置。

本地 `bash -n`、非托管环境拒绝分支及 `git diff --check` 通过；托管清理、容量检查和完整 emulator suite 尚待后继 CI。没有 K60／iPhone 新设备操作，没有五端完整验收结论。Android 后续先核对模拟器确实启动并执行全部必需测试，Windows 后续继续正常签名 QA 对照；不能用 Windows 的 403 项成功替代本项 Android 门禁。

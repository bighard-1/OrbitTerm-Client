# Android CI 模拟器磁盘前置条件（2026-11-02）

## 保留的失败

回执提交 `d169d9b` 的 Security Gates `41566378868`，Android instrumentation job `125689174624` 在启动模拟器时失败：可用 6949.83 MB，创建 userdata 分区需要 7372.80 MB。模拟器进程直接退出，后续 ADB 反复找不到设备，最终等待启动超时。APK 预构建成功，但连接测试、迁移、Compose 和 smoke 未运行，不能记为应用断言失败，也不能记为通过。

同次 Android release、Rust、Apple checked-path、依赖扫描、桌面视觉检查成功；条件式 OpenSSH RC／专用签名 Mac UI skipped。**整体安全门禁未通过**。不覆盖此前被后继提交取消的运行记录。

## 修订与限制

仅 instrumentation 的临时 Ubuntu 托管 job，在预构建前移除本任务不用的 .NET／Haskell 预装 SDK。保留 Java、Rust、Android、Gradle 缓存、JNI、APK、测试结果和源码。脚本要求 `GITHUB_ACTIONS=true`、`RUNNER_ENVIRONMENT=github-hosted` 且 Linux，否则在任何文件变动前拒绝执行；环境变量含义依据 [GitHub 官方变量文档](https://docs.github.com/en/actions/reference/workflows-and-actions/variables)。不用于本机或持久自托管 runner。

模拟器镜像安装和 APK 预构建完成后，再检查 AVD 所在文件系统至少 10 GiB 可用，并复查加速。检查失败立即退出，不再空等启动 10 分钟。清理前后和启动前的容量写入既有 `qa-instrumentation` 报告目录，由失败保留步骤一起上传。没有缩小 Android 测试范围、跳过断言、关闭保护或改动性能配置。

本地 `bash -n`、非托管环境拒绝分支及 `git diff --check` 通过；托管清理、容量检查和完整 emulator suite 尚待后继 CI。没有 K60／iPhone 新设备操作，没有五端完整验收结论。Android 后续先核对模拟器确实启动并执行全部必需测试，Windows 后续继续正常签名 QA 对照；不能用 Windows 的 403 项成功替代本项 Android 门禁。

## 2026-11-07 最终 CI 核对

固定后继提交 `34cd7bc419a33286ad4c455fc3044eb8569d4523` 的 [Security Gates 41585994271](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/41585994271) 最终成功。GitHub Jobs API 明确 [Android instrumentation job 125751726311](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/41585994271/job/125751726311) 的空间准备、APK 预构建、Android 15 模拟器连接测试及报告保留步骤全部成功；本次不再停留在模拟器启动前。没有仅凭预构建或整体绿标推断连接测试运行，也没有用重新运行覆盖上一磁盘不足失败。

同次 Android release、Rust、Apple checked-path、依赖扫描、桌面视觉共六个必跑 job 全部成功；专用签名 macOS UI 与 OpenSSH RC 两个条件 job 仍 skipped，不作为已完成验收。Windows 原生 CI `41585994208`、Linux 原生 CI `41585994253` 同提交均成功。

这关闭了该候选的托管 CI 磁盘／启动阻碍及必跑门禁待确认项，不代表新增 K60 真机结果或五端完整验收。本轮继续前只读发现 ExternalSSD 未被 Mac 检测到，ADB 工具、Windows App 与私有验收证据路径不可用；未新装手机包、未执行设备删除或覆盖更新。Windows 新版删除结果弹窗仍待设备验证。API 结果暂存内置盘私有 `~/.codex/tmp/orbitterm-qa-20261107/`，待外置盘恢复再归档，不在缺盘状态创建同名假挂载目录。

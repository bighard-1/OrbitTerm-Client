# Android Guava 锁定依赖安全门禁修复（2026-10-28）

## 首次失败与边界

- 固定提交 `4528427` 的 [Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/40646694547) 中，`Dependency vulnerability and license scan` job 失败。扫描报告 `com.google.guava:guava` 的 `32.0.1-jre`、`33.2.1-jre`、`33.3.1-jre` 锁定项涉及 `CVE-2026-102554`，级别 HIGH，修复版本为 `33.7.2`。该失败不因随后修复而抹除。
- 同一旧提交的 Linux Client 与 Windows Client 工作流成功；Security Gates 整体不能据此称为成功。Android `releaseRuntimeClasspath` 未解析出 Guava，本次暴露面主要是 Gradle 构建、注解处理与测试工具链，但安全门禁覆盖这些锁定依赖，仍需修复。

## 修复与本机验证

- 在 Android 根 Gradle 的既有统一版本约束内固定 `com.google.guava:guava:33.7.2-jre`，使用 Gradle `--write-locks` 重新生成 app、core、data 三个模块的锁文件。锁文件中不再包含旧 Guava 版本；Guava 带入的辅助依赖版本与 QA 变体配置由 Gradle 同步更新，并非手工改锁文件。
- `:app:dependencyInsight --dependency guava --configuration _internal-unified-test-platform-core` 确认旧传递请求被固定版本取代；`:app:dependencyInsight --dependency guava --configuration releaseRuntimeClasspath` 无匹配项。
- 本机运行 `:core:testDebugUnitTest :data:testDebugUnitTest :app:testDebugUnitTest :app:assembleRelease -x :app:buildOrbitAndroidCore` 成功，`git diff --check` 通过。排除 JNI 重建任务只是保护工作树中既有二进制改动；本轮没有据此证明新的 Rust JNI 二进制可发布。
- 首次未排除 `:app:buildOrbitAndroidCore` 的 Gradle 验证意外重建了工作树内两个原有、未提交的 JNI 文件；发现后立即停止，并从本机较早的 QA 构建输出恢复两个架构的文件。恢复后的大小与本轮开始时记录一致，分别为 5,785,696 与 6,684,280 字节；因为重建前没有记录摘要，**无法严格证明恢复内容与原内容逐字节一致**。这属于验证流程失误，不计为产品源码修复或已完成验收；该二进制改动未纳入本次提交。

## 验收状态与后续对照

- **源码**：Android Gradle 约束及三模块锁文件已修改；提交号待本次提交生成。
- **自动化**：上述本机验证通过；新提交的远端 Security Gates 待核对，旧提交依赖扫描失败持续保留。
- **隔离 GUI / 真实设备**：均未为本修复运行；K60 未安装新 QA。
- **五端完整验收**：未完成。后续先确认新固定提交的依赖扫描、Android 仪器和 Release 门禁，再继续 K60 与 Windows SFTP 延迟目录、断线及原有跨端矩阵对照。

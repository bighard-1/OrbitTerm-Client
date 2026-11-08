# CI 依赖获取整改（2026-11-08）

## 原始失败与范围

固定源码 `802a48e` 的 Security Gates `42470265561` 第一次及限次重试均失败，原始证据保留：Apple 下载运行库源归档时 HTTP 504／curl 56；Android release 在 setup-java 下载 Temurin 17 时 HTTP 504；Android instrumentation 在下载 Gradle 8.13 时超过 10000 ms。对应下游测试没有执行。详见[前一轮完整回执](WINDOWS_RESTORE_WORKAREA_20261108.md)。这些 CI 网络错误不能归因于用户 Wi-Fi／DNS，也不能写成客户端业务失败或测试通过。

本轮只整改构建／验收工具和获取流程，设备 QA 仍固定为已验签 `802a48e`。K60 未出现在 USB 列表，未请求解锁，也未操作 Android／iOS／macOS／Windows／Linux 客户端 GUI 或线上服务。

## 修订行为

- 提取 HTTPS 源归档下载器，最多 3 次请求，每次连接超时 15 秒、请求上限 120 秒，失败间隔 2 秒。覆盖原先未被 curl 默认重试捕获的退出码 56，最后仍失败时保留原始非零状态。关闭用户 curl 配置文件的隐式影响，初始 URL 与重定向均限定 HTTPS，保持系统证书验证。
- 下载仅写同目录随机临时文件，传输成功后核对已锁定 SHA-256，通过才原子移入源码缓存；失败、摘要错误均清理临时文件。现有缓存仍重新校验，损坏缓存明确失败并保留以供诊断，不提取或执行。
- FreeRDP 保持版本 `3.26.0` 及原摘要不变，网络失败后可使用项目官方公布的 `pub.freerdp.com` 发布目录；本机读取该归档 11500641 字节，SHA-256 与原锁定值 `55fa…44d5` 完全相同，备用地址写入组件清单。摘要不符立即停止，不换来源绕过。OpenSSL 版本及摘要不变。
- 托管 runner 优先使用其明确提供的 JDK 17 路径，实际运行 Java／javac，检查主版本及 CPU 架构后才写入后续步骤的 JAVA_HOME／PATH；没有提供 JDK 则走原 setup-java，提供了但不匹配则失败。仅 GitHub-hosted 条件启用，不在本机／自托管环境猜测 JDK。安全门禁及 Android 受保护构建共用入口，不改变发布审批或签名权限。
- Gradle 仍为 `8.13`，下载超时提高到 60000 ms，加入官方发行包 SHA-256 `20f1b1176237254a6fc204d8434196fa11a4cfb387567519c61556e8710aed78`，保留 URL 校验。没有添加本版本不支持的 Wrapper 重试属性，没有升级依赖、跳过测试或复用旧测试结果。

依据：[FreeRDP 官方下载指引](https://www.freerdp.com/)、[托管 macOS 镜像的 Java 清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md)、[setup-java 缓存语义](https://github.com/actions/setup-java/blob/main/docs/advanced-usage.md)、[Gradle Wrapper 摘要与超时](https://docs.gradle.org/current/userguide/gradle_wrapper.html)、[Gradle 8.13 官方摘要](https://services.gradle.org/distributions/gradle-8.13-bin.zip.sha256)。网页随上游更新；实际执行结果仍须从固定候选 CI 收取。

## 本地自动化与未覆盖

首次新增测试 **13 项中 9 通过／4 失败**，保留失败：2 项是 macOS `/var` 与 `/private/var` 路径归一化的断言不当；另 2 项发现 Bash EXIT trap 运行时局部变量已释放，半文件未清理、退出码被覆盖。将清理路径在登记 trap 时安全引用，路径断言按实际规范路径比较，故障测试保留且不排除。

修正后新套件 **13／13**，覆盖正确／损坏缓存、部分下载后恢复、最多三次失败、摘要错误立即停止、HTTPS 约束、空格路径、JDK 运行时／编译器／架构、缺失工具、环境文件注入及本机／自托管不采用。测试使用虚构 curl／JDK 夹具，不冒充真实网络或托管镜像结果。脚本语法、两份 YAML 解析、桌面视觉合同及静态安全扫描通过；本机真实归档下载与后继完整 CI 回执另收。

提交前进一步收取：`scripts/security/tests` 完整 Python 套件 **22／22**；使用新下载器在外置盘独立目录实际下载 FreeRDP／OpenSSL，两个完整归档分别与既有锁定 SHA-256 一致。本次真实下载直接成功，不能记作真实网络失败后备用来源切换；该切换已在故障夹具中覆盖，官方 FreeRDP 备用归档另有实际完整读取摘要核验。没有用本机旧源码缓存冒充冷下载，也未执行归档中的构建程序。

**无新增隔离产品 GUI、真实设备业务或五端完整验收结果**。后续 Android／Windows 对照固定源码对应的原生产物、依赖失败必须使门禁失败、测试报告实际执行且不被缓存／重试掩盖；Android 重点核对仪器／迁移／smoke 全部执行，Windows 不因本轮构建流程整改重复导入证书或覆盖设备包。

## 固定提交托管中间回执

固定源码 `ff7b254a3729e0b4b742bbf15f2aaa05907169f3` 已推送。Windows [42477833195](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/42477833195) 成功，原始完整日志确认 **412／412、0 失败／跳过**，WinUI 构建 0 警告／错误；Linux [42477833242](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/42477833242) 成功。

Security [42477833346](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/42477833346) 中 Android release／instrumentation 的 JDK 选择步骤均成功，原 setup-java 下载步骤因已采用镜像 JDK 而 skipped，后续 SDK／NDK 安装成功，构建实际执行。Apple 已完成 audited runtime 构建并进入 Swift 静态扫描／Apple 构建矩阵；Android 预构建日志已有 Gradle 实际编译任务。依赖扫描及桌面视觉合同成功。其余任务读取时仍在运行，**完整门禁尚未通过**，后继最终结果另收；不把工具选择步骤的 skipped 与测试跳过混为一谈。

这说明新流程已越过旧候选的三个获取阻滞点；不能据此断言首次上游 HTTP 504 的网络根因已建立或以后不会再有网络故障。真实故障耗尽时仍须失败，源码／故障测试负责验证限次、摘要及清理边界。

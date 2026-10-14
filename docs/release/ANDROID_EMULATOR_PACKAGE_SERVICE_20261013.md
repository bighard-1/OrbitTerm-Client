# Android 15 CI 模拟器包服务异常与恢复门禁（2026-10-13）

## 原始失败（保留）

- 固定提交 `7f5031a` 的 [Security Gates 作业](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/38509529791/job/115674600175)在 Android 15 / x86_64 AOSP ATD 软件模拟器上失败。Linux Client、Windows Client 及其余 Security Gates 常规作业通过；条件 OpenSSH 和已签名 Mac UI 作业跳过。
- 模拟器先报告 `sys.boot_completed=1`，随后测试脚本的包服务预检查通过。约 76 秒后，隔离 Smoke APK 安装返回 `cmd: Can't find service: package`；仪表化测试及 Smoke 状态断言均**尚未开始**。这是模拟器运行时包服务不可用的直接证据，不是客户端用例失败，也不证明后续用例通过。现有 CI 日志没有足够的系统日志解释包服务为何消失，根因暂记为未定。
- Android 包服务消失和签名 macOS UI 缺少 provisioning profile 是两项独立未闭环问题，不能互相覆盖。

## 后继防护

- 工作流在启动模拟器前已执行 `:app:assembleSmoke`。ATD 门禁不再在软件模拟器启动后重复运行 Gradle；缺少预构建 x86_64 APK 时立即失败。
- 安装前继续等待启动标志及 `cmd package list packages` 可用。若 APK 安装时仍收到 `Can't find service: package`，仅在包服务恢复后重试，最多三次安装和两轮各 90 秒等待；长期不可用则明确失败，不标记测试通过。其余安装错误仍原样失败。
- 此修改只涉及 CI/隔离 Smoke 脚本；不修改 Android 客户端、测试账户、线上服务或实体设备。

## 新 CI 的另一项失败（保留）

- 后继提交 `2dd118e` 的 [Android 15 作业](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/38518784894/job/115703474379)已跨过原包服务失败：隔离 Smoke APK 安装成功并启动首个 `locked` 状态，但在 30 次无障碍快照后仍未读到预期文案。最后的层级树显示最上层是系统 `Fake System App isn't responding` 弹窗，测试应用 Activity 位于其后。**夹具断言失败保留**，不能把安装成功写成 Smoke 或仪表化通过。
- 第二次修订只对 `aosp-atd-api35` 隔离 CI 档案生效：无障碍树同时精确匹配该系统弹窗标题和 `android:id/aerr_close` 按钮时，最多关闭两次并继续读取夹具状态；其他标题、真实设备和标准档案绝不自动点击。若弹窗持续出现或仍无预期内容，测试照常失败。

## 验收边界

- 本地先做 Shell 语法、静态扫描和差异检查；必须由后继 CI 的真实模拟器运行确认 Smoke 与连接仪表化结果。
- 本轮无隔离账户 GUI 或实体 Android/Windows 测试。后续两端实体设备仍按总台账对照包身份、安装/升级、离线墓碑与最终删除、SSH 二次验证正反向及录屏边界；模拟器基础设施重试不能代替这些结论。

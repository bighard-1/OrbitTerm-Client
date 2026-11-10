# 2026-10-13 macOS 签名 UI 冒烟通道预检

本记录只评估签名 UI 验收通道是否可以安全执行，不是签名 GUI 通过证据，也不是五端真机放行。基线客户端提交为 `ab277b8`；本轮未改产品功能源码、未生成或安装新客户端候选。日志不包含账户凭据、设备标识或资产地址。

## 审查发现与修订

- 普通 Apple 源码门禁仅对 macOS UI 目标执行无签名 `build-for-testing`；条件式签名 UI 作业在 CI 中按设计 `skipped`。原 opt-in 脚本使用正式版 Bundle ID，直接在当前有正式版/独立 QA 数据的 Mac 上运行存在数据隔离风险，故未运行。
- XcodeGen 规范和检入工程原先把 macOS UI 测试目标 `CODE_SIGNING_ALLOWED` 设为 `NO`。现设为 `YES`，签名通道以 `CODE_SIGNING_ALLOWED=YES` 构建；普通源码门禁仍显式传 `CODE_SIGNING_ALLOWED=NO`，保持原有无签名编译路径。
- 修订后的 opt-in 脚本还要求显式的专用 runner 标记；条件式 CI 作业仅在手动启用时传入该标记。脚本随后检查是否有 OrbitTerm 进程、常见正式版安装位置或正式版数据目录；任一条件不符即拒绝，**不自动删除、退出或迁移用户数据**。通过前置检查后才构建测试宿主，验证严格签名、签名团队和正式版 Bundle ID，再用 `test-without-building` 执行，最后从 `.xcresult` 核对至少 5 条用例全部通过、0 失败/跳过。签名校验发生在启动测试之前。

## 本机验证与未通过结果

| 类型 | 结果 |
| --- | --- |
| 源码/脚本 | `bash -n`、`git diff --check` 通过；XcodeGen 临时生成工程与检入工程均读取到 macOS UI 目标允许签名，Bundle ID 仍为专用测试目标 ID。 |
| 无签名自动化 | `OrbitTermmacOSUITests` 的普通 `build-for-testing` 通过，仅编译，没有运行 5 条 UI 用例。FreeRDP 废弃接口编译警告保留。 |
| 安全前置检查 | 未传专用 runner 标记时拒绝；传入标记后，当前 Mac 因同时存在正式版与独立 QA 应用仍在构建和启动前按预期拒绝。未停止任一应用、未写应用数据。 |
| 签名构建预检 | 脱离脚本，仅做 `build-for-testing`、**不运行测试**；Xcode 报缺少正式版 Bundle ID 对应的 Mac App Development provisioning profile，退出 65。没有传 `-allowProvisioningUpdates`、没有自动生成 profile；失败结果保留。仅该预检产生的约 34 MiB 可重建 DerivedData 已精确清理。 |
| 隔离 GUI/真实设备 | **0 条签名 macOS UI 用例实际执行**；没有新的 Mac/iPhone/Linux/Android/Windows 功能验收。 |

在上述目标设置修订后，另以普通无签名路径执行**完整** `scripts/security/check_apple_release_gates.sh`：退出 0、最终 `[PASS] Apple release gates`，iOS 模拟器 UI 的 `.xcresult` 再次确认 **12/12 通过、0 失败/跳过**。这证明目标设置没有破坏普通 Apple 源码门禁；它没有运行签名 macOS UI 的 5 条用例，也不能覆盖前述 provisioning profile 失败。

## 续验条件

使用专用、无正式版安装及历史数据的 macOS runner，预先配置相符的签名证书和 Mac App Development provisioning profile，再手动启用该条件式通道。须记录最终 app 签名身份、结果包实际用例数及失败/跳过数；只在 **5 条或更多用例全部通过** 后记为签名 GUI 通过。当前机器不应通过关闭正式版、删除其数据或借用用户资料来绕过前置检查。Android/Windows 实机与五端完整验收继续独立开展。

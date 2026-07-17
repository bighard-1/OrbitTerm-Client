# OrbitTerm SSH 状态模型审计

本文件描述仓库当前实现，不把缺失状态推断为已经存在。

## Apple 当前状态模型

主会话模型是 `OrbitTerm/Core/WorkspaceSession.swift`。它没有单一连接状态 enum，而是以下可变字段组合：

- `isConnected: Bool`
- `terminalStatus: String`（中文用户可见状态）
- `baseSessionID`、`terminalChannelID`、`terminalChannelIDs`
- `verifiedSessionLease`（checked SSH 的 Host Key 验证租约）
- `isTelnetSession`、`activeMonitorPanelID`
- 子服务 `sftpManager`、`dockerService`；Monitor 由 `SessionManager.monitorService` 管理。

因此当前状态存在可组合/不完整表示。例如可有 checked `verifiedSessionLease` 但 terminal open 失败；此时 base session 已验证，但 `isConnected == false`。这是一项真实且有价值的安全状态，却无法仅由 Boolean 与字符串稳定表达。

### Checked SSH 实际转换

```text
未连接
  → 正在验证服务器身份...
  → CheckedTerminalConnectionOrchestrator.begin
  → 已连接 / 等待服务器身份确认 / 被阻断 / 认证|网络|超时|信任存储失败 / 已取消
  → 已验证 SSH + terminal open
  → 终端在线（已验证）
  → 连接已断开，点击重连
  → 未连接
```

实现位置：`SessionManager.connectChecked`、`applyCheckedOutcome`、`installCheckedLease`、`handleConnectionLost`、`disconnect`。真实用户文案包括“正在验证服务器身份...”“等待服务器身份确认”“服务器身份已阻断”“认证失败”“网络连接失败”“连接超时”“信任存储失败”“终端在线（已验证）”。

细化到用户要求的模型，当前实现可映射为：

```text
idle (terminalStatus = 未连接)
→ connecting / host-key verification (正在验证服务器身份...)
→ awaiting_host_key_decision (等待服务器身份确认)
→ authenticating (由 Rust checked connect 内部执行；Apple UI 无独立公开状态)
→ connected (verifiedSessionLease + terminal channel)
→ disconnected (connection-lost callback)
→ failed / blocked / cancelled
```

当前仓库未发现 Apple UI 中独立的 `resolving`、`handshaking`、`authenticating`、`reconnecting` enum case。Host Key 验证与认证的底层阶段被聚合进 checked outcome。

### Host Key 信任

- 协调器：`Core/HostKeyTrust/HostKeyTrustCoordinator.swift`。
- presentation：`HostKeyTrustPresentation.swift`。
- unknown：challenge，可取消或信任当前 host；保存成功后重新连接。
- changed/revoked/unsupported：blocked，只有关闭/复制指纹，不允许接受继续。
- store save failure：只允许 retry save/cancel，明确不尝试连接。

### 认证、超时、KeepAlive、重连

- checked FFI error 代码包括 `ssh_auth_failed`、`ssh_connect_failed`、`ssh_timeout`，见 `CheckedFFIError.swift`；UI 映射在 `SessionManager.checkedFailureStatus`。
- `orbitConnectionLost` 通知会把会话改为“连接已断开，点击重连”；当前是**手动重连**，未发现主 SSH 会话自动重连状态或退避策略。
- 当前仓库未发现 SSH KeepAlive 配置模型、心跳间隔设置或用户可见 KeepAlive 状态；断连文案提到“心跳超时”，但该心跳实现不在 Apple UI 的可审计状态模型中。
- Monitor 的 legacy 路径有 `reconnectTasks`、`MonitorPollingPolicy.reconnectBackoffSeconds`（2/5/10/20/30 秒）和 timeout 处理；checked Monitor 使用独立 poller。不能把它误认为主 SSH terminal 的自动重连。

### 子功能状态

| 功能 | 当前状态字段 / 类型 | 说明 |
|---|---|---|
| Terminal | `terminalChannelID`、`terminalChannelIDs`、`terminalSplitCount`、`TerminalService` | checked 模式下安全分屏未启用；终端 open 失败可保留 verified base lease |
| SFTP | `SFTPManager.isConnected/isLoading/statusText/transfers/checkedConnection/checkedError` | 必须从 active verified base session 打开 checked SFTP |
| Monitor | `MonitorPanelState`、poll task、checked binding/poller、failure count | polling、失败和 legacy reconnect 逻辑位于 `MonitorService.swift` |
| Docker | `DockerService.isConnected/isLoading/isScanning/dockerEnvironmentMissing/statusText/checkedError` | checked Docker 支持 list/stats/log/action；rename/update 在公开 checked 路径禁用 |
| Batch | `CheckedBatchCommandService` 的 typed result/error | 仅 verified session；当前 Apple checked 连接完成后明确提示 Batch 仍禁用 |
| Port Forwarding | 当前仓库未发现 Apple/Windows/Android Port Forwarding 实现或状态模型 |

## Windows 当前状态模型

Windows 以 `WorkspaceTabViewModel` 的字符串字段表示 UI 状态：`Status`（默认 Idle）、`SecurityStatus`、`SessionActionSummary`、`MonitorStatus`、`MonitorSummary` 等；核心 typed outcome 在 `Application/Sessions/ConnectResult.cs`、`NativeBridge/CheckedConnectOutcome.cs`、`Application/Security/HostKeyTrustModels.cs`。`SessionOrchestrator`、`VerifiedSessionRegistry`、`TerminalSessionRegistry` 维护会话生命周期。

这比 Apple 更接近分层模型，但仍没有可直接供主题/组件消费的统一 `ConnectionPhase` enum。主题实施前建议为所有客户端采用下方规范，而不是继续依赖英文/中文字符串判定颜色。

## Android 当前状态模型

当前 Android 客户端没有 SSH terminal、Host Key、SFTP、Monitor 或 Docker 页面/会话实现；`MainScreen.kt` 使用硬编码 demo asset，按钮无操作。`OrbitCoreBridge.kt` 只声明 portable encryption/sync/vector clock JNI。故 SSH 状态模型：**当前仓库未发现**。

## 推荐跨端状态契约

```text
ConnectionPhase
  idle
  resolving
  connecting
  handshaking
  awaitingHostKeyDecision
  authenticating
  openingTerminal
  connected
  reconnecting(attempt, nextRetryAt)
  disconnecting
  disconnected(reason)
  blocked(blockReason)
  failed(error, retryable)
  cancelled
```

独立、可组合的附属状态：

```text
HostKeyState: unknownChallenge | trusted | changed | revoked | unsupported | storeFailure
AuthState: notStarted | inProgress | authenticated | failed
KeepAliveState: disabled | healthy(lastAck) | delayed | timedOut
ChannelState: unavailable | opening | open | closing | closed | failed
```

主题组件只读取 `ConnectionPhase` 与安全状态，不读取 `terminalStatus` 文案。`connectionConnected`、`connectionConnecting`、`connectionReconnecting`、`connectionDisconnected`、`connectionBlocked` 必须直接映射 phase；Host Key changed/revoked 一律映射 `connectionBlocked` + `danger`，不可映射为装饰 accent。

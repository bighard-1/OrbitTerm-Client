# OrbitTerm Windows / iOS / macOS / Android 行为对齐矩阵

更新时间：2026-08-21  
范围：以安全语义、远端数据变化和用户可恢复结果为准；不要求复制平台控件、窗口或像素布局。  
状态：`已对齐`、`有意差异`、`待完成`。

## 使用方式

- **已对齐**：三端的安全前提、数据变化和失败恢复结果一致，并至少有源码或自动化证据。
- **有意差异**：平台能力不同，但差异不改变安全语义或远端结果；必须说明原因。
- **待完成**：不得在发布说明中称作三端一致；完成时必须更新本矩阵、对应自动化测试与真机记录。
- 详细 Android/iOS 项目追踪保留在
  [ANDROID_IOS_BEHAVIOR_ALIGNMENT_MATRIX.md](ANDROID_IOS_BEHAVIOR_ALIGNMENT_MATRIX.md)；本文件是三端发布审查的单一总览。

## 矩阵

| 域 | 操作结果 / 安全语义 | iOS | macOS | Android | 状态 | 证据与负责人 | 验收条件 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 认证 | 登录、注册、邀请码校验后才建立加密账户会话 | AuthView | AuthView | AuthViewModel / LoginScreen | 已对齐 | Apple + Android | 不显示密码或令牌；错误可恢复且不跨账户泄漏。 |
| 主密码 | 登录密码变更与主密码轮换分离；锁定、登出、换账号清除内存密钥 | AccountSecurityView / MasterPasswordGateView | AccountSecurityView / MasterPasswordGateView | MasterPasswordViewModel | 已对齐 | Apple + Android | 生物识别仅解锁；失败或中断不建立可信会话。 |
| Host Key | unknown 必须确认；changed、revoked、unsupported 必须阻断 | HostKeyTrust | HostKeyTrust | CheckedSshNativeClient | 已对齐 | 安全 | 无绕过路径；指纹可访问但不泄露其他凭据。 |
| 跳板机 | 跳板与最终目标分别验证，工具服务仅复用最终已验证会话 | JumpHostConfiguration | JumpHostConfiguration | PortableJumpHostConfig | 已对齐 | Apple + Android | 跳板失败、Host Key 阻断或取消时不创建终端、SFTP、Docker 或监控会话。 |
| 资产生命周期 | 批量导入、保存前连接测试、最近删除恢复与永久清理 | AssetBulkAddSheet / RecentlyDeletedView | 同 iOS | AssetBulkImportParser / RecentlyDeletedViewModel | 已对齐 | Apple + Android | 导入有大小/数量/重复限制且不回显秘密；测试会话不持久化；恢复校验密文身份；永久删除二次确认。 |
| Telnet | 仅在显式风险确认后使用，且不伪装成已验证 SSH | TelnetAccessPolicy | TelnetAccessPolicy | 仅兼容同步保存，禁止创建和连接 | 有意差异 | 产品 / 安全 + Android | Android 明确不支持 Telnet；导入记录不被销毁，但必须 fail-closed，未来支持前需独立风险确认与测试。 |
| RDP 远程桌面 | `rdp` 资产使用同一 E2EE 资产信封、账户隔离、冲突合并和删除墓碑；未接入引擎的平台保留资产但绝不回退为 SSH | 保存并同步，原生工作区待 FreeRDP 阶段 | 保存并同步，原生工作区待 FreeRDP 阶段 | 保存并同步，原生工作区待 FreeRDP 阶段 | 分阶段对齐 | Windows RDP Host + ADR-037 | Windows/Linux 可作为图形目标；macOS 图形目标不在首期范围。四端往返同步不得丢凭据、改协议或复活墓碑。 |
| 会话 | 多会话切换、关闭、重连及迟到回调只能作用于原会话 | SessionManager | SessionManager | TerminalSessionController / OperationScopeCoordinator | 已对齐 | Apple + Android | 锁定、登出、换账号、关闭会话后，旧回调不能复活 UI 或 native handle。 |
| 终端 | 输入、ANSI 输出、复制粘贴、清屏、滚动历史与快捷键均由用户显式触发 | SwiftTermTerminalView | SwiftTermTerminalView | RemoteTerminalCanvasView | 已对齐 | Apple + Android | 应用主题不改变 ANSI palette；敏感剪贴板按统一策略清理。 |
| 终端布局 | 移动端单终端视图；桌面端可分屏 | macOS 支持会话分屏 | iOS 单窗会话切换，不提供分屏入口 | Android 单窗标签式会话，不提供分屏入口 | 已对齐 | 产品 | 移动端统一移除终端分屏；macOS/Windows 工作站继续保留独立 PTY 分屏。 |
| SFTP 浏览 | 仅经 checked SSH 进入目录，路径、应用内预览/编辑、冲突保护与危险删除保持受控 | SFTPBrowserView | SFTPBrowserView | SftpRoute / SftpInAppDocumentPolicy / CheckedSftpNativeClient | 已对齐 | Apple + Android | 移动端 UTF-8 文本先预览后编辑且硬限制 2 MB；保存冲突保留本地草稿；递归删除有显式确认和上限。 |
| SFTP 批处理 | 上传、下载、取消、进度、失败恢复与队列限额 | SFTPManager transfers | SFTPManager transfers | SftpRoute / transfer queue | 已对齐 | Apple + Android | 取消不误删后续任务；网络切换与前后台的真机证据必须留档。 |
| SFTP 多选 | 多个文件/目录的统一下载或分享 | 支持 | 支持 | 多选 ZIP、SAF 保存与系统分享 | 已对齐 | Android | 多选项目统一进入 checked FIFO 队列；分享使用短期 FileProvider URI，不绕过取消或 checked SFTP 语义。 |
| Docker | 已验证会话上的列表、日志、操作、刷新和会话切换取消 | DockerService | DockerService | CheckedDockerNativeClient | 已对齐 | Apple + Android | 删除/强制停止二次确认；操作不可重复提交；旧日志不可显示于新会话。 |
| Monitor | 绑定当前会话的采样、历史、暂停、资源预算和错误恢复 | MonitorService | MonitorService | CheckedMonitorNativeClient | 已对齐 | Apple + Android | 切换会话/锁定后停止旧采样；图表不影响应用主题或业务阈值。 |
| 同步 | 资产、跳板、片段加密同步，账户隔离与冲突选择 | SyncService | SyncService | SyncRepository / WorkManager | 已对齐 | Apple + Android | 旧账户任务不可写入新账户；冲突明确给出保留本地或云端的可执行动作。 |
| 同步删除 | 活动清单、回收站分页与本地待发队列按规范化 `asset_id` 合并，墓碑优先但不覆盖本机待发布编辑 | SyncService / SyncPullRecoveryPolicy | 同 iOS | SyncRepository / RemoteTombstoneMergePolicy | 待完成 | Apple + Android + Windows | 三端代码级回归已通过；仍需 Windows、macOS、iOS、Android 真机执行任一端删除、重复双向同步、离线重连及删除后编辑矩阵，确认不复活后才关闭 TD-20260804。 |
| 独立 SSH 密钥库 | 与资产内嵌凭据分离的可复用密钥，采用 `orbit_ssh_keys` v1 端到端加密信封、墓碑和账户作用域 | Keychain 密钥库、拉取合并、墓碑、资产分配恢复与移动管理入口 | 同 iOS，macOS 额外提供生成和批量部署 | Keystore 密钥库、拉取合并、墓碑、资产认证恢复与移动管理入口 | 已对齐 | 安全 + 全平台 | 不同步本机专用密钥；同步密钥只在解锁后进入 Keychain/Keystore/DPAPI；私钥和口令不得进入普通设置、日志或诊断。Linux 后续使用同一信封并接入 Secret Service/KWallet 适配器。 |
| 端口映射配置 | `orbit_port_forwards` v1 仅同步用户保存的映射配置；活动 tunnel ID、监听句柄、进程与运行状态永不跨端 | Keychain 保存、E2EE 合并、墓碑和移动管理入口 | 同 iOS，macOS 带桌面宽布局 | Keystore 保存、E2EE 合并、墓碑和移动管理入口 | 已对齐 | 桌面 + 移动端 | 运行态字段仍被契约拒绝；移动端只在前台和已验证 SSH 会话上启动本地映射；Linux 后续复用契约和安全存储接口。 |
| 后台策略 | 后台、锁屏、窗口关闭后的连接与恢复 | 受 iOS 生命周期限制 | 以窗口/会话策略为准 | 前台服务与通知 | 有意差异 | 平台 | 不承诺系统不支持的持续 SSH；界面在线状态必须与 native handle 一致。 |
| 剪贴板与诊断 | 凭据/私钥不自动复制；导出和日志默认脱敏 | SecureClipboard / DiagnosticsPrivacy | SecureClipboard / DiagnosticsPrivacy | TerminalClipboard / privacy metrics | 已对齐 | 安全 | 不保留用户后来复制的新内容；诊断不含主机、路径、命令、终端输出、私钥或令牌。 |
| 无障碍 | 安全状态不只依赖颜色，关键控件有文本和语义 | XCUITest accessibility assertions | XCUITest compile + signed smoke | Compose semantics / P2AccessibilityLayoutRegressionTest | 已对齐 | Apple + Android | 自动化覆盖根状态、状态 badge 与危险确认；TalkBack、VoiceOver、键盘与大字号仍需真机验收。 |
| 视觉回归 | 主题与危险/空态的固定、无数据基线 | XCUITest root states | signed macOS UI smoke | OrbitDesignScreenshotBaselineTest | 有意差异 | 平台 | 各平台采用原生稳定手段；不得把截图基线用于包含账户、服务器、终端或网络数据的页面。 |
| 发布证据 | 声明支持的平台均有构建和门禁证据 | Apple release gates | Apple release gates + signed lane | Android protected release gates | 待完成 | 发布 | macOS 签名 smoke、iPhoneOS 真机 UI、Android 真机 SFTP/无障碍证据仍由受控发布环境提供。 |

## P2 关闭项

1. 在 iOS、macOS、Android 实机上完成 VoiceOver/TalkBack、大字号、键盘/硬件键、横屏/窗口行为的验收记录。
2. 将签名 macOS UI smoke、iPhoneOS 真机 UI 与 Android 真机传输验收附到对应发布候选版本。

## Windows 客户端补充矩阵（P3 / P4）

Windows 保持原生 WinUI 交互，不复制 Apple 的窗口控件；下列项目与既有 Apple / Android 行为契约对齐。

| 域 | Windows 实现 | 当前状态 | 自动化 / 实机证据 | 后续验收 |
| --- | --- | --- | --- | --- |
| SSH 终端 | NativeTerminalView + 受验证 PTY 会话 | 已对齐 | 2026-08-05：真实 SSH 验证 ANSI 色彩、中文、emoji 与交互输入；TerminalScreen 测试覆盖宽字符、历史和 256 色；2026-08-08：Windows 三栏、终端与工具区在当前实机 DPI 验收未发现问题 | 多显示器与辅助技术正式发布前复验。 |
| 终端输入与复制 | 直接在终端画布输入；Ctrl+Shift+C 与右键复制；受控粘贴 | 已对齐 | NativeTerminalView 键盘、选择和剪贴板实现；P3 / P5 实机验证 | 特殊键在更多 Shell（bash/zsh/pwsh）验证。 |
| 快捷指令 | DPAPI 本地持久化、分类搜索、变量填写、插入/发送/复用至批量命令 | 部分完成 | `SnippetsPersistAndReuseExistingTerminalAndBatchInputs`、`SnippetVariablesAndGroupedSearchRemainGuarded`；2026-08-08：未分类文案与 Apple 对齐 | **待完成：**加密云端同步、资产范围限制、从终端历史一键保存；这些能力在 Apple 已有，Windows 尚未声称对齐。 |
| 批量命令 | 多个用户勾选的已验证 SSH 会话、单条受限命令、逐资产结果、按工作区隔离结果、64 KiB 输出上限与脱敏失败提示 | 部分完成 | `BatchCommandRequiresVerifiedSessionAndKeepsPerTabResult`、`BatchCommandBoundsLargeOutputBeforePublishingItToTheWorkspace`、`BatchCommandExecutesOnceForEachExplicitlySelectedVerifiedWorkspace` | **待完成：**按资产分组的一键勾选、可中止的执行队列与超时回执；Apple 的并发调度模型是 Windows 后续优化基准。 |
| 监控 | 已验证 SSH 会话上的快照、六项摘要、1 秒自动刷新、暂停/恢复、30 秒/5 分钟/10 分钟趋势范围与失败态脱敏提示 | 已对齐 | MonitorSnapshotRefreshRequiresVerifiedSessionAndShowsBoundedSummary；MonitorHistoryIsWorkspaceScopedAndClearedWhenTheSessionEnds；MonitorFailureIsActionableWithoutShowingProtocolCodes | 继续做 Windows 高 DPI 与窗口失活/恢复的手工验收。 |

## 维护规则

- 新增跨端功能时，合并前必须更新本矩阵并写明证据、负责人和验收条件。
- 任何无法解释的平台差异均应记为 `待完成`，不能标成 `有意差异`。
- 本矩阵只描述行为契约；平台导航、菜单、窗口与输入法应保持原生。

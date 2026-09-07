# Linux 离线同步故障注入矩阵

该矩阵不连接正式服务，也不需要账户凭据。测试只使用临时目录、回环 HTTP 服务和明确关闭的本机端口，用于验证离线队列在真实账户集成测试前具备可重复的故障边界。

| ID | 故障或重放条件 | 必须满足的结果 | 自动测试 |
|---|---|---|---|
| F01 | 入队后销毁并重新创建仓储实例 | 操作、尝试次数、失败原因和下次重试时间均恢复；文件不含主密码、令牌或明文凭据字段 | `queue_recovers_after_reopen_without_persisting_auth_or_plaintext_secrets` |
| F02 | 操作文件版本或结构非法 | 拒绝读取且不覆盖原文件 | `malformed_persistent_queue_fails_closed_without_overwrite` |
| F03 | 操作文件路径被替换为符号链接 | 以 `SymlinkRefused` 阻断，不跟随目标 | `persistent_queue_refuses_symbolic_links` |
| F04 | 同一持久化上传负载重放两次 | 两次 HTTP JSON body 字节完全一致，资产 UUID、密文和向量时钟不漂移 | `queued_upload_replay_sends_the_exact_same_idempotent_body` |
| F05 | 服务端连续三次返回 HTTP 503 | 客户端只做有限重试，最终返回可入队的 `ServerRetryable(503)` | `server_5xx_is_bounded_and_classified_for_queue_retry` |
| F06 | TCP 连接被拒绝 | 有限重试后归类为可入队网络错误 | `refused_connection_is_classified_for_queue_retry` |
| F07 | 访问令牌返回 401，刷新令牌有效 | 只刷新一次并使用新访问令牌重试原请求 | `refreshes_once_after_unauthorized_then_retries_pull` |
| F08 | 拉取记录对应资产仍有排队操作 | 不解密或覆盖该资产，保持未解决状态并阻止游标确认 | `queued_asset_stays_deferred_without_decrypting_or_advancing` |
| F09 | 启动/网络恢复/定时器同时唤醒，或用户打开同步中心 | 后台执行保持单飞；同步中心打开期间不启动后台执行器，关闭后恢复调度 | `background_work_is_single_flight`、`open_dialog_suppresses_background_work_until_closed` |
| F10 | 主密码会话超时、账户切换、显式锁定与重复问题通知 | 旧账户不能读取新账户解锁；30 分钟到期和锁定清除内存引用；相同修订的问题通知只发送一次，健康恢复后允许再次提醒 | `account_switch_replaces_the_in_memory_unlock`、`unlock_expires_and_explicit_lock_clears_account_scope`、`notification_keys_are_deduplicated_until_health_recovers` |
| F11 | 首次增量拉取包含已永久清理的 `purged` 墓碑 | 本机无该资产时把墓碑视为已满足并允许确认游标；本机仍有副本时只允许明确接受删除，不提供无效的恢复动作 | `purged_tombstone_is_satisfied_only_when_local_asset_is_absent` |
| F12 | 增量拉取包含 Apple/Windows 写入的无资产 UUID 辅助文档 | 仅当 OTC1/OTC2 解密成功、元数据合法且 `kind`、版本、集合结构符合已知跨端协议时安全跳过；未知或损坏记录继续阻断游标 | `recognizes_known_account_scoped_auxiliary_records_without_blocking_assets`、`malformed_or_unknown_unbound_records_remain_fail_closed` |

执行入口：

```bash
clients/linux/scripts/run_sync_fault_matrix.sh
```

脚本仅在全部测试通过后生成权限为 `0600` 的脱敏证据文件。证据包含 UTC 时间、平台、Rust 版本、相关源文件 SHA-256 和 F01–F12 状态，不包含环境变量值、账户标识、令牌、密文或资产数据。

该矩阵通过不能代替 [`CROSS-PLATFORM-SYNC-MATRIX.md`](CROSS-PLATFORM-SYNC-MATRIX.md) 中的真实 Apple/Linux/Windows 验证。未配置隔离账户时，真实账户状态必须继续标记为 `NOT_RUN`。

# 真机验收与发布证据协议

更新时间：2026-10-05
状态：P0 验收协议；当前尚未通过，不得替代真实设备结果。

## 证据边界

所有 P0 证据保存到受限发布证据库，不提交到应用仓库。每份记录必须包含构建提交、平台、场景和运行编号；不得包含账号、主机、端点、路径、命令、终端输出、凭据、令牌、私钥或设备 UDID。

机器可读范围以 `DESKTOP_STABILIZATION_GATE.json` 为准。该文件声明了墓碑与并发阻断项必须覆盖的场景；脚本只校验证据结构和阈值，不能替代人工观察或设备执行。

每次真机执行前先运行预检。预检只输出就绪状态，不输出设备名、UDID 或账号；两个确认参数仅表示操作员已确认使用非生产测试账户和可删除测试资产，不能传入任何秘密：

```zsh
scripts/performance/preflight_real_device_acceptance.sh \
  --scope tombstones \
  --platform macos \
  --test-account-confirmed \
  --test-assets-confirmed
```

## P0-1：跨端删除墓碑矩阵

在同一受控测试账户、五个实际客户端（Windows、macOS、iOS、Android、Linux）上依次完成以下场景。各端分别指定 `--platform` 运行预检；每一步记录“活动列表、最近删除、本机凭据移除、重复同步结果”四个布尔结论，以及构建提交和运行时间；不要记录资产名称或地址。Linux 的墓碑冲突需明确选择“接受删除”，不得把尚待人工处理的状态记为通过。

| 场景 | 最小步骤 | 通过条件 |
| --- | --- | --- |
| `delete_then_pull` | 任一端删除，其他四端双向同步或完成明确的墓碑冲突处理 | 五端活动列表都移除；回收站恰有一条；所有本机凭据已移除 |
| `delete_after_edit` | 一端编辑后，另一端删除，再同步 | 不会把编辑副本重新写入活动列表；出现可恢复的冲突或删除结果 |
| `offline_delete_then_reconnect` | 离线端删除后恢复网络 | 删除队列可重试并最终收敛；没有重复回收站记录 |
| `repeat_sync_no_resurrection` | 五端各连续执行三次同步 | 已删除资产不会复活；回收站记录不重复 |

任何失败均保持 `cross-platform-asset-tombstones` 为 `in-progress`，附上脱敏的失败分类和复现步骤后再修复；不得将一次成功外推为五端强一致。

## P0-2：大传输与交互并发

在 Windows 10、Windows 11、macOS 各跑连续三次相同场景：三台资产、每台两个终端分屏、六路良性持续输出、其中一台执行 3 GiB 上传或下载，并启用监控。每次至少 15 分钟。

在每个桌面测试主机上先运行：

```zsh
scripts/performance/preflight_real_device_acceptance.sh \
  --scope concurrency \
  --platform macos \
  --test-account-confirmed \
  --test-assets-confirmed
```

每次运行保存一份脱敏 JSON，再用以下命令验证：

```zsh
python3 scripts/performance/verify_desktop_concurrency_evidence.py /restricted/evidence/desktop-concurrency/*.json
```

JSON 只允许数值指标，示例字段如下：

```json
{
  "schema_version": 1,
  "kind": "desktop-concurrency",
  "build_commit": "0123456789abcdef",
  "platform": "macos",
  "scenario": "three-assets-six-panes-3-gib-transfer",
  "run": 1,
  "duration_seconds": 900,
  "max_click_response_ms": 0,
  "max_session_switch_ms": 0,
  "blank_pane_count": 0,
  "stale_monitor_intervals": 0,
  "max_ui_progress_updates_per_second": 0,
  "canceling_state_ms": 0,
  "memory_start_bytes": 0,
  "memory_end_bytes": 0,
  "late_window_throughput_ratio": 0.85
}
```

验收阈值：点击不超过 250 ms、会话切换不超过 500 ms、空白窗格和陈旧监控为零、UI 进度更新每秒不超过 8 次、取消在 1 秒内进入取消中、15 分钟内内存增长不超过 64 MiB，且最后 4 分钟吞吐不少于最佳稳定 60 秒中位值的 70%。任何超标都不允许把 P0-2 标为完成。

## 归档与关闭

发布负责人核对九份并发记录、完整五端墓碑矩阵、构建 SHA、签名/公证/安装证据后，才可把门禁、技术债和发布清单同时更新为 `complete`。没有证据时应明确写为“未验证”，而非“无已知问题”。

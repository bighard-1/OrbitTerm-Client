# OrbitTerm 跨 Apple / Windows / Linux 真实账户同步验证矩阵

## 当前执行状态

2026-08-25 已使用用户明确指定的隔离账户完成真实登录、历史数据清理和矩阵夹具创建。5 条旧资产及 1 条无 UUID 遗留记录已清理；增量历史按设计保留 5 条 `purged` 防复活墓碑。Apple 客户端已创建并成功上传两条专用资产，Linux 已从正式服务端回读、解密并导入两条活动资产。

版本复核发现，上述 M01–M05 执行时使用的仓库检出点为 `fbb75c1`，而远端主线已经推进到 `ab7fec695a673a70b06d4489ba4150fea5a1d104`。因此 M01–M05 只保留为历史协议证据，不得再作为当前主线的发布验收结论；M01–M15 均须在以下当前主线构建上重新执行。

当前 macOS 基线为签名 Release 构建 `/tmp/orbitterm-main-ab7fec6-derived/Build/Products/Release/OrbitTerm.app`，二进制 SHA-256 为 `831183b3a2eb035c633c0866aa6ced883170c6fdc0300f7cf096ac15f271acfc`。当前 Linux 基线为 Flatpak 提交 `46371bd06bf7590405fa801471eea5c6a6a7c3095bdadef5dcc434fdee690866`，bundle SHA-256 为 `0026b48749a47f9f36d25ce62c6bcd850d033c61566635fee6899eee43f997d1`，构建、安装与运行中二进制 SHA-256 均为 `8bdc019c1e58b13473b122d87057717a1025e1f6ee190fa166c6d25f1718eac6`。Linux 全量门禁 59 项通过，F01–F12 隔离故障矩阵通过。

Ubuntu 图形会话未包含用户 Flatpak export 路径的问题已由 `scripts/install_flatpak.sh` 补偿：安装器会同时写入标准用户应用菜单启动器、图标缓存及可信桌面快捷方式。当前工作台标题栏不再显示旧版“大 Logo + 品牌名称”区块，左侧提供“添加服务器”“编辑凭据”，右侧明确提供“同步”“登录 / 解锁”；账户窗口标题为“账户与同步”。

当前主线真实账户只读重跑已完成：Apple 最新主线把两条固定资产迁移为账户作用域 OTC2 密文，远端修订分别为 735、736；Linux 当前主线均可解密为同一固定 UUID。远端编号 43、修订 737 的无资产 UUID 记录经解密确认是合法 `orbit_port_forwards` v1 辅助文档，并非脏资产；Linux 会在验证密文、元数据、协议标记、版本与集合结构后安全跳过，未知或损坏的无 UUID 记录仍失败关闭。只读清单结果为 2 条可解密资产、1 条已识别辅助文档、0 条不受支持记录，未执行删除、上传或游标确认。M02–M15 的当前主线真实变更场景仍需继续执行。

历史 M01–M05 的真实修订链为：固定夹具创建 726/727，Linux“保留本机”728，Apple 并发字段修改 729，首次删除 730，重建夹具恢复 731，第二次删除 732，Linux“恢复云端”733。历史执行结束时 Linux 游标为 733，两个固定 UUID 均保持不变，Apple 最终清单与 Linux/云端一致为 2 条活动资产。

服务端仓库 `bighard-1/OrbitTerm-Master` 的 `main` 分支提交 `e2ea199e5eb799516ae816a3d5dbf226ade9caf6` 已完成只读核验：资产变更请求明确要求 `vector_clock` 为包含 JSON 的字符串，与 Apple/Linux 客户端模型一致。早期清理探针的失败源于临时命令把该字符串重复 JSON 编码，并非服务端契约缺陷；改用单层字符串后全部清理成功，因此本次不修改、不构建也不发布服务端镜像。

真实增量拉取还证明服务端会为已永久清理资产保留 `purged` 事件。Linux 已将该状态纳入终止墓碑：本机无对应资产时安全满足并允许游标确认；本机仍有副本时阻止游标并只允许“接受删除”，不得提供无法成功的“恢复云端”。

Windows 客户端当前只有 portable 加密辅助能力，没有接入云端认证、增量拉取、冲突解决或离线队列。涉及 Windows 的同步用例状态为 `BLOCKED — CLIENT CAPABILITY MISSING`，不是失败，也不是通过；在该能力实现前不得发布“三端同步已验证”的结论。

## 专用账户与固定夹具

必须使用与个人/生产数据隔离的 OrbitTerm 测试账户。账户仅包含一个活动 SSH 资产和测试墓碑，主密码不得复用生产密码。固定活动资产 UUID 写入 `ORBITTERM_TEST_ASSET_ID`，各端都必须保留同一 UUID，不得通过复制生成新资产绕过冲突。

当前固定夹具：

| 用途 | 名称 | UUID | 创建后远端修订 |
|---|---|---|---:|
| 主活动资产 | `Sync-Matrix-Primary` | `9828bfd9-1443-4a3a-ad29-d3ef195aa436` | 726 |
| 删除/恢复资产 | `Sync-Matrix-Tombstone` | `80b63db6-59d9-4fac-abcd-840c28b9a9d5` | 727 |

2026-08-25 当前主线证据：Linux 清单审计 `live-inventory-audit-20260825T061823Z.txt`（SHA-256 `d240b230278ae16fc1472ca44ffe6cc90334ab9f1c1911ffb11f40018a248fd3`），主活动资产预检 `live-sync-preflight-20260825T060706Z.txt`（SHA-256 `207786d156517058992d31dbf6d18d3d11cde15bec87a181cd1cec920a1cc9d0`），删除/恢复资产预检 `live-sync-preflight-20260825T060731Z.txt`（SHA-256 `ecc01f301d755ee865afe88b6bb09a2c8fa03c50ecbbc19abade32df5015d471`），F01–F12 故障矩阵 `linux-sync-fault-matrix-20260825T062113Z.txt`（SHA-256 `97023bcff5243acec12e628d198dd3d7f693b1a42c01520918e16ea85d463553`）；文件权限均须保持 `0600`。较早的 `030526Z`、`030703Z` 与 `042807Z` 证据只作为历史版本记录，不用于当前主线放行。

Linux 在线预检通过环境变量注入秘密，脚本不会打印变量内容：

```bash
export ORBITTERM_SYNC_MATRIX_SCOPE=isolated-test-account
export ORBITTERM_TEST_USERNAME='...'
export ORBITTERM_TEST_PASSWORD='...'
export ORBITTERM_TEST_MASTER_PASSWORD='...'
export ORBITTERM_TEST_ASSET_ID='00000000-0000-0000-0000-000000000000'
clients/linux/scripts/run_live_sync_matrix.sh
```

当账户尚未建立固定夹具或需要调查历史清单时，使用只读审计入口；它不要求资产 UUID，也不会上传、删除或确认游标：

```bash
clients/linux/scripts/run_live_inventory_audit.sh
```

该自动入口只执行登录、增量/兼容拉取、JWT 账户隔离和 portable 解密预检，不修改云端。会改变云端或本地状态的场景必须在受控桌面会话中按下表人工执行。

## 证据规范

每一步记录：UTC 时间、客户端与版本/提交、平台版本、账户指纹后 6 字符、资产 UUID、动作前后 `server_revision`、向量时钟、远端状态、离线队列 ID、尝试次数和结果。截图不得出现账户密码、主密码、访问/刷新令牌、私钥正文或资产密码。

通过条件同时包括：字段值正确、UUID 不变、服务端修订单调递增、向量时钟合法、删除/恢复状态正确、操作重放不产生第二条资产、游标不越过未解决冲突。仅看到 UI 提示不算通过。

## 集成矩阵

| ID | 起点与操作 | Apple 观察 | Linux 观察 | Windows 观察 | 当前状态 |
|---|---|---|---|---|---|
| M01 | Apple 创建固定 UUID 活动资产并同步 | 上传成功，记录修订与向量时钟 | 登录、拉取、解密并导入；UUID/字段/凭据一致 | 同账户拉取并导入 | CURRENT-MAIN PREFLIGHT PASS — 两条 OTC2 固定资产只读拉取/解密通过，UI 持久化导入仍需重跑；Windows blocked |
| M02 | Linux 修改字段，冲突中心选择“保留本机” | 收到同 UUID 的新修订和字段 | 上传前落盘；完成后队列清除、时间线保留 | 收到同 UUID 新修订 | HISTORICAL PASS — 当前主线需重跑；Windows blocked |
| M03 | Apple 与 Linux 分别修改同 UUID，Linux 拉取 | 保留 Apple 侧修订证据 | 显示逐字段差异；“采用云端”后本机及 Secret Service 一致 | 能做同等明确冲突选择 | HISTORICAL PASS — 当前主线需重跑；Windows blocked |
| M04 | Apple 删除固定资产，Linux 尚保留副本 | 云端产生墓碑 | “接受删除”清除本机资产和凭据并记录审计 | 收到墓碑并显式接受 | HISTORICAL PASS — 当前主线需重跑；Windows blocked |
| M05 | 重建 M04，Linux 选择“恢复云端” | 拉取看到 active 和更高修订 | 请求含稳定 operation UUID；记录远端修订 | 收到恢复后的活动资产 | HISTORICAL PASS — 当前主线需重跑；Windows blocked |
| M06 | Linux 断网后选择“保留本机” | 断网期不改变 | 密文上传持久化；显示失败原因、时间、尝试数与下次重试 | 无变化 | Linux 待执行；Windows 不参与 |
| M07 | M06 保持断网，重启 Linux | 无变化 | 队列仍存在；主密码和明文凭据不在队列；游标不推进 | 无变化 | Linux 待执行 |
| M08 | M06 恢复网络并连续点“立即重试” | 只有一个同 UUID 修订链 | 请求哈希去重；成功后队列清除，审计保留 | 收到单一最终状态 | Apple/Linux 待执行；Windows blocked |
| M09 | 恢复墓碑时断网、重启、自动重试 | 最终只恢复一次 | 稳定 operation UUID；按 10/30/120/300/600/900/1800 秒退避 | 收到单一恢复结果 | Apple/Linux 待执行；Windows blocked |
| M10 | 令牌过期且有 refresh token，队列到期 | 无重复写入 | 401 刷新后用同一负载重试；令牌回写 Secret Service | 等价行为 | Apple/Linux 待执行；Windows blocked |
| M11 | 服务端连续 5xx 后恢复 | 无重复写入 | 有限网络重试后持久化失败；手动重试可恢复 | 等价行为 | Apple/Linux 待执行；Windows blocked |
| M12 | 两个测试账户各有同一资产 UUID | 各账户互不可见 | 队列、审计、游标和逐资产修订按 JWT `uid` 指纹隔离 | 各账户互不可见 | Apple/Linux 待执行；Windows blocked |
| M13 | Linux 解锁同步会话，Apple 修改非冲突资产 | Apple 产生更高修订 | 30 秒内后台拉取、安全写入凭据并确认游标；侧栏显示健康修订 | 收到同一最终状态 | Apple/Linux 待执行；Windows blocked |
| M14 | Apple/Linux 同时修改固定 UUID，Linux 后台拉取 | Apple 保留其修订证据 | 不覆盖、不确认游标；发送一次桌面通知，点击进入完整字段冲突中心 | 能看到最终明确选择 | Apple/Linux 待执行；Windows blocked |
| M15 | Linux 锁定、退出并切换到第二隔离账户 | 原账户云端不改变 | 主密码内存清除；本机访问/刷新令牌清除；第二账户队列、游标和通知不读取第一账户状态 | 两账户继续隔离 | Apple/Linux 待执行；Windows blocked；服务端远端 revoke 接口缺失 |

## 阶段放行门槛

1. Linux 只读在线预检通过，并保存不含秘密的测试输出。
2. M01–M15 的 Apple/Linux 适用项全部有真实证据；M06–M11、M13–M15 至少重复三轮。
3. 检查 `$XDG_STATE_HOME/OrbitTerm/sync/operations.json` 权限为 `0600`，内容不含主密码、令牌、明文密码或私钥；允许包含端到端加密密文。
4. Windows 补齐能力前，发布说明只能声明 Apple/Linux 集成验证范围。
5. 测试结束后撤销测试账户令牌、轮换测试密码并归档脱敏证据。

当前正式 API 只提供登录与刷新，`/api/v1/auth/logout` 和 `/api/v1/auth/revoke` 未形成可用契约。M15 现阶段只能验证本机 Secret Service 令牌撤销；远端撤销必须等待服务端提供正式端点后再标记通过。

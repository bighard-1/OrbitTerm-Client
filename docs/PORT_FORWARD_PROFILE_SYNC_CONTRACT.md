# 端口映射保存配置同步契约

## 范围

- 信封标识：`orbit_port_forwards`
- 当前版本：`1`
- 只同步用户明确保存的端口映射配置，不同步运行状态。
- Windows 与 macOS 可在用户主动操作后启动映射；iOS/Android 只兼容保存和展示配置，不因同步自动建立后台隧道。

## 信封

```json
{
  "kind": "orbit_port_forwards",
  "version": 1,
  "updatedAtUnix": 1770000000,
  "profiles": [],
  "tombstones": []
}
```

每个 `profiles` 项仅包含：

- `id`、`assetId`
- `name`
- `mode`：`local`、`remote` 或 `dynamicSocks5`
- `bindHost`、`bindPort`
- `destinationHost`、`destinationPort`
- `createdAtUnix`、`updatedAtUnix`

删除使用 `tombstones` 中的 `id`、`deletedAtUnix` 表示。

## 明确禁止同步

- native tunnel ID、进程 ID、监听句柄或 socket
- `isRunning` 等运行状态
- 自动启动或“连接后自动恢复”偏好
- 已验证 SSH 会话 ID、Host Key 状态或任何凭据

接收到上述字段时，客户端必须拒绝该信封；接收到合法配置也不得自动建立隧道。

## 限制

- 每个信封最多 256 条配置、1,024 条墓碑。
- 每项资产最多 32 条配置。
- 监听端口为 `0...65535`，其中 `0` 仅表示启动时由本机动态分配。
- 非 SOCKS5 配置的目标端口为 `1...65535`。
- 非回环监听仍须在每台桌面设备上单独进行风险确认。

## 当前接入状态

- Windows 使用当前用户 DPAPI 配置库；Apple 使用按账户隔离的 Data Protection Keychain；Android 使用 Android Keystore AES-GCM 配置库。
- 三端均已接入 E2EE 下载合并、上传、删除墓碑和账户隔离；Android 只保存及合并，不启动隧道。
- Windows 与 macOS 端口映射界面已接入保存配置、启动保存配置和删除配置。
- Android 资产同步识别该信封为辅助配置，不会将其误报为资产解密失败。

## 合并规则

1. 规范化 UUID 是跨端逻辑身份。
2. 活跃副本以 `updatedAtUnix` 较新者为准。
3. `deletedAtUnix >= updatedAtUnix` 时墓碑胜出。
4. 晚于墓碑的显式重新创建可以恢复同一配置。
5. 新设备的空配置库不推断为删除，只有显式删除才生成墓碑。
6. “仅本机”配置不进入 E2EE 信封；与同步 UUID 冲突时保留本机配置并报告冲突。

## Linux 预留

共享信封、校验和合并规则不依赖操作系统。Linux 客户端实现与
`IPortForwardProfileVault` 等价的适配器即可接入，推荐使用 Secret Service
（`org.freedesktop.secrets` / libsecret）。系统没有安全存储服务时必须禁用持久化的
同步配置，不得静默回退为明文文件。Linux 同样不得从云端恢复运行态或自动启动隧道。

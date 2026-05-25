# OrbitTerm Portable Sync Protocol v1

本文档是 OrbitTerm 四端同步的冻结契约。macOS、iOS、Windows、Android 必须按本协议生成、加密、上传、拉取、解包和冲突合并资产数据。

## 设计边界

- 后端保持零知识：只存储 `encrypted_blob_base64`、`vector_clock`、更新时间和归属用户。
- 客户端负责加密与解密：统一使用 Rust `orbit-core` 的 `orbit_encrypt_config` / `orbit_decrypt_config`。
- 各端本地安全存储不同：Apple Keychain、Windows DPAPI/Credential Manager、Android Keystore。
- 云端 Blob 必须完整：只要本地存在密码、私钥、私钥口令，就必须打入同一个加密 Blob。
- 禁止上传平台私有路径：例如 macOS `~/.ssh/id_rsa`、Windows `C:\Users\...`、Android SAF URI 均不得进入云端模型。

## PortableServerConfig v1

字段名采用 JSON camelCase，所有字符串必须是 UTF-8。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `id` | string(UUID) | 是 | 资产唯一 ID，四端保持一致 |
| `credentialID` | string(UUID) | 是 | 本地凭据索引 ID，默认等于 `id` |
| `name` | string | 是 | 资产名称 |
| `group` | string | 是 | 分组，空字符串表示未分组 |
| `host` | string | 是 | IP/域名，不含本地路径 |
| `port` | number | 是 | 1-65535 |
| `username` | string | 是 | 登录用户名 |
| `authMethod` | string | 是 | `password` 或 `key` |
| `transport` | string | 是 | `ssh` 或 `telnet` |
| `networkDeviceProfile` | string | 是 | `auto`、`huaweiVRP`、`h3cComware` 等 |
| `allowPasswordFallback` | boolean | 是 | 密钥失败后是否允许密码回退 |
| `password` | string | 是 | 敏感字段，仅存在加密 Blob 内 |
| `privateKeyContent` | string | 是 | 私钥原文，仅存在加密 Blob 内 |
| `privateKeyPassphrase` | string | 是 | 私钥口令，仅存在加密 Blob 内 |
| `keyReference` | string | 是 | 去路径化的文件名提示，可为空 |
| `savedAtUnix` | number | 是 | 秒级 Unix 时间戳 |

## 加密 Blob

1. 将 `PortableServerConfig` 用稳定 JSON 编码为 UTF-8 字节。
2. 调用 `orbit_encrypt_config(masterPassword, plaintextBytes)`。
3. 结果以 Base64 字符串作为 `encrypted_blob_base64` 上传。
4. 解密反向调用 `orbit_decrypt_config(masterPassword, encryptedBase64)`。

Rust 加密格式当前为：

```text
OTC1 | 16-byte salt | 12-byte nonce | AES-256-GCM ciphertext+tag
```

KDF：Argon2id，内存 64MB，迭代 3 次，输出 32 字节密钥。

## Vector Clock

- JSON 对象：`{"client": 1}` 或 `{"mac": 3, "ios": 2}`。
- 任一端上传前必须 bump 自己的 actor。
- 服务端只比较版本关系，不解密内容。
- 409 冲突后客户端拉取云端版本，进行字段级合并。

## 字段级合并规则

- 如果本地和云端相对同一个 shadow/base 修改的字段没有交集，静默合并。
- 如果修改同一字段，展示冲突弹窗，由用户选择保留本地或云端。
- 敏感字段 `password`、`privateKeyContent`、`privateKeyPassphrase` 也参与字段级比较，但 UI 必须脱敏展示。

Rust 已暴露以下跨端辅助 FFI：

- `orbit_portable_validate(json)`：校验并规范化 `PortableServerConfig`。
- `orbit_portable_changed_fields(base, newer)`：返回字段差异数组。
- `orbit_portable_merge(remote, local, localChangedFields)`：按本地变更字段合并。
- `orbit_vector_clock_bump(vectorClock, actor)`：递增指定端版本号。

## 各平台本地落地

| 平台 | 普通配置 | 敏感凭据 |
| --- | --- | --- |
| macOS/iOS | UserDefaults/SQLite shadow | Keychain |
| Windows | JSON/SQLite/LiteDB | DPAPI 或 Credential Manager |
| Android | Room/DataStore | Android Keystore 加密后的 SharedPreferences/Room |

## 禁止事项

- 禁止在本地普通配置文件中保存明文密码或私钥。
- 禁止 Android/Windows 自己实现不同的 Blob 格式。
- 禁止根据 `authMethod` 过滤凭据后再同步。
- 禁止把某一端专属路径写进云端模型。

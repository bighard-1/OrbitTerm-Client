# OrbitTerm Android Client

原生 Android ARM 客户端骨架，目标是与 macOS/iOS 共享同一套后端、加密 Blob、同步协议和 Rust 核心能力。

## 当前状态

- 已建立 Kotlin + Jetpack Compose 工程。
- 已定义 `PortableServerConfig`、`ServerAsset`、`ServerCredentials`。
- 已接入 Android Keystore 保护的 EncryptedSharedPreferences 凭据存储。
- 已建立 `OrbitApi` 登录/上传/拉取接口。
- 已预留 `OrbitCoreBridge`，并在 Rust 侧补充了同步相关 JNI 包装。

## 打包前待完成

1. 生成 Android `arm64-v8a/liborbit_core.so`。
2. 将 `SyncRepository` 接入真实登录态和本地 Room/SQLite 队列。
3. 接入终端渲染器、SFTP、Docker、Monitor 页面。
4. 将 SSH/SFTP/Docker/Monitor 的 JNI 或 UniFFI binding 补齐。

# Android Rust Bridge

当前 `OrbitCoreBridge` 是 Android 侧调用入口。同步协议相关函数已经具备 JNI 包装，可直接调用：

- `orbitEncryptConfig`
- `orbitDecryptConfig`
- `orbitPortableValidate`
- `orbitPortableChangedFields`
- `orbitPortableMerge`
- `orbitVectorClockBump`

后续终端、SFTP、Docker、Monitor 的大批量接口建议改用 UniFFI 生成 Kotlin binding，避免长期维护大量手写 JNI。

`orbit-core` 提供 `cdylib`，可以通过 `scripts/build_android_core.sh` 生成 `arm64-v8a/liborbit_core.so`。

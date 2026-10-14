# Apple 自定义按键本机存储 v1

更新：2026-09-04。仅本机存储已接入；不上传、不订阅新的云端配置种类。

## 范围与格式

- `TerminalCustomKeyStore` 为 iOS/macOS 共用的主线程串行存储；本轮原生编辑界面仅接入 iOS。macOS 原有终端界面不变。
- 一个账户对应一个 Keychain 二进制条目，service 为 `com.orbitterm.terminal-custom-keys.local.v1`，account 为规范账户名的 SHA-256，不使用用户名明文作为索引。
- 使用既有 `KeychainDataStore`，访问级别为 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`，未设置 `kSecAttrSynchronizable`；macOS 使用 Data Protection Keychain。未额外生成磁盘明文配置、密码或第二套密钥文件。
- 本机包装为 `{version:1, account, actor, envelope}`。actor 是首次成功写入后持久化的 UUID；envelope 使用共享 `terminal_custom_keys` v1 因果修订模型、字节语法和容量边界。
- 先验证 JSON 语法，再验证重复字段/未知字段、账户/actor/版本和内部信封。读取异常、未知模式或损坏记录不当作空库，不覆盖原条目。
- Apple 没有旧版自定义键数据，故不进行 Android 旧 preference 迁移，不制造空的“迁移成功”标记。

## 权限与事务

- `AppSession` 的认证、用户名、解锁状态直接驱动存储权限，不依赖 SwiftUI 页面销毁。切换规范账户会先锁定；UI 测试账户只使用内存隔离副本。
- 读写和键值获取绑定 `(account, generation)` 租约；锁定、切换账户、显式重新读取使旧编辑器及按钮租约失效。锁定移除可访问快照及编辑/撤销草稿，不承诺 Swift 托管内存的物理清零。
- 每次写入前重新比对 Keychain 中的原字节，拒绝覆盖外部变化、删除或不可访问记录；一个 `SecItemUpdate/Add` 原子替换整个文档。应用内操作无 `await` 交错，不提供跨进程 CAS 保证。
- 保存成功后再发布列表并关闭表单；失败保留表单输入，禁用重复写入并要求显式重新读取。不记录 payload、账户密钥或 Keychain 原始错误内容到日志。
- 删除写墓碑，原生管理页提供当前页面内的“撤销删除”，以新因果修订恢复。退出页面、锁定或重新读取后不保留撤销草稿。
- Keychain 的系统设备解锁保护不等于主密码派生加密；应用主密码锁通过进程内租约限制访问。不能宣称已实现自定义键云端端到端加密往返。

## iOS 原生界面

- 会话 → 快捷指令 → 管理自定义按键；终端键盘附加栏末尾也有“编辑”。内置键保留，自定义键按常用/符号分区追加。
- SwiftUI `List/Form/NavigationStack/sheet` 管理添加、编辑、删除、撤销和错误状态；UIKit `UIInputView` 管理键盘附加栏。“常用/符号”与收起键盘按钮不随键列表滚动，触摸目标至少 44pt。
- UIKit 按键动作只保留 ID；点击时通过当前回调、当前账户租约解析发送字节。会话页面还校验活动会话身份。编辑/保存不发送任何终端输入。
- 名称按 Unicode 标量计数 1–16；发送内容解码后 1–64 字节、源文本最多 256 字节；包含 CR/LF 时提示可能立即执行命令。无效输入不截断、不静默替换。

## 自动化与验证边界

- `TerminalCustomKeyStoreTests`：12 项，账户/锁定/旧租约、稳定 actor、读取/写入故障、外部修改、墓碑撤销、严格格式、容量、Unicode、冲突禁发及重入锁定。
- `OrbitTermMobileKeyTests`：独立无网络宿主，真实模拟器 Keychain 属性/重开/账户隔离，UIKit 附加栏冻结与回调更新，以及 320/375/414/768pt、深色、大字体布局截图。宿主需正常模拟器临时签名；无宿主或强制无签名不是有效的 Keychain 验证环境。
- `TerminalCustomKeyEditorUITests`：添加/编辑/取消/删除/撤销、非法输入/回车警告、超大字体、保存失败保留草稿。均为进程内测试账户，不用用户登录信息，不执行服务器命令。
- 原生截图是组件布局检查，不等于 iPad 整机布局验收；实际软键盘/外接键盘、VoiceOver 连续阅读、后台锁定以及设备 Keychain 行为仍需设备验证。

## 后续

双端冲突解释、损坏配置导出修复/恢复界面尚未完成。旧发布客户端和 Linux 分支兼容发布策略未明确，账户 E2EE 网络写入继续关闭。`ThisDeviceOnly` 数据不能作为跨设备备份；在同步/受保护导出完成前，重置或更换设备可能丢失本机按键。

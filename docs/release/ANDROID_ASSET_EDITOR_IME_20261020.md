# Android 资产编辑页键盘避让专项（2026-10-20）

本记录只涉及 K60 独立受保护 QA 和 Android 36 隔离模拟器；不包含账户凭据、真实资产地址或设备标识。总台账编号 `ANDROID-ASSET-IME-108`，前置的本机资产删除文案问题见 [K60 SFTP 专项](ANDROID_SFTP_DEVICE_20261020.md#受保护-qa-恢复尝试与本机删除语义纠偏)。

## 原始失败与源码原因

- 用户在 K60 受保护 QA 新建唯一虚构“仅此设备”资产时，报告键盘盖住输入框、上划无法调整，无法完成字段录入；因此删除提示真机验收**尚未执行**。不得把未完成的表单当作保存成功。
- `MainActivity` 已声明 `adjustResize`，但 `AssetEditor` 内 `LazyColumn` 没有占用受约束的剩余高度，也没有处理 IME inset；外层 `MainScreen` 在编辑资产时仍显示底部导航，进一步压缩表单空间。该布局与所报现象相符；尚无 K60 屏幕坐标证据证明它是唯一原因。

## 修复候选与验证分层

- 源码提交 `eecac4d`：编辑页外层消费 IME inset，长表单使用受权重约束的 `LazyColumn` 滚动；编辑页打开时底部导航隐藏，返回列表后恢复。增加仅供测试的字段/表单/保存按钮语义标识，不涉及凭据采集或日志输出。
- 自动化：首次本地 QA 编译因缺少 `collectAsStateWithLifecycle` 导入失败，补齐后 feature 单测、app QA 单测和受保护 QA 构建通过。新增底部导航显隐断言。初始 Android 36 隔离 Compose 运行被测试 APK 的“旧版 Android 应用”系统警告遮挡；消除该测试宿主警告后，默认 `adjustPan` 把整个页面顶部推离屏幕。测试宿主改用生产声明的 `adjustResize`、并启用 edge-to-edge；最终 **1/1** 验证密码框在 IME 边界之上、可输入虚构字符串、顶部保存按钮可见。上述宿主失败保留，不记为产品真机失败或成功。
- 隔离 GUI：以上仅为 Android 36 模拟器的独立 Compose 宿主，不是 K60 QA 全流程，也未登录测试账户。未覆盖厂商输入法、长私钥、多行字段、跳板机字段、系统字体放大或横屏（正式版固定竖屏）。
- 真实设备：arm64 受保护 QA APK SHA-256 `a35558792ccfabf55d966d313cbd1872ae34b31990659328aad6c761de375cec`，测试签名 SHA-256 `487967efa5c0fdd16f5d37be2c9bc0b959807da8a6a458e2788c23d000df0751`，已在 K60 原位安装；设备内 `base.apk` 哈希与候选完全相同。用户随后在实体 K60 的受保护 QA 成功填写并保存一条虚构“仅此设备”SSH 资产，原先“键盘遮挡导致无法完成添加”的阻断在这一条基本表单路径上解除。用户没有逐字段报告键盘边界、滚动位置及保存按钮可见状态，不能把此结果扩展为所有表单/输入法通过；正式包未更新。
- 五端完整验收：未完成。该布局变更只在 Android；Windows/iOS 等其他客户端不从此结果自动获得键盘/编辑页通过结论。

## 下一步对照

1. K60 的普通 SSH 表单已能完成虚构资产添加；仍需在不同输入法/字体大小下逐字段核对键盘边界、上划、保存，并补长私钥和跳板机多行输入。旧包阻断保留，不能用此次基本路径覆盖。
2. 本机资产删除的确认文案与“最近删除”结果已由用户核对，详见 [K60 SFTP 专项](ANDROID_SFTP_DEVICE_20261020.md#受保护-qa-恢复尝试与本机删除语义纠偏)；完成提示原文与活动列表消失未单独回报，不扩大结论。
3. iOS 对照移动端焦点与键盘回避，Windows 对照资产表单焦点/保存与本机资产删除文案。之后另建隔离只读 SFTP 夹具，补受保护 QA 的取消、失败与文件残留。

## Android 15 托管模拟器门禁失败与分层修正

- 固定候选 `2eb062f` 的 [Security Gates](https://github.com/bighard-1/OrbitTerm-Client/actions/runs/39529795959) **失败，原始结果保留**：Android instrumentation job 的 feature 套件运行 8 项时，本专项新增 `AssetEditorImeComposeTest.passwordFieldRemainsAboveKeyboardAndAcceptsInput` 在 Android 15 AOSP ATD 上等候 IME 可见超过 5 秒，抛出 `ComposeTimeoutException`；不能把 Linux/Windows CI 成功误写成总门禁成功。该失败仅定位到测试等待条件，未证明 K60 产品布局回归。
- 测试修正提交 `8244b80`：ATD CI 配置只断言表单滚动、密码框可输入以及保存按钮可见；有实体软键盘的本地模拟器和 K60 路径仍要求 IME 可见并检查字段/保存按钮在键盘上方。**ATD 不再声称验证键盘边界**，这是明确的覆盖分层，不是删除真机验收要求。
- 本机 `:feature:assembleDebugAndroidTest --offline` 编译通过。修正提交的远端 Android 15 instrumentation 尚待新一轮 CI，不能预先记为通过；K60 当前受保护 QA 二进制不因测试源码变更而更新。

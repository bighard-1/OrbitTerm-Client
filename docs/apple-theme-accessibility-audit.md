# Apple 五主题辅助功能审计

审计日期：2026-07-15

范围：`sky-candy`、`emerald-flow`、`peach-dawn`、`lavender-mist`、`glacier-mint`，覆盖 macOS 14 与 iOS 17 的登录、解锁、设置、工作台、SFTP、Docker、Monitor 和资产管理主题 chrome。

## 已完成修复

- 主题 surface 在“减少透明度”下集中使用可读的实体 surface；提高对比度时，卡片、输入框和焦点边界使用更粗的主题边框。
- 登录、解锁、工作台标签、服务器侧栏、SFTP 选择和传输、Docker/Monitor 面板补充了可读名称、组合行语义或状态图标。
- 图标操作包括新建会话、关闭会话、展开/收起侧栏及隐藏 Docker/Monitor 面板均有动作型标签。
- 登录和主密码状态改用显式展示语义；不会通过用户可见文案决定颜色或辅助功能状态。
- 连接、传输、容器和资产状态继续用文字与 SF Symbol 表示，颜色仅为辅助信息。
- Monitor CPU、吞吐和详情图表提供当前值文本摘要；不逐点朗读历史采样。
- 登录按钮、认证切换和主密码错误提示在“减少动态效果”下取消装饰性缩放、位移或摇晃，必要的 `ProgressView` 保留。
- 密码和 passphrase 继续使用 `SecureField`；本轮没有为私钥正文、密码、token 或 Keychain 引用添加 accessibility value、hint 或日志。

## Dynamic Type 与键盘

- 资产、SFTP、Docker、Monitor 和工作台的名称截断保留可读的组合 accessibility label；关键状态不只存在于紧凑单行 badge。
- 现有原生 Button、Picker、TextField、SecureField 和 List 保持键盘可达。主题 focus ring 在高对比设置下加强；没有新增全局快捷键或改变 Return/Escape 行为。
- Hover 不是关键操作的唯一入口：相同操作保留按钮、context menu 或键盘可访问路径。

## 已知限制与真机阶段

- 本轮是静态与构建级验证；需要在真机上使用 VoiceOver、Dynamic Type 最大字号、Switch Control 和 macOS Full Keyboard Access 做人工流程确认。
- 当前资产页面没有可安全复用的 typed Host Key 生命周期输入，因此没有将显示文案反推为 Host Key 安全阶段。
- 图表摘要只陈述当前真实采样值，不推断趋势或更改阈值。

## 真机、键盘与签名环境验证（2026-07-15）

### 环境与自动验证

- Xcode 26.6 / Swift 6.3.3；XcodeGen 重新生成工程、`plutil` 和 `git diff --check` 均通过。
- 已发现的可用 destination 仅为本机 macOS 与 iOS Simulator；Core Device 未发现已连接的实体 iPhone 或 iPad。
- iOS Debug 设置为自动签名，但当前环境没有配置 Development Team；本机未发现 Apple Development 或 Distribution 签名身份，也未发现 provisioning profile。因此未尝试设备构建、安装或启动，也没有变更签名、Bundle ID、entitlements 或 Apple Developer 设置。
- macOS Debug 产物已构建并通过 `codesign --verify --deep --strict`。其为本地 ad-hoc 签名，适合作为本机构建验证，不代表发布或公证签名。
- 自动回归继续覆盖全量 XCTest、macOS Debug 与 iOS Simulator Debug；这些结果不替代真机辅助功能结论。

### 未验证与环境阻断

- iPhone：签名、安装、启动、VoiceOver、Dynamic Type 三档、减少动态效果、减少透明度、提高对比度、无颜色区分及五主题 Light/Dark 人工矩阵均未验证；原因是没有已连接、配对且启用 Developer Mode 的实体设备，且没有可用开发签名身份或 profile。
- iPad 与外接键盘：未验证；原因是没有已连接的实体 iPad。模拟器不作为真机结论。
- macOS：自动构建和签名验证通过；应用辅助功能树读取在本机控制工具中超时，未将其或键盘导航、VoiceOver、Full Keyboard Access 人工流程标为通过。

### 后续人工清单

在已配对、解锁且开启 Developer Mode 的设备上，使用既有签名环境完成最低矩阵：五主题的登录/解锁、工作台、资产表单与一项功能页；并至少各完成一套 SFTP、Docker 与 Monitor 的 Light/Dark 检查。随后在 VoiceOver、最大辅助功能字号、减少动态效果、减少透明度、提高对比度和无颜色区分下复测；记录页面与设置，不记录凭据、私钥、token、完整 UDID 或 provisioning 内容。

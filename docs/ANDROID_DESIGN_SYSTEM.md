# Android 设计系统与视觉回归

更新时间：2026-07-28  
范围：Android 的应用层 Material 外观、操作状态与危险操作；终端 ANSI 外观是独立的用户偏好。

## 设计原则

- 应用主题只决定应用界面；切换配色、深浅色模式不得重写终端 ANSI 色板。
- 反馈不得只用颜色表达：每个状态同时有文本、色彩和 Compose 语义。
- 危险操作使用明确动词、可见“危险操作”标识、危险色确认按钮与独立取消入口。
- 页面不得自行硬编码“成功/警告/失败”颜色；应使用 `OrbitStatusTone` 和 `orbitStatusColors`。

## 语义令牌

| 令牌 | 用途 | 组件 |
| --- | --- | --- |
| `Neutral` | 非活动、说明、普通状态 | `OrbitStatusLine` |
| `Information` | 引导、可执行提示 | 页面提示与后续表单提示 |
| `Success` | 已连接、已完成 | `OrbitStatusLine`、`OrbitFeedbackBanner` |
| `Warning` | 需要用户注意但尚未失败 | `OrbitStatusBadge` |
| `Danger` | 失败、删除、强制停止等风险操作 | `OrbitFeedbackBanner`、`OrbitConfirmationDialog`、`OrbitFormDialog` |

登录与主密码锁定页面的品牌标题必须暴露为无障碍标题；认证与解锁失败必须使用 `OrbitFeedbackBanner`，以 `LiveRegion` 主动通知读屏。该约束由 `MobileRootStateComposeTest` 覆盖，并纳入连接设备的 Android 测试门禁。

这些令牌由 [OrbitDesign.kt](../clients/android/OrbitTermAndroid/design/src/main/java/com/orbitterm/android/ui/design/OrbitDesign.kt) 统一定义。终端只使用 `TerminalThemePreference` 的原始背景、前景和 16 色 ANSI 值；主题预览使用 `OrbitTerminalThemeSwatch`，不能借用应用状态色。

## 视觉回归基线

`OrbitDesignScreenshotBaselineTest` 捕获 Activity 的真实 Compose 内容树，并对像素生成 SHA-256 指纹。基线目标为本项目 CI 使用的 Android 15 ARM64 模拟器（320 × 640 内容区域），覆盖：

- 明亮主题下的页面标题、状态标签、成功反馈与 Dracula ANSI 色板预览；
- 深色主题下的失败反馈和危险确认对话框。

系统状态栏、导航栏不参与捕获，避免时钟、手势区域等系统像素造成误报。若设计有意变化，应先在该固定模拟器上审查变化原因，再更新测试中的指纹；不得为使测试通过而在未审查的设备或密度上重录。

## 自动化门禁

- `:app:testDebugUnitTest`：主题完整性、终端前景/背景至少 4.5:1 对比度、状态契约。
- `:app:connectedDebugAndroidTest`：Compose 语义、危险操作可达性、截图指纹、Room 迁移和性能预算。
- `P2AccessibilityLayoutRegressionTest`：字体 200% 的危险确认操作可达性，以及横屏宽度下的终端状态/主题布局。
- `scripts/security/check_android_instrumentation_gates.sh`：确认上述仪器化测试类均在结果中出现。

真机上的 TalkBack、字体 200%、横屏/分屏和硬件键盘仍按 [Android 验收清单](ANDROID_ACCEPTANCE_CHECKLIST.md) 执行；截图指纹是回归门禁，不替代这些真实交互验收。

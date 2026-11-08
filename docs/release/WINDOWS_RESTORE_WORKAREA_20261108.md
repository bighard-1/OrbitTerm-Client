# Windows 还原窗口工作区保护（2026-11-08）

## 旧候选真实 GUI 复现

在 Windows 10 测试机已安装的 `56c9e6d` QA、1280×720 RDP、原 100% 文本大小下取消主密码页，保持账户锁定。普通窗口拖到下方，使底部超出工作区；最大化后再点击还原，底部仍被任务栏／屏幕边缘遮住。已保存还原失败画面，随后最大化并正常退出 QA，RDP 保持连接。未解锁账户、未同步、未连接或删除资产。此受控复现证明该路径不要求 150% 文本，不反推上轮首次异常的全部历史原因。

先前 `56c9e6d` 的 Security `42454682865` 现已最终成功，六个必跑 job 全部成功；专用签名 Mac UI／OpenSSH RC 两个条件任务 skipped。它是本次修订前的门禁，不能替代新修订验证。K60 未在 USB 列表出现，未操作手机；其他端无新设备结果。

## 修订行为

- 对窗口初次显示、从最小化／最大化还原、显示器分辨率／DPI／工作区变化及退出终端全屏的边界，延后到原生消息处理完成后重新读取实际窗口矩形。
- 仅普通还原状态进行修正，按当前／最近显示器的可用工作区移动；尺寸只有在大于工作区时才缩小。保持合法的负坐标，避免把左侧／上方显示器误判为越界；运算使用宽整数避免坐标加尺寸溢出。
- 不在每个位置／尺寸变化中修正，不干预普通自由拖动；若显示环境在原生拖动循环中变化，等该循环结束再处理。排队任务合并，关闭／全屏状态不移动，已在工作区内不重复调用 MoveAndResize。
- 没有禁用窗口拉伸、最大化、系统文本缩放或安全保护；原生尺寸下限仍按实际工作区限制。

实现依据：[WM_SIZE 状态](https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-size)、[原生拖动循环](https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-entersizemove)、[DisplayArea 回退规则](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.windowing.displayareafallback?view=windows-app-sdk-1.7) 和 [MoveAndResize 屏幕坐标](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.windowing.appwindow.moveandresize?view=windows-app-sdk-1.8)。API 文档不能代替真实多屏／DPI 验收。

## 自动化与限制

新增 9 项几何测试覆盖任务栏遮挡、合法矩形不变、顶部／左侧工作区留白、负坐标显示器、显示器移除后的远处矩形、较小工作区、超大窗口、整数边界及无效工作区；同时断言修正幂等。定向 **9／9** 通过，运行于 Mac 可移植 .NET，不能记为 WinUI 设备通过。

首次本地完整测试 **372 通过／40 失败／0 跳过**：测试项目将 macOS 原生库按 Windows 文件名复制，原生加载失败。首次失败保留；修正忽略的测试输出目录中的平台文件名，没有为此修改产品或过滤失败测试。后继完整套件结果另收。

测试环境修正后，完整可移植 .NET **412／412、0 失败、0 跳过**，TRX 与完整日志保存在私有证据目录；包含新增 9 项回归，不排除先前失败项。该结果运行于 Mac，仍不替代后继 Windows 原生套件和 GUI。

跨桌面视觉合同、桌面稳定性合同、静态安全扫描及差异检查通过。新修订的 Windows 原生测试／WinUI 编译、签名更新及修订后 GUI 尚待固定候选回执，**还原位置问题未记作设备闭环**。

## 下一步关闭条件

同一测试机重复“自由拖出→最大化→还原”：拖动期间不拉回，还原后同步底栏与窗口底边可见。补最小化→还原、普通边框拉伸、窗口内拖动、RDP 分辨率切换；真实多屏／DPI 及在线终端全屏返回单列未覆盖，不以纯几何单测代替。

Android 后续对照旋转／分屏后的关键操作可见性，macOS／Linux 对照屏幕变化后的还原矩形与自由拖动。五端完整验收未完成。证据仅存加密私有目录 `Development/orbitterm-windows-restore-workarea-20261108/`，不提交真实端点、凭据或设备标识。

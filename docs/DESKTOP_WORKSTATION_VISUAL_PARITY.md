# OrbitTerm 三端桌面视觉一致性契约

适用范围：macOS、Windows、Linux 原生桌面客户端。

## 视觉裁决原则

三端不是相互复制皮肤，而是实现同一个紧凑专业运维工作台。Windows
工作台的布局密度、终端宽度保护和响应式折叠作为结构基准；macOS 的
颜色层次、认证聚焦和表面克制作为表现基准。用户已经验收的零宽度折叠、
同步状态常显、紧凑监控带和端点监控卡属于共享产品决策。

## 必须一致

- 顶部 Logo、全局操作的数量、顺序、相对权重和可达性。
- 端点与六项监控指标的顺序、卡片占比、曲线和详情入口。
- 资产栏、终端工作区、会话工具三栏结构及其响应式折叠顺序。
- 标签、终端、命令预输入、SFTP、Docker、Snippets 的信息层级。
- 登录、注册、解锁和同步管理的任务拆分及字段顺序。
- 设置分组顺序、五套应用主题、四套终端主题和语义状态色。
- 空、加载、失败、危险确认、禁用和焦点状态的视觉语义。

## 允许原生差异

- macOS 交通灯、Windows 标题栏按钮、Linux 桌面环境窗口按钮。
- SF Symbols、Segoe Fluent Icons 和 Freedesktop symbolic icons 的具体字形。
- San Francisco、Segoe UI Variable、Adwaita Sans 的字面度量差异。
- Command、Ctrl、Alt、Super 的平台惯用快捷键。
- Touch ID、Windows Hello、Secret Service 等平台能力入口。
- 原生文件选择器、通知、无障碍焦点框和系统高对比度呈现。

## 响应式验收矩阵

每端至少验证 980×700、1180×720、1280×800 和最大化四种状态。Windows
额外覆盖 100%、150%、200% DPI；macOS 覆盖标准与 Retina；Linux 覆盖
GNOME/Wayland 和 GNOME/X11。相同测试状态下，面板占比、控件顺序、
文本层级和功能可见性必须一致，字体像素栅格和原生窗口装饰不参与失败判定。

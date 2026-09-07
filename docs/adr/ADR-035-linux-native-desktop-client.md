# ADR-035: Linux 原生桌面客户端架构与发行边界

- 状态：Accepted
- 日期：2026-08-23

## 背景

OrbitTerm 已有 Apple、Windows 与 Android 客户端，并以 Rust `orbit-core` 提供安全敏感的跨端能力。Linux 端需要接近 Windows/macOS 工作台布局，同时覆盖 GNOME/KDE、Wayland/X11 以及不同发行版生命周期，且不得产生第四套 SSH/SFTP/Docker 实现。

## 决策

采用 Rust + GTK 4 + libadwaita + VTE 构建 Linux 桌面客户端，并保持五层边界：

1. `domain` 只定义不含凭据的可移植服务器资产。
2. `application` 定义用例和仓储协议，不依赖 GTK、Secret Service 或 FFI。
3. `bridge` 是唯一 `orbit-core` C ABI 边界，只暴露 checked connect、checked channel 与必要的通道控制/释放操作。
4. `platform` 负责 XDG、Secret Service、portal 与发行版集成。
5. `app` 负责 GTK 状态、交互与可访问性，不直接声明 FFI。

`orbit-core` 作为 Rust 依赖静态链接入 Linux 可执行文件，避免要求用户单独安装 ABI 完全一致的共享库。系统图形栈通过 Flatpak 运行时固定；原生包则以 Ubuntu 24.04 的 GTK 4.14、libadwaita 1.5、VTE 0.76 和 glibc 基线为第一验证目标。

## 同步与凭据

Linux 本地领域与资产仓储只表示服务器 ID、credential ID、名称、分组、主机、端口、用户名、认证方式、传输方式、标签与非平台化密钥提示，不表示密码、私钥或口令。为了与 Apple/Android 已上线协议兼容，同步用例可在内存中从 Secret Service 临时丰富 portable 配置，并在主密码端到端加密后上传密文；拉取密文解密后必须立即把凭据拆分回 Secret Service。凭据明文、绝对路径、Host Key challenge 和会话 ID 不得进入资产文件、日志或网络明文。

Linux 同步必须复用既有 API、资产 UUID、identity fingerprint、vector clock、游标、墓碑、幂等 operation ID、冲突合并和主密码轮换语义。已开放的安全拉取阶段固定 HTTPS 正式端点，支持登录/刷新、与 Apple 相同的 JWT `uid` 哈希账户指纹、每账户游标、稳定设备 ID、增量分页、单次游标失效回退、主密码解密和 portable 校验。同 UUID、涉及本地的墓碑、解密失败及不支持项均进入待处理区，不自动应用。

Linux 只有在一批变更没有待处理项、所有本地资产与 Secret Service 写入全部成功后，才发送同步 acknowledgement 并原子保存服务端确认的账户游标。acknowledgement 不修改云端配置；若服务端不支持增量端点，则允许只读全量兼容导入，但不得保存或确认游标。完成冲突决策、墓碑决策、加密上传、幂等离线队列与跨端测试前，禁止 Linux 上传、删除或覆盖云端配置。

主密码解锁会话只存在于应用进程的零化内存中，每次成功解密后最多保留 30 分钟；显式锁定、账户切换、退出和应用关闭立即清除。解锁期间允许账户隔离的后台增量拉取：无待处理项时自动落盘并确认游标，有冲突、墓碑、解密失败、排队资产或本地写入失败时停止确认、保存内存预览并发送去重桌面通知。后台调度与同步中心互斥且保持单飞。

访问和刷新令牌只存入 Secret Service。退出必须先清除内存主密码与待展示预览，再清除本机令牌；若密钥环清除失败则退出不得显示成功。当前正式 API 未提供 logout/revoke 契约，Linux 不虚构远端撤销成功，界面明确说明本地撤销边界；服务端增加撤销接口后再扩展为远端优先、成功后本地清除。

Linux 凭据存入 Secret Service，使用稳定 credential ID 查找。Host Key 单独写入 XDG state 下的 OrbitTerm 专用 `known_hosts`，首次连接展示 SHA-256 指纹；发生 changed/revoked/unsupported 状态时阻断，禁止“仍然连接”。

## UI 决策

保留 Apple/Windows 已有的信息架构：左侧资产列表、中部多标签工作站、右侧会话工具和底部连接状态。控件、焦点、字体缩放、深浅色与窗口装饰遵循当前 Linux 桌面，不做像素级伪 Windows/macOS 皮肤。

窄窗口通过可拖动分栏保持核心终端可用；后续阶段在小于 960 px 时把工具区收进自适应抽屉。动画只用于状态过渡并遵循减少动画设置。

## 发行与兼容性

Flatpak 是跨发行版主渠道；原生 `.deb` 是 Ubuntu/Debian 补充渠道；企业 tarball 仅对声明的 ABI 基线负责。支持矩阵按桌面会话而不是发行版名称无限承诺：

- GNOME/Wayland 为主验证组合。
- GNOME/X11 与 KDE/Wayland 为次级验证组合。
- 无 Secret Service、无 portal 或纯服务器环境提供明确诊断，不降级为明文凭据。
- x86-64 为首发架构；aarch64 在独立 CI runner 与真实设备验证后发布。

## 后果

优点是最大化原生体验、复用安全内核、减少发行版依赖漂移并保留跨端同步语义。成本是需要维护 Flatpak 权限、GNOME/KDE 组合测试，以及对 libadwaita 自适应布局做持续验证。

Electron、Tauri/WebView 和单一 AppImage 不作为首选：它们不能消除 Secret Service、portal、Wayland、系统 SSH 安全边界与运行时生命周期的测试责任。

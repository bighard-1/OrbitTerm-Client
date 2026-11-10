# 独立 QA 客户端清理与重装记录（2026-10-10）

关联总台账：`FIX-20261010-06`；关联 SSH 二次验证专项：`SEC-02` / `SSH-MFA-DEVICE-01`。本次仅处理已识别的隔离测试客户端和构建，不修改线上服务、云端资产或正式客户端身份。源码固定为已推送的 `codex/five-platform-integration` 提交 `6e62d9c`，其中 SSH 二次验证实现提交为 `67a9e7d`。

## 清理前门禁与实际处理

| 平台 | 已识别的旧安装 | 清理前保护检查 | 实际处理与恢复性 |
| --- | --- | --- | --- |
| iPhone 13 mini | 独立 QA 身份 `com.orbitterm.matrix.ios`，旧版 `1.0.1 (20260624)` | 对该 QA 容器的同步队列只读计数为 0；未读取/导出明文资产或凭据 | 精确卸载该 Bundle ID，再安装新版。卸载会清除旧 QA 本地容器，**本机不可恢复**；云端测试账户资产未执行删除。正式身份 `com.orbitterm.app` 保留原状。其他配对手机未操作。 |
| iOS 模拟器 | 当前启动模拟器中的相同独立 QA 身份旧包 | 旧 QA 队列只读计数为 0 | 精确卸载、重装并启动；旧模拟器 QA 容器同样被清除。 |
| macOS | 运行于旧临时构建目录的 `com.orbitterm.matrix.macos` | 核对进程与 Bundle ID；发现正式身份的另两处安装，不纳入本次清理 | 常规退出请求未完成，改向**已核实的旧 QA 进程**发送 TERM 并确认退出；旧 QA 应用本体移入用户废纸篓，**可恢复**。新 QA 应用安装到独立的 `~/Applications/OrbitTerm QA.app`。未清除 Application Support 或 Keychain，也未移动正式客户端。 |
| Ubuntu 开发机 | 只发现一份已安装的 `com.orbitterm.Client` Flatpak；若干历史隔离源码目录并非已安装客户端 | 现有主项目工作区有未提交改动，不能清理或覆盖；现有 Flatpak 与数据保持不动 | **没有卸载 Linux 原安装**。在全新、干净的隔离目录检出同一提交；新版 QA 二进制单独安装到 `~/.local/opt/OrbitTerm-QA-20261010/`，不写入原 Flatpak。不会把“旧源码目录”误当作旧安装包删除。 |

## 新候选与验证层级

| 层级 | 结果 | 尚未覆盖 |
| --- | --- | --- |
| 固定源码 | `6e62d9c`，构建前源码工作区清洁；Mac/iOS/Linux QA 均从该提交构建。 | 源码同源不代表各端实际运行或功能验收。 |
| 构建与签名 | iPhone QA `1.0.2 (20261010)`，独立 ID `com.orbitterm.matrix.ios`，Debug + 显式镜像 QA 标记；Xcode 构建与严格签名校验通过，可执行文件 SHA-256 `258df8889cb075bbe22bdd81c82bb7f728c86d8bec860f2df3275e9a90aafc93`。macOS QA `1.0.2 (20261010)`，独立 ID `com.orbitterm.matrix.macos`，构建与严格签名校验通过，实际代码 `OrbitTerm.debug.dylib` SHA-256 `64352dc45444d1d462868d0e64e42d86c60f98068806d5da823491cadb690edc`。模拟器 QA 从同一源码及显式 QA 标记构建通过。Ubuntu 干净检出中的 `cargo check -p orbitterm-linux --locked` 和 `cargo build -p orbitterm-linux --locked` 均通过，QA 二进制 SHA-256 `b42851faf2cc3e3c070f69458b43ba9870b3eaab3daa22c826b73135be2f5697`。 | 开发签名 QA 包不是发布包；Mac/Linux 构建仍有既有 FreeRDP 废弃 API 头文件警告。iPhone 开发描述文件于 **2026-10-15 UTC** 到期，届时须重新签名，不能将当前包作为长期验收候选。 |
| 安装/进程 | iPhone 13 mini：新 QA 包安装与 CoreDevice 启动成功，安装清单显示 `1.0.2 (20261010)`，正式包未变。iOS 模拟器：新 QA 包安装和 `simctl launch` 成功。macOS：新 QA 包安装至独立位置，安装后签名和版本复核通过。Ubuntu：QA 二进制单独复制到独立目录并复核哈希；原 Flatpak 仍在。 | Mac 新 QA **未启动**：现有应用使用通用 Application Support 路径，未建立与正式客户端数据完全隔离的运行时前，不应在同一 macOS 用户下冒然登录。iPhone/模拟器本轮也未重新登录或做 SSH OTP GUI。 |
| 隔离 GUI / 真实设备 | iPhone 的“安装＋进程启动”是设备级烟测，**不是页面、登录、同步或验证码流程通过**。Ubuntu QA 用独立 XDG 数据/配置/缓存目录、私有 D-Bus 会话及 Xvfb 启动，进程维持到 15 秒超时（退出码 124）；原 Flatpak 未停。 | Xvfb 本轮**未采集并检查画面**，只能记为无立即退出的进程烟测，不记为 GUI 交互通过。隔离会话出现文件门户 FUSE 权限警告和超时结束时的 D-Bus 退出提示，未见应用崩溃；需在真正 GUI 交互时对照。真实验证码 SSH 主机、错误码/取消/双跳、敏感数据边界及五端墓碑矩阵仍待测。Android/Windows 实体设备未就绪，本轮未安装。 |

## 保留的异常与后续对照

- 旧 Mac QA 的常规退出请求未完成；定向 TERM 后确认进程退出并安全移动应用。没有据此推断应用存在新的产品级退出缺陷，后续应在可复现条件下单独检查。
- 新 iPhone QA 安装清除了旧 QA 本地会话；再次进入时可能需要重新登录和接受法律条款。不能把当前“启动成功”误记为“已解锁/已同步”。
- iPhone QA 的镜像捕获豁免仅限三重门禁，**正式版镜像隐私 P1 仍开放**；该 QA 包不得分发为正式版或承载真实资产。
- Android/Windows 准备就绪后，用同源固定提交重建两端原生库和测试包，记录签名、版本与哈希；先验收 SSH 密码/密钥＋验证码、双跳、取消和不留明文，再做旧缓存墓碑复活、离线删除和跨端队列对照。Linux/Mac/iPhone 也需使用真实 OTP 测试服务器补齐同一矩阵，不能因安装成功关闭 `SSH-MFA-DEVICE-01`。

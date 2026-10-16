# OrbitTerm 项目记录约定

对客户端功能、安全、同步/墓碑、跨端契约或验收流程做修复与优化时，同步更新 `docs/release/FIVE_PLATFORM_FIX_AND_REGRESSION_LEDGER.md`。新增记录须区分源码、自动化、隔离 GUI、真实设备和五端完整验收；写明提交/候选构建、验证结果、未覆盖范围，以及 Android/Windows 后续对照点。失败结果保留，不以重跑覆盖。

真实账户/设备证据只写脱敏信息；不得提交密码、令牌、私钥、完整资产地址、设备 UDID 或未脱敏 HTTP 请求/响应。详细复现证据可追加到相应的 `docs/release/` 验收日志，并从总台账链接。

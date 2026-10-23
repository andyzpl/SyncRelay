# 0.2.28+aprobe.3 阶段 A 只读观察候选

日期：2026-10-23。状态：**本地候选准备完成；等待隔离提交、单次 CI/普通 DEB 构建与下载核验。尚未安装或取得真机证据。**

## 精确身份

- 基线：`51803d43fe068d16c462cea0729264a26cf5f2f5`（`0.2.27+aprobe.2`）。
- 候选分支：`codex/operations-a-device-probe-20261023-aprobe3`。
- 插件版本：`0.2.28+aprobe.3`；包 ID `andyz.syncrelay`；普通 `iphoneos-arm` DEB。
- schema：14；不新增迁移 SQL，不改发送核心、receiver ABI、消息库派发或视频能力。

## 相对 `.2` 的生产逻辑

- `SRStore` 增加只读 `schemaVersion`：仅在构造、迁移事务提交、外键复核和 `PRAGMA user_version == 14` 确认后发布；构造失败不返回对象。
- `SRPanel` 诊断导出 `schemaVersion`；存储不可用时为 `null`。
- receiver/probe 增加精确 local-ID 回读后的匿名 `hookMessageOrdinal` 关联；原始 local/server ID 不导出，停止/重开清空。
- 分析器新增 `--stop-pair`，收紧 `--pair` 的同轮、armed、generation、样本前缀和安全字段检查，并补 schema/local-ID 反例测试。

## 当前证据边界

本地全量 Python 179 项通过；Objective-C 新增用例尚未在本机编译、链接或执行。`schemaVersion=14` 只表示当前版本，不证明迁移前版本、旧行保留、迁移原子性或回滚。图片资源就绪、真实宿主语义、消息库派发、视频、UI 和阶段 A 整体验收仍未通过。

## 待执行的外部动作

1. 在隔离分支提交并推送当前候选。
2. 对该提交派发一次 `build_deb=true` CI，执行 Python、原生模拟及 arm64/arm64e 普通 DEB 构建。
3. 下载并核对提交/run、两架构、control/载荷/过滤、SHA-256 与无安装脚本。

授权不包括安装、RootHide 转换、设备库迁移或清理数据。完成核验后另写实际 run、摘要和证据路径。

# 0.2.21+a-package.1 阶段 A 打包候选

**2026-10-25 最新状态（已生成，用户已安装并回传报告）：** 按授权从当前开发快照建立隔离分支 `codex/a-package-20261025`，提交 `02cf7fb963fb4e34bb2a83a35d68fd1415e2aa87`，运行一次 `build_deb=true` CI `40179290423` / job `121126667336` 并成功。Python **225 项**通过；22 个 Objective-C 目标各执行 3 次；pacing、operations-state 各执行 1 次，media-quota 按矩阵执行 3 次；生产测试、打包和静态核验均通过。该包是普通 `iphoneos-arm` DEB，不是 RootHide 转换。用户安装后的 `102501.json` 确认 schema 14、发送/采样关闭和 `imageReads=0`，同时暴露出 `storageReady` 被生产端导出为数字 `1` 的布尔类型缺陷；这不是存储故障或迁移证据。

## 102501 回填与修复边界

- 当前分析器对报告输出 `storage_readiness_invalid`，因此不会继续解释 `schemaVersion`；这是保护性拒绝，不表示数据库不可用。
- `manual_delivery_not_determined`、`image_not_submitted`、`image_attempt_claimed` 和 `text_attempt_claimed` 是发送关闭、未主动提交及持久实验预约的既有边界，不是本轮新增失败，也不要求重复设备操作。
- `UI/SRPanel.m` 已改为显式 `@YES/@NO`，`tests/settings_ui_contract_test.py` 已增加生产端类型契约，`tests/diagnose_report_test.py` 断言该固定文案；本地复核为完整 Python 226 项、双架构语法检查与 `git diff --check` 通过。修复包尚未构建或安装，`102501` 只作为旧包缺陷证据，不能当作修复后证据。

## 包身份

- 包文件：`dist/0.2.21+a-package-test-40179290423/andyz.syncrelay_0.2.21_iphoneos-arm.deb`
- SHA-256：`bedb3a3a722dd10dbeed51ee857e4e9eaaf6fecd83666c6ee235df0a9e9692d5`
- CI artifact：`SyncRelay-development-deb`，ID `12592629882`
- 控制字段：`Package=andyz.syncrelay`、`Version=0.2.21`、`Architecture=iphoneos-arm`
- 包内含 `SyncRelay.dylib` 与 `SyncRelay.plist`；CI 已用 `dpkg-deb` 检查并用 `lipo` 验证 `arm64`/`arm64e`。

## 范围与边界

- 本次只提交隔离分支、运行一次构建工作流、下载并核对 DEB；主工作区 `main`、HEAD `f652d5e97180a15f43437fd1e449f3b3063e87fc`、暂存区及既有修改未覆盖。
- 没有安装、RootHide 转换、设备迁移、清理设备数据、发送实验或新的真机采样。
- 当前产品按 schema 14 全新初始化；不准备 schema 11 测试库，也不把 `102427` 的 14→14 基线当作迁移证据。
- 阶段 A 的开发侧 Python/C/Objective-C/打包门槛已具备该快照证据；真实微信来源时间语义、页面级生命周期和被动图片资源就绪仍未整体验收，B/C 继续关闭。

详细本地测试与剩余证据边界见 [OPERATIONS-A-LOCAL-CLOSEOUT.md](OPERATIONS-A-LOCAL-CLOSEOUT.md)。

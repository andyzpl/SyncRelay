# 0.2.21+a-package.1 阶段 A 打包候选

**2026-10-25 最新状态（已生成，未安装）：** 按授权从当前开发快照建立隔离分支 `codex/a-package-20261025`，提交 `02cf7fb963fb4e34bb2a83a35d68fd1415e2aa87`，运行一次 `build_deb=true` CI `40179290423` / job `121126667336` 并成功。Python **225 项**通过；22 个 Objective-C 目标各执行 3 次；pacing、operations-state 各执行 1 次，media-quota 按矩阵执行 3 次；生产测试、打包和静态核验均通过。该包是普通 `iphoneos-arm` DEB，不是 RootHide 转换。

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

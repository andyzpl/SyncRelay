# 0.2.28+aprobe.3 阶段 A 只读观察候选

日期：2026-10-23。状态：**隔离提交与单次 CI/普通 DEB 核验通过；尚未安装或取得 `.3` 真机证据。**

## 精确身份

- 基线：`51803d43fe068d16c462cea0729264a26cf5f2f5`（`0.2.27+aprobe.2`）。
- 候选分支：`codex/operations-a-device-probe-20261023-aprobe3`。
- 候选构建提交：`6bd977de878af89d19bb09885721ed10c20751be`；树 `d24b83f285e3c27e2394487780f3aecd5160e4fc`。后续仅文档提交（`5deba40`、`e21688a`、`b62c72d`）不改变已核验的包字节；安装/证据必须绑定 `6bd977d` 包。
- 插件版本：`0.2.28+aprobe.3`；包 ID `andyz.syncrelay`；普通 `iphoneos-arm` DEB。
- schema：14；不新增迁移 SQL，不改发送核心、receiver ABI、消息库派发或视频能力。

## 相对 `.2` 的生产逻辑

- `SRStore` 增加只读 `schemaVersion`：仅在构造、迁移事务提交、外键复核和 `PRAGMA user_version == 14` 确认后发布；构造失败不返回对象。
- `SRPanel` 诊断导出 `schemaVersion`；存储不可用时为 `null`。
- receiver/probe 增加精确 local-ID 回读后的匿名 `hookMessageOrdinal` 关联；原始 local/server ID 不导出，停止/重开清空。
- 分析器新增 `--stop-pair`，收紧 `--pair` 的同轮、armed、generation、样本前缀和安全字段检查，并补 schema/local-ID 反例测试。

## 当前证据边界

本地全量 Python 179 项通过。单次 CI [39971512703](https://github.com/andyzpl/SyncRelay/actions/runs/39971512703) 在同一提交上 success：job `120475133844` 内 179 项 Python 通过，新增 Objective-C 用例在 macOS 编译、链接并模拟执行通过；固定 Theos/SDK 生产构建成功。artifact `12510241079` 已下载核验。`schemaVersion=14` 只表示当前版本，不证明迁移前版本、旧行保留、迁移原子性或回滚。图片资源就绪、真实宿主语义、消息库派发、视频、UI 和阶段 A 整体验收仍未通过。

## 单次 CI 与 DEB 核验

- 精确范围：提交 `6bd977d`、树 `d24b83f`、分支 `codex/operations-a-device-probe-20261023-aprobe3`；一次 `workflow_dispatch`、`build_deb=true`。
- 包：`andyz.syncrelay_0.2.28+aprobe.3_iphoneos-arm.deb`，366022 bytes，SHA-256 `d840e4cc8ef95385e5683de84b82e3909d41f72a5521b7180bb954926c4dcccb`。
- artifact zip SHA-256：`4711d9debe9629fdaa677acf37129473326af938c1d4a03a68eaf35713ce5739`，与 GitHub artifact digest 一致；包摘要与包内 `SHA256SUMS` 一致。
- control：包 ID `andyz.syncrelay`、版本 `0.2.28+aprobe.3`、架构 `iphoneos-arm`；载荷仅 `SyncRelay.dylib` 与 `SyncRelay.plist`，过滤仅 `com.tencent.xin`，无安装/卸载脚本。
- 生产二进制：arm64 与 arm64e 两片，均签名；两片均含版本、提交、run、`SRSourceTimeProbe`、`sourceTimeSemanticsVerified`、`imageReadinessObserved`、`schemaVersion` 标记，未链接 Mikoto。
- 证据：`.build-cache/aprobe3/verification.json`、`.build-cache/aprobe3/job-120475133844.log`、`dist/0.2.28+aprobe.3-test-39971512703/ci-provenance.json`。

上述成功只覆盖源码编译、原生模拟和普通 DEB 静态核验。未安装、未 RootHide 转换、未执行设备库迁移或清理数据；`.3` 真机行为与 schema 迁移证据仍需另行授权。`0.2.28+aprobe.3` 高于设备当前 `.2`，但不承诺是 `.2` 全部行为的超集。

## 安装前与安装后门禁

- 安装前先记录设备当前插件版本、当前报告中的 `storageReady`/账号可读状态，并保全现有导出与任务；不得删除数据库、旧 claims 或媒体。普通 DEB 只适用于已确认的安装方式；若设备实际使用 RootHide 环境，必须先另行确认转换与安装方式，不能直接覆盖普通包。
- 若设备库可能是旧 schema，打开 `.3` 会执行既有迁移，属于另需明确授权的数据迁移；没有可恢复备份与回滚方案时不要安装。迁移后不能通过 schema 11 旧包降级。
- 安装后首次只读基线导出必须同时满足 `storageReady=1`、`schemaVersion=14`、发送开关为 0、图片读取为 0、手动捕获 idle；任一项不满足就停止后续采样并保全报告，不改库、不降级、不删除数据。
- `schemaVersion=14` 只证明当前打开版本，不证明迁移前版本、旧行保留、迁移原子性或回滚；不得把它写成设备迁移验收。
- `.3` 的诊断字段新增 `hookMessageOrdinal`，仅表示同轮精确 local-ID 回读后的匿名关联；原始 local/server ID 不导出。`sourceTimeSemanticsVerified` 与 `imageReadinessObserved` 在设备证据完整前必须保持 false。
- 真机步骤、导出字段和通过标准以 `OPERATIONS-A-DEVICE-READINESS.md` 第 3 节为准；页面切换只用 `--pair`，手动停止只用 `--stop-pair`，不能把 `.2` 报告冒充 `.3`。

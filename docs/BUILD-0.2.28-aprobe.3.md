# 0.2.28+aprobe.3 阶段 A 只读观察候选

日期：2026-10-23。状态：**隔离提交与单次 CI/普通 DEB 核验通过；尚未安装或取得 `.3` 真机证据。**

## 精确身份

- 基线：`51803d43fe068d16c462cea0729264a26cf5f2f5`（`0.2.27+aprobe.2`）。
- 候选分支：`codex/operations-a-device-probe-20261023-aprobe3`。
- 候选提交：`6bd977de878af89d19bb09885721ed10c20751be`；树 `d24b83f285e3c27e2394487780f3aecd5160e4fc`。
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

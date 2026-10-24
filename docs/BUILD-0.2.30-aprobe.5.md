# 0.2.30+aprobe.5 阶段 A 生命周期候选

日期：2026-10-24。状态：**普通 DEB 已按精确提交构建并完成静态核验；未安装、未迁移、未取得真机证据。阶段 A 未整体验收。**

## 精确范围

- 基线：`03abb9bfaccd46f05d68877f37f7eefeb92bee6b`（`0.2.29+aprobe.4`）。
- 候选分支：`codex/operations-a-device-probe-20261024-aprobe5`。
- 精确提交：`12e3a999d359a1020d0b01f6c00f82b8f6f80528`；树 `b84d278ddf4bf2c376337d1d956be54939bc6b72`。
- 版本：`0.2.30+aprobe.5`；包 ID `andyz.syncrelay`；普通 `iphoneos-arm` DEB。
- schema：14；不新增迁移 SQL，不改发送核心、receiver 发送 ABI、消息库派发、视频或 B/C UI。
- 生产增量：`SRSourceTimeProbe` 只读 `resumedAfterInactive`；每轮开始/停止/超时清为 false，2 秒宽限内恢复且仍 active 时置 true。只表示“本轮观察到前台 inactive 后在宽限内恢复”，不证明宿主页面切换完成、系统后台或完整生命周期。
- 诊断/分析器：导出 `resumedAfterInactive`；分析器校验类型及“不得与 `inactivePending=true` 同时出现”。旧报告缺该字段仍可单独分析，但不得用作 `.5` 切页恢复证据。
- 本次增量：receiver 在保留严格来源群门禁的前提下，按 receive/outgoing 路径新增有界脱敏 `sessionRejections`（仅 `non_string`、`empty_string`、`other_string`），不导出会话标识；分析器与原生测试同步覆盖。
- 测试/文档：补原生生命周期断言、源码契约守卫、分析器反例，以及设备步骤和导出说明。

## 本地证据

- 隔离树 `py -3 -m unittest discover -s tests -p '*_test.py'`：**185 项通过**。
- `tests.diagnose_report_test`：**45 项通过**。
- `tests.source_time_probe_contract_test`：**11 项通过**。
- 指定 Python 文件 `py_compile` 通过；`git diff --check` 通过，仅有既有 CRLF/LF 提示。
- 精确提交的 [CI run 40064748000](https://github.com/andyzpl/SyncRelay/actions/runs/40064748000) 成功：185 项 Python、全部 Objective-C 程序编译/链接并三轮模拟执行、双架构生产构建和包内容核验通过。
- 普通 DEB：`E:\ios玩机\apps\SyncRelay\dist\0.2.30+aprobe.5-test-40064748000\andyz.syncrelay_0.2.30+aprobe.5_iphoneos-arm.deb`，370364 字节，SHA-256 `f7dab46a09f9291f11de69cdc4c36692eccfeb501ad40743cb2d2d20b9fb3c43`。
- artifact `SyncRelay-development-deb`（ID `12549500239`）下载 ZIP SHA-256 `a853a2cf8560bf8488b661bf1c227f9ee358bca183e21d5da4c8f608ab6a0639`；解包后确认 control 版本、arm64/arm64e、`com.tencent.xin` 过滤、内嵌提交/run、`sessionRejections` 字符串和动态库/Plist 均存在。未做 Apple 信任链验证。
- 以上 CI/打包证据不是安装、迁移或真机证据；产物未安装。

## 已执行外部动作

本次仅按用户批准范围执行：

1. 提交并仅推送非 `main` 分支 `codex/operations-a-device-probe-20261024-aprobe5`；
2. 对精确提交 `12e3a99` 执行一次 `workflow_dispatch(build_deb=true)`，run `40064748000`；
3. 下载并静态核验普通 DEB。

本次不包含安装、RootHide 转换、设备数据库迁移、清理数据、推送 `main` 或发布。若设备库可能是旧 schema，安装会触发既有迁移；没有备份/回滚方案与单独授权不得安装。迁移后不能安装 schema 11 旧包降级。

## 设备判据摘要

- 首份 `.5` 报告：`build.plugin=0.2.30+aprobe.5`、构建提交/run 与批准记录一致、`storageReady=1`、`schemaVersion=14`、发送关闭、图片读取 0、手动捕获 idle、采样 off。
- 切页：开始采样后在微信内切页并在 2 秒内返回，稳定前台后只导出 B。B 应为 `active=true/state=sampling`、`inactivePending=false`、`resumedAfterInactive=true`、receiver armed；不得用导出前的系统分享面板当作切页操作。
- 超时/后台：控制中心或 App Switcher 停留超过 2 秒、或真正后台，应 `active=false/state=inactive`、receiver `armed=false`、`resumedAfterInactive=false`，回前台不自动重开。
- 离线停止：同一轮 active A、手动停止 B，使用 `--stop-pair A B`；A 导出会打开分享面板，若返回时已 inactive，该轮不得冒充手动停止保留。
- 图片资源就绪仍没有安全被动入口，继续 `imageReadinessObserved=false`。

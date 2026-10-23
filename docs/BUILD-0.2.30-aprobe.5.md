# 0.2.30+aprobe.5 阶段 A 生命周期候选

日期：2026-10-24。状态：**普通 DEB 已按精确提交构建并完成静态核验；未安装、未迁移、未取得真机证据。阶段 A 未整体验收。**

## 精确范围

- 基线：`03abb9bfaccd46f05d68877f37f7eefeb92bee6b`（`0.2.29+aprobe.4`）。
- 候选分支：`codex/operations-a-device-probe-20261024-aprobe5`。
- 精确提交：`b0e567c2f6c9c43e1356f0c14f339f5d673b4d34`；树 `acf73174ae47a55f64fae71e39a714966a50d4be`。
- 版本：`0.2.30+aprobe.5`；包 ID `andyz.syncrelay`；普通 `iphoneos-arm` DEB。
- schema：14；不新增迁移 SQL，不改发送核心、receiver 发送 ABI、消息库派发、视频或 B/C UI。
- 生产增量：`SRSourceTimeProbe` 只读 `resumedAfterInactive`；每轮开始/停止/超时清为 false，2 秒宽限内恢复且仍 active 时置 true。只表示“本轮观察到前台 inactive 后在宽限内恢复”，不证明宿主页面切换完成、系统后台或完整生命周期。
- 诊断/分析器：导出 `resumedAfterInactive`；分析器校验类型及“不得与 `inactivePending=true` 同时出现”。旧报告缺该字段仍可单独分析，但不得用作 `.5` 切页恢复证据。
- 测试/文档：补原生生命周期断言、源码契约守卫、分析器反例，以及设备步骤和导出说明。

## 本地证据

- 隔离树 `py -3 -m unittest discover -s tests -p '*_test.py'`：**181 项通过**。
- `tests.diagnose_report_test`：**44 项通过**。
- `tests.source_time_probe_contract_test`：**11 项通过**。
- 指定 Python 文件 `py_compile` 通过；`git diff --check` 通过，仅有既有 CRLF/LF 提示。
- 精确提交的 [CI run 39990147883](https://github.com/andyzpl/SyncRelay/actions/runs/39990147883) 成功：181 项 Python、全部 Objective-C 程序编译/链接并三轮模拟执行、双架构生产构建和包内容核验通过。
- 普通 DEB：`andyz.syncrelay_0.2.30+aprobe.5_iphoneos-arm.deb`，366232 字节，SHA-256 `e9c774d1903cd926c37700f5c88d70c3c4217b07b9999737204fe2cd71f637c6`。
- artifact `SyncRelay-development-deb`（ID `12517762480`）下载 ZIP SHA-256 `12affe81f110e661f78673a60bc7b3250c405d93445cc2045009eac41edd91bd`，与 GitHub 摘要一致；解包后 control 版本、arm64/arm64e 两片、`com.tencent.xin` 过滤、内嵌提交/run、各片 code-signature load command 与 ad-hoc 签名 blob 均核对。未做 Apple 信任链验证。
- 以上 CI/打包证据不是安装、迁移或真机证据；产物未安装。

## 已执行外部动作

本次仅按用户批准范围执行：

1. 提交并仅推送非 `main` 分支 `codex/operations-a-device-probe-20261024-aprobe5`；
2. 对精确提交 `b0e567c` 执行一次 `workflow_dispatch(build_deb=true)`；
3. 下载并静态核验普通 DEB。

本次不包含安装、RootHide 转换、设备数据库迁移、清理数据、推送 `main` 或发布。若设备库可能是旧 schema，安装会触发既有迁移；没有备份/回滚方案与单独授权不得安装。迁移后不能安装 schema 11 旧包降级。

## 设备判据摘要

- 首份 `.5` 报告：`build.plugin=0.2.30+aprobe.5`、构建提交/run 与批准记录一致、`storageReady=1`、`schemaVersion=14`、发送关闭、图片读取 0、手动捕获 idle、采样 off。
- 切页：开始采样后在微信内切页并在 2 秒内返回，稳定前台后只导出 B。B 应为 `active=true/state=sampling`、`inactivePending=false`、`resumedAfterInactive=true`、receiver armed；不得用导出前的系统分享面板当作切页操作。
- 超时/后台：控制中心或 App Switcher 停留超过 2 秒、或真正后台，应 `active=false/state=inactive`、receiver `armed=false`、`resumedAfterInactive=false`，回前台不自动重开。
- 离线停止：同一轮 active A、手动停止 B，使用 `--stop-pair A B`；A 导出会打开分享面板，若返回时已 inactive，该轮不得冒充手动停止保留。
- 图片资源就绪仍没有安全被动入口，继续 `imageReadinessObserved=false`。

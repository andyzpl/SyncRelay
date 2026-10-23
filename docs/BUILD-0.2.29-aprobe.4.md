# 0.2.29+aprobe.4 阶段 A 生命周期候选

日期：2026-10-23。状态：**本地源码与 Python 门禁已复核，隔离候选待冻结；CI/DEB 尚未执行。**

## 精确身份

- 基线：`a6d48dbb94ebb8d44ada62a70a57906046c50efa`（`.3` 文档收口提交；其构建包仍绑定 `6bd977de878af89d19bb09885721ed10c20751be`）。
- 候选分支：`codex/operations-a-device-probe-20261023-aprobe4`。
- 插件版本：`0.2.29+aprobe.4`；包 ID `andyz.syncrelay`；普通 `iphoneos-arm` DEB，预期 arm64/arm64e。
- schema：14；不新增迁移 SQL，不改发送核心、receiver ABI、消息库派发或视频能力。
- 当前本地暂存区为空；主工作区未提交成果未改动。

## 相对 `.3` 的范围

- `SRSourceTimeProbe` 增加前台短暂 inactive 的 2 秒单调时钟宽限；超时停止并释放 receiver，真正后台立即停止，回前台不自动重开。
- `SRPanel` 在 `DidBecomeActive` 取消仍在宽限内的 pending 状态；若超过 2 秒才回到 active，也按超时停止，不把晚激活当成恢复。
- 诊断增加 `inactivePending` 与固定 `inactiveGraceLimit=2`；分析器拒绝未决宽限的页面切换/手动停止成对证据。
- 增加 Objective-C 模拟用例和 Python 契约守卫；版本、control 与 workflow notice 仅作对应更新。
- 不修改 schema、迁移 SQL、消息库派发、视频、B/C UI 或自动捕获。

## 当前本地证据

- `py -3 -m unittest discover -s tests -p '*_test.py'`：**180 项通过**。
- `py -3 -m unittest tests.source_time_probe_contract_test -v`：**10 项通过**。
- `py -3 -m unittest tests.diagnose_report_test -v`：**44 项通过**。
- `py -3 -m py_compile tools/diagnose_report.py tests/diagnose_report_test.py tests/source_time_probe_contract_test.py tests/operations_schema_test.py tests/native_build_contract_test.py`：通过。
- `git diff --check a6d48db`：通过；仅保留既有 CRLF/LF 提示。

以上均不是 Objective-C 编译、链接、模拟执行或真机证据。`sourceTimeSemanticsVerified=false`、`imageReadinessObserved=false` 不变；阶段 A 未整体验收。

## 设备判据

- 页面切换：开始采样后导出 A；在微信内切页并在 **2 秒内**返回；稳定前台后导出 B。`--pair A B` 只接受同 round、generation 不变、两边 `active=true/state=sampling/inactivePending=false`、receiver armed，且 B 保留 A 的样本前缀。超过 2 秒才返回不属于通过。
- 系统 inactive：打开控制中心或 App Switcher 并停留超过 2 秒再返回；应看到 `active=false/state=inactive`、receiver `armed=false`，回前台不自动重开。若回前台仍 active，判失败并停止后续采样。
- 真正后台：`DidEnterBackground` 后应立即停止并释放 receiver；不能用系统 inactive 的宽限代替后台停止。
- 图片资源就绪仍没有安全被动入口。不要为了观察而点图、请求原图、启动手动捕获、下载或准备媒体；本轮不得把 `imageReadinessObserved` 改成 true。

## 待执行的一次 CI/DEB 核验

候选冻结后，只对精确 `.4` 提交执行一次非 `main` 分支推送和一次 `workflow_dispatch`（`build_deb=true`）。核验至少应确认：

- CI 的 Python 计数为 180，Objective-C 编译、链接及三轮模拟执行通过。
- arm64/arm64e 两架构构建成功；control 为 `0.2.29+aprobe.4`。
- 载荷仅 dylib/plist，过滤仅 `com.tencent.xin`，无安装/卸载脚本。
- 两切片签名，且二进制含 `inactivePending`、`inactiveGraceLimit`。
- schema 仍为 14；`deviceVerified=false`、`installationPerformed=false`、`migrationPerformed=false`。

执行后在本文件追加 run、commit/tree、artifact、包摘要和日志证据。CI/DEB 通过仍不等于真机或阶段 A 验收。

## 安装与设备边界

- 本次授权不包括安装、RootHide 转换、设备数据库迁移或清理数据。
- 若后续另行授权安装，先保全现有诊断与任务；普通 DEB 只适用于已确认的安装方式，不能把普通包直接覆盖到未确认的 RootHide 环境。
- 设备若仍为 schema 11，首次打开 `.4` 会执行既有 11→14 迁移；没有备份/回滚方案不得安装。迁移后不能安装 schema 11 的 `timeprobe.1` 降级。
- 安装后首次只读基线必须满足包身份、`storageReady=1`、`schemaVersion=14`、发送关闭、`imageReads=0`、手动捕获 idle；否则停止采样并保全报告。
- 真机操作、导出字段和通过标准以 `OPERATIONS-A-DEVICE-READINESS.md` 第 3 节为准。页面切换只用 `--pair`，手动停止只用 `--stop-pair`，不能把 `.2`/`.3` 报告冒充 `.4`。

# 0.2.29+aprobe.4 阶段 A 生命周期候选

日期：2026-10-24。状态：**本地源码与 Python 门禁已复核；两次精确提交 CI 均未完成，第一次是 lifecycle 测试期望错误，第二次是既有异步等待在慢 runner 上超时。测试等待已改为有界条件轮询并本地通过；第三次 CI/DEB 尚未获准，当前没有可用 DEB。**

## 精确身份

- 基线：`a6d48dbb94ebb8d44ada62a70a57906046c50efa`（`.3` 文档收口提交；其构建包仍绑定 `6bd977de878af89d19bb09885721ed10c20751be`）。
- 候选分支：`codex/operations-a-device-probe-20261023-aprobe4`。
- 插件版本：`0.2.29+aprobe.4`；包 ID `andyz.syncrelay`；普通 `iphoneos-arm` DEB，预期 arm64/arm64e。
- schema：14；不新增迁移 SQL，不改发送核心、receiver ABI、消息库派发或视频能力。
- 隔离工作树在原 `.4` 候选上只新增 `tests/source_time_probe_test.m` 的有界等待辅助函数及四处正向等待；生产代码、版本和 schema 不变。
- 主工作区 `HEAD` 仍为 `f652d5e97180a15f43437fd1e449f3b3063e87fc`，暂存区为空，既有未提交成果未改动。

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
- 测试修复后再次执行全量 Python：**180 项通过**；探针契约 **10 项通过**、分析器 **44 项通过**。

以上均不是 Objective-C 编译、链接、模拟执行或真机证据。`sourceTimeSemanticsVerified=false`、`imageReadinessObserved=false` 不变；阶段 A 未整体验收。

## 设备判据

- 页面切换：开始采样后导出 A；在微信内切页并在 **2 秒内**返回；稳定前台后导出 B。`--pair A B` 只接受同 round、generation 不变、两边 `active=true/state=sampling/inactivePending=false`、receiver armed，且 B 保留 A 的样本前缀。超过 2 秒才返回不属于通过。
- 系统 inactive：打开控制中心或 App Switcher 并停留超过 2 秒再返回；应看到 `active=false/state=inactive`、receiver `armed=false`，回前台不自动重开。若回前台仍 active，判失败并停止后续采样。
- 真正后台：`DidEnterBackground` 后应立即停止并释放 receiver；不能用系统 inactive 的宽限代替后台停止。
- 图片资源就绪仍没有安全被动入口。不要为了观察而点图、请求原图、启动手动捕获、下载或准备媒体；本轮不得把 `imageReadinessObserved` 改成 true。

## 待执行的一次 CI/DEB 核验

### 两次 CI 失败（2026-10-23）

- 精确提交 `a6554d2c1598f33fd5180043a46dcbb160b3987c`、树 `06c510dfa2859a26cdcddfcdc8756a30b9049f60`，run [39982445082](https://github.com/andyzpl/SyncRelay/actions/runs/39982445082)，job `120512938439`。
- Python **180 项通过**；pacing、operations-state 及前 22 个 Objective-C 程序均输出 PASS。`source-time-probe-test` 编译并执行到新增 `checkInactiveGrace()` 后，在“超时后再次调用用户停止”的断言失败：期望 `state=stopped`，实际保持 `inactive`。
- 核对源码后确认这是测试期望错误：`stopForReason:` 在采样已非 active 时按既有幂等规则不覆盖自动停止原因，`inactive` 应保留。生产生命周期逻辑不因此修改；测试改为验证手动停止不会清除 `inactivePending`，且状态仍为 `inactive`。
- 该 run 在 `Test production core on macOS` 步骤失败，后续安装工具链、DEB 构建、包核验和上传全部跳过；没有 DEB artifact。
- 修正测试后的提交 `b9e1fcbc6523450f46525db394a9a0e2b78af900`、树 `9fba2a718961793c87817936fa7e86b6f8b1f47e`，run [39983266913](https://github.com/andyzpl/SyncRelay/actions/runs/39983266913)，job `120515785520`。
- 第二次 run 同样通过 Python **180 项**并完成全部 Objective-C 编译/链接；`source-time-probe-test` 在更早的既有 `checkOwnAndGeneration()` 第 202 行失败：固定等待 1.1 秒后未取得本人异步样本。第一次 run 中同一用例曾通过，两次之间生产代码未变，新增 lifecycle 用例尚未执行，因此这是既有测试定时不稳，不能记成 lifecycle 回归。
- 第二次 run 未生成 DEB artifact；lifecycle 修复仍没有成功的原生执行证据。当前已使用两次 CI，第三次必须另行获准。

### 本地定时修复（2026-10-24）

- 只改 `tests/source_time_probe_test.m`：把 `checkOwnAndGeneration()` 及读回关联用例中需要等待新样本出现的固定 1.1 秒检查改为最多 5 秒的有界条件轮询；仍保留负向断言所需的固定观察窗口，避免把“没出现”误判成失败或通过。
- 辅助循环按 50 ms 切片运行主 run loop，总时限明确；不增加生产调度、网络、媒体读取或任何新探针入口。
- 本地全量 Python 180、探针契约 10、分析器 44 通过；Objective-C 只能在 macOS CI 编译/执行，本轮 Windows 本地未执行。

### 待批准的第三次 CI/DEB

候选冻结后，只对精确 `.4` 提交执行一次非 `main` 分支推送和一次 `workflow_dispatch`（`build_deb=true`）。核验至少应确认：

- CI 的 Python 计数为 180，Objective-C 编译、链接及三轮模拟执行通过。
- arm64/arm64e 两架构构建成功；control 为 `0.2.29+aprobe.4`。
- 载荷仅 dylib/plist，过滤仅 `com.tencent.xin`，无安装/卸载脚本。
- 两切片签名，且二进制含 `inactivePending`、`inactiveGraceLimit`。
- schema 仍为 14；`deviceVerified=false`、`installationPerformed=false`、`migrationPerformed=false`。

修复提交冻结并另行获准后，才可执行第三次 CI；执行后在本文件追加 run、commit/tree、artifact、包摘要和日志证据。CI/DEB 通过仍不等于真机或阶段 A 验收。

## 安装与设备边界

- 本次授权不包括安装、RootHide 转换、设备数据库迁移或清理数据。
- 若后续另行授权安装，先保全现有诊断与任务；普通 DEB 只适用于已确认的安装方式，不能把普通包直接覆盖到未确认的 RootHide 环境。
- 设备若仍为 schema 11，首次打开 `.4` 会执行既有 11→14 迁移；没有备份/回滚方案不得安装。迁移后不能安装 schema 11 的 `timeprobe.1` 降级。
- 安装后首次只读基线必须满足包身份、`storageReady=1`、`schemaVersion=14`、发送关闭、`imageReads=0`、手动捕获 idle；否则停止采样并保全报告。
- 真机操作、导出字段和通过标准以 `OPERATIONS-A-DEVICE-READINESS.md` 第 3 节为准。页面切换只用 `--pair`，手动停止只用 `--stop-pair`，不能把 `.2`/`.3` 报告冒充 `.4`。

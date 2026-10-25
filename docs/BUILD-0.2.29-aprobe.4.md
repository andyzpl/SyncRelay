# 0.2.29+aprobe.4 阶段 A 生命周期候选

日期：2026-10-24。状态：**第四次精确提交 CI 成功，已生成并下载核验普通 DEB；尚无安装、RootHide 转换、设备数据库迁移或真机证据。阶段 A 未整体验收。**

## 精确身份

- 基线：`a6d48dbb94ebb8d44ada62a70a57906046c50efa`（`.3` 文档收口提交；其构建包仍绑定 `6bd977de878af89d19bb09885721ed10c20751be`）。
- 候选分支：`codex/operations-a-device-probe-20261023-aprobe4`。
- 插件版本：`0.2.29+aprobe.4`；包 ID `andyz.syncrelay`；普通 `iphoneos-arm` DEB，预期 arm64/arm64e。
- schema：14；不新增迁移 SQL，不改发送核心、receiver ABI、消息库派发或视频能力。
- 隔离工作树在原 `.4` 候选上只修改测试：有界等待辅助函数、四处正向等待、BOOL 显式转换和对应源码守卫；生产代码、版本和 schema 不变。
- 主工作区 `HEAD` 仍为 `f652d5e97180a15f43437fd1e449f3b3063e87fc`，暂存区为空，既有未提交成果未改动。2026-10-24 复核时，主工作区的 `SRSourceTimeProbe.h/.m`、`UI/SRPanel.m`、`tools/diagnose_report.py` 及两份来源时间测试 blob 与该提交一致；`Core/SRVersion.h`/`control` 仍为 `0.2.21`，因此主工作区本身不是可直接产出本包的版本化树。

## 相对 `.3` 的范围

- `SRSourceTimeProbe` 增加前台短暂 inactive 的 2 秒单调时钟宽限；超时停止并释放 receiver，真正后台立即停止，回前台不自动重开。
- `SRPanel` 在 `DidBecomeActive` 取消仍在宽限内的 pending 状态；若超过 2 秒才回到 active，也按超时停止，不把晚激活当成恢复。
- 诊断增加 `inactivePending` 与固定 `inactiveGraceLimit=2`；分析器拒绝未决宽限的页面切换/手动停止成对证据。
- 增加 Objective-C 模拟用例和 Python 契约守卫；版本、control 与 workflow notice 仅作对应更新。
- 不修改 schema、迁移 SQL、消息库派发、视频、B/C UI 或自动捕获。

## 当前本地证据

- `py -3 -m unittest discover -s tests -p '*_test.py'`：**181 项通过**。
- `py -3 -m unittest tests.source_time_probe_contract_test -v`：**11 项通过**。
- `py -3 -m unittest tests.diagnose_report_test -v`：**44 项通过**。
- `py -3 -m py_compile tools/diagnose_report.py tests/diagnose_report_test.py tests/source_time_probe_contract_test.py tests/operations_schema_test.py tests/native_build_contract_test.py`：通过。
- `git diff --check a6d48db`：通过；仅保留既有 CRLF/LF 提示。
- 第三次失败的最小修复后再次执行全量 Python：**181 项通过**；探针契约 **11 项通过**、分析器 **44 项通过**。

以上均不是 Objective-C 编译、链接、模拟执行或真机证据。`sourceTimeSemanticsVerified=false`、`imageReadinessObserved=false` 不变；阶段 A 未整体验收。

## 设备判据

- 页面切换：开始采样后在微信内切页，并在 **2 秒内**返回稳定前台，再只导出 B。导出会打开系统分享面板，属于系统级 inactive；**切页前导出 A 会额外打断采样**。B 应满足 `active=true/state=sampling`、`inactivePending=false`、receiver armed，且本轮没有新增 receiver stop/environment_blocked。`.4` 本身没有 `resumedAfterInactive` 字段；若需区分“切页内短暂 inactive”和“系统切换”，必须另建包含该只读字段的候选，不能把 `.4` 的单份 B 写成完整 A/B。`--pair` 只用于外部已有合法 A/B 的回归。超过 2 秒才返回不属于通过。
- 系统 inactive：打开控制中心或 App Switcher 并停留超过 2 秒再返回；应看到 `active=false/state=inactive`、receiver `armed=false`，回前台不自动重开。若回前台仍 active，判失败并停止后续采样。
- 真正后台：`DidEnterBackground` 后应立即停止并释放 receiver；不能用系统 inactive 的宽限代替后台停止。
- 图片资源就绪仍没有安全被动入口。不要为了观察而点图、请求原图、启动手动捕获、下载或准备媒体；本轮不得把 `imageReadinessObserved` 改成 true。

## 第四次 CI/DEB 核验（2026-10-24）

- 精确提交 `03abb9bfaccd46f05d68877f37f7eefeb92bee6b`，树 `b99c85596ad773a42bfc54998c8826236cd7e869`，非 `main` 分支 `codex/operations-a-device-probe-20261023-aprobe4`。
- [run 39986009254](https://github.com/andyzpl/SyncRelay/actions/runs/39986009254)，job `120525271412`，结论 `success`；只派发一次，未重跑前三次失败 run。
- Python **181 项通过**；全部 Objective-C 程序编译、链接并完成三轮模拟执行，`source-time-probe-test` 包含新增 `checkInactiveGrace()` 通过。日志中 112 条 `PASS:` 是分项/重复记录，不是程序数。
- 生产源码在固定 Theos/SDK 上完成 arm64/arm64e 编译、链接和签名；`lipo -verify_arch arm64 arm64e` 通过。`-multiply_defined is obsolete` 是链接器警告，不是构建失败。
- artifact `12514559998` 只有一个，artifact ZIP SHA-256 `e52dc5b5f9e39e6a685535e6bdfbb4fc83de5169c8a6a6d6e79725513c424885`。
- 包 `andyz.syncrelay_0.2.29+aprobe.4_iphoneos-arm.deb`，366852 字节，SHA-256 `9a45171f6270cbae4946c620b0e29e6925bec589bf555e9a30888aa91aba29af`。
- control：`Package=andyz.syncrelay`、`Version=0.2.29+aprobe.4`、`Architecture=iphoneos-arm`；描述明确为 2 秒前台 inactive 宽限、schema 14、无媒体准备/自动捕获/运营 UI。
- 载荷只有 `SyncRelay.dylib` 与 `SyncRelay.plist`；注入过滤只有 `com.tencent.xin`；control 仅 `control`/`md5sums`，无 preinst/postinst/prerm/postrm。
- 两切片均带有效代码签名；两切片均含版本、提交、run、`SRSourceTimeProbe`、`sourceTimeProbe`、`sourceTimeSemanticsVerified`、`imageReadinessObserved`、`schemaVersion`、`inactivePending`、`inactiveGraceLimit`、`noteApplicationInactive`、`noteApplicationActive` 标记，且不依赖 Mikoto。
- 下载目录：`dist/0.2.29+aprobe.4-test-39986009254/`；完整机读记录为 `.build-cache/aprobe4/verification.json` 与包目录内 `ci-provenance.json`，日志为 `.build-cache/aprobe4/job-120525271412.log`。
- 核验结果仍是 CI 编译/链接/模拟执行和 DEB 静态核验，**不是真机、宿主 ABI、页面切换、数据库迁移或阶段 A 验收**。

### 前三次 CI 失败（2026-10-23 至 2026-10-24）

- 精确提交 `a6554d2c1598f33fd5180043a46dcbb160b3987c`、树 `06c510dfa2859a26cdcddfcdc8756a30b9049f60`，run [39982445082](https://github.com/andyzpl/SyncRelay/actions/runs/39982445082)，job `120512938439`。
- Python **180 项通过**；pacing、operations-state 及前 22 个 Objective-C 程序均输出 PASS。`source-time-probe-test` 编译并执行到新增 `checkInactiveGrace()` 后，在“超时后再次调用用户停止”的断言失败：期望 `state=stopped`，实际保持 `inactive`。
- 核对源码后确认这是测试期望错误：`stopForReason:` 在采样已非 active 时按既有幂等规则不覆盖自动停止原因，`inactive` 应保留。生产生命周期逻辑不因此修改；测试改为验证手动停止不会清除 `inactivePending`，且状态仍为 `inactive`。
- 该 run 在 `Test production core on macOS` 步骤失败，后续安装工具链、DEB 构建、包核验和上传全部跳过；没有 DEB artifact。
- 修正测试后的提交 `b9e1fcbc6523450f46525db394a9a0e2b78af900`、树 `9fba2a718961793c87817936fa7e86b6f8b1f47e`，run [39983266913](https://github.com/andyzpl/SyncRelay/actions/runs/39983266913)，job `120515785520`。
- 第二次 run 同样通过 Python **180 项**并完成全部 Objective-C 编译/链接；`source-time-probe-test` 在更早的既有 `checkOwnAndGeneration()` 第 202 行失败：固定等待 1.1 秒后未取得本人异步样本。第一次 run 中同一用例曾通过，两次之间生产代码未变，新增 lifecycle 用例尚未执行，因此这是既有测试定时不稳，不能记成 lifecycle 回归。
- 第二次 run 未生成 DEB artifact；lifecycle 修复仍没有成功的原生执行证据。
- 第三次精确提交 `295c40847fdfcd9d123c36892440a41db4ba0f0b`、树 `144f10f0f1704754fef1dafa908f9440e130c7fa`，run [39985086993](https://github.com/andyzpl/SyncRelay/actions/runs/39985086993)，job `120522058236`。Python **180 项通过**，pacing 与 operations-state 通过；`source-time-probe-test` 在编译阶段出现 4 处 `incompatible block pointer types passing 'int (^)(void)' to parameter of type 'BOOL (^)(void)'`，Objective-C 程序未执行，后续打包/核验/上传全部跳过，无 DEB artifact。

### 本地定时修复（2026-10-24）

- 只改 `tests/source_time_probe_test.m`：把 `checkOwnAndGeneration()` 及读回关联用例中需要等待新样本出现的固定 1.1 秒检查改为最多 5 秒的有界条件轮询；仍保留负向断言所需的固定观察窗口，避免把“没出现”误判成失败或通过。
- 第三次失败后，把四处等待条件显式转换为 `BOOL`，满足辅助函数声明和 `-Werror`；同时在 `tests/source_time_probe_contract_test.py` 增加源码守卫，要求 4 个调用都使用该类型转换。没有改生产代码或放宽编译告警。
- 辅助循环按 50 ms 切片运行主 run loop，总时限明确；不增加生产调度、网络、媒体读取或任何新探针入口。
- 本地全量 Python **181**、探针契约 **11**、分析器 **44** 通过；Objective-C 只能在 macOS CI 编译/执行，本轮 Windows 本地未执行。

### 主工作区回填核对（2026-10-24）

- 只同步 `tests/source_time_probe_test.m` 与 `tests/source_time_probe_contract_test.py` 到主工作区；两份文件 Git blob 与 `03abb9b` 完全一致，分别为 `4be1cda5e117ad2b3b39a385b28b92073bf74649` 和 `3db9283f122417386ff8aa36996c0bb9fb15a102`。
- 主工作区执行全量 Python **181 项通过**；探针契约 **11 项通过**；分析器 **44 项通过**；指定 5 个 Python 文件 `py_compile` 通过；`git diff --check` 通过，仅有既有 CRLF/LF 提示。
- 主工作区 HEAD、暂存区和既有未提交文件未改变；没有重跑相同源码 CI、重新打包、安装、迁移或真机测试。
- 微信临时目录截至本次复核没有 2026-10-24 的新诊断，最新仍为 `.2` 的 `10231`（2026-10-23 20:54）。因此本文件仍记录“无安装/真机证据”，不因口头“已经安装”升级结论。

### 已执行的第四次范围

1. 将候选分支 `codex/operations-a-device-probe-20261023-aprobe4` 从 `295c408` 快进推送到 `03abb9b`；未推送 `main`。
2. 对精确提交 `03abb9b` 执行一次 `workflow_dispatch(build_deb=true)`；未重跑前三次失败 run。
3. 下载 artifact 到 `.build-cache/aprobe4` 与 `dist/0.2.29+aprobe.4-test-39986009254/`，完成身份、架构、control、载荷、过滤、签名、哈希和二进制标记核验。
4. 未安装、未迁移设备库、未 RootHide 转换、未自动捕获、未发送、未读取媒体。

## 安装与设备边界

- 第四次 CI/DEB 授权不包括安装、RootHide 转换、设备数据库迁移或清理数据；这些动作仍未执行。
- 若后续另行授权安装，先保全现有诊断与任务；普通 DEB 只适用于已确认的安装方式，不能把普通包直接覆盖到未确认的 RootHide 环境。
- 设备当前加载 `.2`；`.4` 若首次打开 schema 11 设备库，会执行既有 11→14 迁移。没有设备数据保全/回滚方案和单独授权不得安装。迁移后不能安装 schema 11 的 `timeprobe.1` 降级。
- 安装后首次只读基线必须满足包身份、`storageReady=1`、`schemaVersion=14`、发送关闭、`imageReads=0`、手动捕获 idle；否则停止采样并保全报告。
- 真机操作、导出字段和通过标准以 `OPERATIONS-A-DEVICE-READINESS.md` 第 3 节为准。页面切换只用 `--pair`，手动停止只用 `--stop-pair`，不能把 `.2`/`.3` 报告冒充 `.4`。

# 阶段 A：macOS 原生回归验收记录

**2026-10-25 最新打包状态（当前精确快照，未安装）：** 按授权从当前开发快照建立隔离分支 `codex/a-package-20261025`，提交 `02cf7fb963fb4e34bb2a83a35d68fd1415e2aa87`，运行一次 `build_deb=true` CI `40179290423` / job `121126667336` 并成功。Python **225 项**通过；22 个 Objective-C 目标各执行 3 次，pacing/operations-state 各执行 1 次、media-quota 执行 3 次；普通 `iphoneos-arm` DEB 已由 CI 用 `dpkg-deb` 检查并用 `lipo` 验证 `arm64`/`arm64e`。包 SHA-256 为 `bedb3a3a722dd10dbeed51ee857e4e9eaaf6fecd83666c6ee235df0a9e9692d5`，artifact ID `12592629882`，详情见 [BUILD-0.2.21-apackage.1.md](BUILD-0.2.21-apackage.1.md)。本次没有安装、迁移、清理设备数据或新增真机采样；A 的真实宿主语义仍未整体验收，B/C 继续关闭。

**2026-10-25 最新原生结果（通过，未打包）：** 隔离分支 `codex/a-probe-clock-invalid-native-20261025-r3`、提交 `aa01abe451a5bd4254f6e3df829ac4fdb8032f29`、tree `bca12cb7a48ba08fa119725936e61afcc1119b1f` 在 CI `40169810412` / job `121098186039` 以 `build_deb=false` 运行一次并成功。Python **224 项**通过；22 个 Objective-C 目标完成编译/链接并各执行 3 次（66 次），3 个 C 目标按配置执行 5 次；25 个目标共 71 次配置执行与成功标记逐项一致。`source-time-probe-test` 三轮均通过，包含字段夹具修正和 inactive 入口 NAN/负值/异常的安全停止用例；生产测试没有失败。5 个打包步骤全跳过、artifact=0，无生产包、安装、迁移或设备动作。主工作区 main/HEAD/真实暂存区保持原样；A 的原生模拟门槛已补齐，但真实宿主语义仍不等于模拟通过。详见 [本地收口记录](OPERATIONS-A-LOCAL-CLOSEOUT.md)。

**2026-10-25 修复前快照的原生回归（不覆盖本轮探针增量）：** 分支 `codex/a-native-validation-20261025`、提交 `d02de94` 经 CI `40154276666` / job `121052172029` 以 `build_deb=false` 通过；当时 Python **211 项**，22 个 Objective-C 目标编译/链接并各执行 **3 次**。3 个 C 目标编译通过，其中 `pacing-test`、`operations-state-test` 各 **1 次**，`media-quota-test` **3 次**。此前已根据实际日志纠正旧“三个 C 均三轮”表述；Windows 本地曾分别运行三轮，不得混写成 macOS CI 次数。后续 Python 分析器/护栏及本轮 Objective-C 探针/测试变更均未纳入该次 CI；没有新的 CI、生产 DEB、安装、迁移或设备动作。

**2026-10-25 历史原生回归（迁移路径移除前快照）：** 隔离分支 `codex/operations-a-local-closeout-native-20261025` 的提交 `c35fb7181bc211d2b1d19e1de6c92a9b8bee9609`（树 `e5f3928a0ac229a150965e8d6a132d8edc595158`）在 CI `40147383615` / job `121031524021` 以 `build_deb=false` 完成当时快照的 Python **214 项**、22 个 Objective-C 原生测试目标（三轮）及 3 个 C 目标；打包工具、DEB、安装、迁移和设备步骤均跳过。该证据不能覆盖当前移除旧库升级路径后的源码；不等于当前源码或真机阶段 A 验收通过。

**2026-10-25 本地集中检查（当前状态以顶部成功 CI 为准）：** 本次实查发现相邻 OwnHide 已有 SDK/libclang/Zig 缓存，未下载/安装工具。三个 C 程序已用 Zig 0.14.1 在 Windows 实际编译，各运行三轮通过；缓存 libclang 18.1.1 / iPhoneOS 16.5 SDK 对 arm64/arm64e 共 **106 单元**完成零诊断语法检查。顶部隔离 CI 快照为 Python **224 项**，本地诊断边界增量后完整 Python **225 项**；当前精确 CI 快照由顶部 CI `40169810412` 完成 Objective-C 编译/链接/三轮执行，新增 1 项尚未进入 CI。较早 211/214 项只属于历史快照。详细矩阵见 [本地收口记录](OPERATIONS-A-LOCAL-CLOSEOUT.md)。下方“无工具链”是此前当轮记录，不描述本次发现；A 仍未整体验收。

**2026-10-25 原生已验证项（仍未打包）：** SRStore 增加库图片登记匹配与失效 token 的 owner 保留护栏；`tests/library_test.m` 新增真实自有文件的未登记 payload 拒绝，以及缺失/损坏文件同时被历史版本、隐藏条目、冻结任务/run 引用时的行级保留与重开用例。上述用例已由对应精确源码隔离 CI 编译/链接/三轮执行；本段仍不提供生产 DEB 或真机证据。

**设备状态补充（2026-10-24）：** `102427` 只有当前 schema 14、无迁移执行的基线证据；`102428` 没有采样回调，已记证据不足并停止采样。不再要求重复同类设备操作；本文件的 macOS 模拟证据不能替代迁移或真机来源语义证据。


> **当前节点（2026-10-24）：** 该文档记录的是隔离源码的 macOS 编译、链接和模拟执行，不能替代真机验收。最新设备包 `.5` 的 CI/DEB 身份和报告证据见 `BUILD-0.2.30-aprobe.5.md` 与 `OPERATIONS-A-DEVICE-READINESS.md`；阶段 A 仍未整体验收。下方各原生回归结果保留为各自提交的历史证据，不得与 `.5` 真机结果混写。

日期：2026-10-22。结果：**本次隔离源码快照的 macOS 编译、链接和模拟执行通过；不代表真实微信来源时间语义或阶段 A 整体验收通过。**

## 来源与运行身份

- 仓库：用户指定的公开构建仓库 `andyzpl/SyncRelay`。
- 独立分支：`codex/operations-a-native-20261022`。
- 源码提交：`cadae524da26b01ab31b3fc609dc6bcb71699dec`。
- 基线：`f652d5e97180a15f43437fd1e449f3b3063e87fc`；树：`3b1709d053386ce0f33792914c827f37b7b2e543`。
- 工作流：`build.yml`，手动触发且 `build_deb=false`。
- 运行：[39723869319](https://github.com/andyzpl/SyncRelay/actions/runs/39723869319)，job `119643252449`，结论 `success`。
- 环境：GitHub 托管 Intel runner，`macos-15-intel`，实际 macOS `15.7.9`；测试步骤于北京时间 12:42:40–12:45:52 执行。

快照只包含运营回归需要的 14 个变更文件：工作流、运营状态 C 文件、协调器、存储、运行日志及对应测试。没有包含并行开发的消息类型探针、接收适配未提交改动、报告分析脚本或文档；没有上传个人诊断或第三方文件。当前工作区 `main` 的 HEAD 和真实暂存区未移动；测试提交只存在于独立分支，不等于已合并主线。

## 实际执行结果

| 检查 | 结果与口径 |
| --- | --- |
| Python 回归 | 86 项通过；本地完整工作区为 96 项，差额是刻意未纳入该快照的 10 项并行类型探针测试，不是漏跑运营用例 |
| C 状态机与间隔 | 两个程序均在 macOS 实际编译并执行通过；另有本地 Windows C 执行证据 |
| Objective-C 编译/链接 | 18 个测试程序全部成功；使用真实 Foundation、SQLite、ImageIO/CoreGraphics 等系统框架 |
| Objective-C 执行 | 每个程序连续运行 3 轮，共 54 次程序执行，均通过 |
| 近期重点回归 | 协调器故障撤销许可、延后生命周期、账号/内容/运行身份、归档读回及时间回拨等用例均在三轮执行中通过 |
| 来源时间模拟 | 声明 ABI、新旧/同秒边界、延迟本人消息与图片、时间证据冻结及代次取消用例三轮通过；宿主对象仍为模拟对象 |
| 打包与产物 | 安装构建工具、Theos/SDK 设置、构建 DEB、校验包、上传产物五步均 `skipped`；artifact 数为 0 |

日志共出现 91 条 `PASS:`；其中包含 C 程序及重复执行的分项输出，**不能解释为 91 个独立原生测试程序**。18 个 Objective-C 程序为：store、adapter、pipeline、relay-coordinator、automatic-progress、small-group-session、group-planner、receive、plan-queries、send-probe、single-text-send-adapter、text-send-host、settings-entry、runtime-log、image-source、image-send-probe、image-send-host、image-asset。

本轮未发现需要修正的原生编译、链接或模拟执行失败，没有因此继续增加产品范围或改写已验证发送核心。

## 证据保存

以下为本地忽略目录中的运行记录，不包含凭据：

- `.build-cache/operations-native-tests/round1.json`：精确源码清单、SHA、初始源文件散列与请求身份。
- `.build-cache/operations-native-tests/round1-status.json`：运行、job 和各步骤的最终状态。
- `.build-cache/operations-native-tests/round1-verification.json`：源码 SHA、通过结果、86 项 Python、91 条输出及零产物复核。
- `.build-cache/operations-native-tests/round1-job-119643252449.log`：下载保存的实际 runner 日志。

本地运营源码/测试与该提交的 blob 已逐项核对。后续若改动这些源码，需要重新运行对应测试，不能把本次结果外推到未测版本。

## 阶段结论与下一步

已补齐此前缺失的 macOS 原生执行证据。仍缺真实微信 `m_uiCreateTime` 的声明 ABI、单位、时间含义和离线补同步行为证据；模拟通过、getter 存在、消息有服务器 ID 都不能替代这些证据。

下一步限定为来源时间的只读专项真机核验，准备条件和矩阵见 `docs/OPERATIONS-SOURCE-TIME-DEVICE-CHECK.md`。上述原生验收时生产 UI 尚未接入时间证据回调；随后新增的文字只读采样是独立代码快照，不能直接继承上述测试结果，状态见下一节。该次原生回归没有专项验证 DEB，也没有启用 `build_deb`，旧消息类型探针包不能冒充来源时间验证包。后续独立打包证据见本文末节。

阶段 A 尚未整体验收；不进入 B UI 实现、不开放 C 自动捕获。重发、目标级账本、人工排除、新群自动入组、免密码备份恢复仍按 v2 的 C 阶段推进，不能据本次底层回归宣称已交付。

## 后续：文字只读采样新增代码的独立回归

独立分支 `codex/operations-source-time-probe-20261022`，不移动工作区 main/真实暂存区。两轮均为 `build_deb=false`，各自结果只适用于其精确源码，不能把首轮通过直接外推给后续代码。

| 轮次 | 精确源码与运行 | 结果 |
| --- | --- | --- |
| 文字采样初版 | `9cab7018a845b1258827857843b245f1be59bf89`，树 `0e70aa3baaf3524ae822998523b3956879bbe01f`；[39726737112](https://github.com/andyzpl/SyncRelay/actions/runs/39726737112)，job `119652253571` | success；19 个 Objective-C 程序实际编译/链接并各执行三轮，91 项 Python、两个 C 程序通过；新采样程序 PASS 标记三次；五个打包/上传步骤跳过、artifact 0 |
| 同步通知重开轮次围栏 | `91b310d84129aa42ce2ea292ca5d846f0a5200c0`，树 `405b1fcaf51f56790dfcd451bb4ed826e72f2a60`；[39727441563](https://github.com/andyzpl/SyncRelay/actions/runs/39727441563)，job `119654509224` | success；19 个 Objective-C 程序实际编译/链接并各执行三轮，92 项 Python、两个 C 程序通过；新采样程序（含重开轮次用例）PASS 标记三次；五个打包/上传步骤跳过、artifact 0 |

首轮 runner 为 macos-15-intel，实际 macOS 15.7.9；测试步骤于北京时间 13:13:04–13:17:44 执行。共 94 条 PASS 输出，包含重复/分项标记，不是 94 个独立测试程序。19 个程序各三轮为 57 次程序执行；这些是 Foundation/运行时模拟，不是 UIKit 真机渲染或宿主语义认证。

第二轮同为 macos-15-intel、实际 macOS 15.7.9；测试步骤于北京时间 13:20:29–13:23:39 执行。同样是 19 个程序各三轮、57 次执行及 94 条分项/重复 PASS 输出。本地工作区与隔离快照分别通过 arm64/arm64e 98 单元语法检查，均为零诊断；与 CI 精确提交的源码 blob 和原始文件散列逐项一致。并行类型文件散列、工作区 HEAD 和真实暂存区均核对未变。

本次精确快照在前轮 14 个运营变更文件之外增加 Makefile、UI/SRPanel.m、语法检查清单、SRSourceTimeProbe 的 h/m 和两个测试文件，共 21 个相对工作区 HEAD 的文件；不加入并行类型改动、诊断、第三方包或用户私有文件变更，不移动工作区 main/真实暂存区。

最新本地完整工作区 102 项 Python、C 状态/间隔及 arm64/arm64e 98 单元语法检查通过；第二轮隔离快照本地 92 项 Python 通过，差额仍为刻意未纳入的 10 项并行类型探针测试。新增原生 `source-time-probe-test` 覆盖原方法链、首次时间保留、本人延迟、历史/重复/同秒/异常时间、16 样本/120 秒、停止重开旧代次、账号/配置/环境失效、声明能力缺项、脱敏、图片准备调用陷阱与普通手动捕获回调回归。

首轮后复核补充模拟边界：配置失效的停止通知中，消费者明确重开新轮；若模拟时钟回拨令新旧监听时间恰好相同，原消费栈不能将旧证据写入新轮。新增轮次围栏与测试，源码守卫在未修复实现失败、修复后通过；未对旧 Objective-C 实现执行失败复现。第二轮只改采样实现与两个对应测试文件，修复后的完整原生用例现已三轮执行通过。

本地证据前缀为 `.build-cache/operations-native-tests/source-time-round1` / `source-time-round2`，分别保存 manifest、status、verification 和 job 日志；该轮工作区语法日志为 `.build-cache/syntax-source-time-probe-round2.log`，精确隔离快照语法日志为 `.build-cache/syntax-source-time-snapshot-round2.log`。这两次未构建来源时间 DEB，不要求用户安装旧包。文字子集的工程验证已到可准备阶段包的检查点，整张来源时间矩阵仍缺图片/逐对象 ABI 入口及全部真机证据，不标阶段 A 整体验收。

## 后续：文字子集专项包已构建核验

独立分支 `codex/operations-source-time-device-20261022`，精确提交 `c9be95413384e30416abdc356505295a947ac9df`、树 `cb9ee97554f08e3442e30982bba08e7b800c1692`；父提交为上述第二轮源码。只改隔离版本 `0.2.21+timeprobe.1`、control 范围说明及产物 notice，生产逻辑/测试不变。

一次 `build_deb=true` 触发 [39730283085](https://github.com/andyzpl/SyncRelay/actions/runs/39730283085)，job `119663509751`，结果 success。macos-15-intel、实际 macOS 15.7.9；原生回归于 UTC 05:50:21–05:54:47 实际执行，再次通过 19 个 Objective-C 程序各三轮、92 项 Python、两个 C 程序。57 次 Objective-C 程序执行、94 条重复/分项 PASS 输出；精确快照另通过双架构 98 单元语法检查、零诊断。

与前两轮不同，本次五个打包/上传步骤全部成功，artifact 为 1；普通 DEB 已下载并完成包身份、散列、载荷和双架构内嵌标识/中文入口复核。完整产物信息与安装限制见 `docs/BUILD-SOURCE-TIME-0.2.21-timeprobe.1.md`；本地证据前缀 `.build-cache/operations-source-time-package/`。工作区 main、真实暂存区和并行类型源码未变，不包含新增私有材料。

当前已到当前候选包的设备采样节点：用户已安装并完成第 3 轮停止快照，观察到一条他人实时文字和本人早期 receive/outgoing 回调，实际 getter 编码为 `I`，receiver 停止后样本保留；有限文字/ABI观察通过。图片/离线语义、本人 server ID 延迟等缺口仍未关闭，来源语义认证保持 false，不把 DEB 构建或单轮观察当作阶段 A 整体验收。

## 下一轮：A-1/A-2/A-3 原生回归准备（2026-10-22）

状态：**仅准备**。本轮未提交、未推送、未触发 CI、未打包，也没有创建快照提交；工作区 `main` 停在 `f652d5e97180`，真实暂存区为空。以下内容供审核，批准后才执行外部动作。

补充（2026-10-22 收口）：本段所列步骤已获批准并执行，共五次派发、前四次失败并按需定点修复、第五次成功；修复已按行回填主工作区。完整结果、回填核对与未覆盖范围见文末《后续：A-3 隔离快照五轮原生回归执行结果》一节。

### 快照方式

沿用前几轮的隔离源码快照：从当前 `HEAD` 建一个 detached 工作树（`git worktree add --detach`，不建本地分支），把白名单文件从工作区覆盖进去，在**该工作树内**提交，再把该提交以 `refs/heads/codex/operations-a3-native-20261022` 推到公开仓库。父提交仍是 `f652d5e`，`git diff f652d5e..<snapshot>` 可完整复算；主工作树的 HEAD、暂存区和文件内容都不移动。脚本：`.build-cache/operations-native-tests/a3-native/prepare_snapshot.sh`（`--check` 只读建树、`--commit` 建快照提交，均不推送），白名单：同目录 `whitelist.txt`。

### 白名单：34 个文件（18 改、16 新）

- 生产（13）：`Core/SRStore.{h,m}`、`Core/SRRelayCoordinator.{h,m}`、`Core/SROperationsState.{h,c}`、`Core/SRImageAssetStore.{h,m}`、`Core/SRRuntimeLog.m`、`Core/SRMediaQuota.{h,c}`、`Core/SRMediaAlertState.{h,m}`。
- 既有回归需要的并行源码（3）：`Adapter/SRSourceTimeProbe.{h,m}`、`tests/source_time_probe_test.m`。工作流本来就有 `source-time-probe-test` 这一行，不带上这三个文件就编译不了；它们自上一轮验证后未再改动，不含本次 A-3 逻辑。
- 原生测试（11）：`tests/library_test.m`、`library_task_test.m`、`media_quota_test.c`、`media_budget_test.m`（新）；`image_asset_test.m`、`relay_coordinator_test.m`、`automatic_progress_test.m`（schema 14）、`runtime_log_test.m`（operation 事件）、`operations_state_test.c`（暂停策略）（改）。
- Python 测试（6）：`library_model_test.py`、`library_task_test.py`、`media_quota_contract_test.py`、`coordinator_safety_contract_test.py`、`native_build_contract_test.py`（新）；`operations_schema_test.py`（改）。
- 构建清单（3）：`.github/workflows/build.yml`、`Makefile`、`tools/syntax_check.py`。

刻意排除：`Adapter/SRWeChatReceiver.{h,m}` 与 `tests/receive_test.m`（appmsg 结构探针并行改动，其测试另计 10 项）、`UI/SRPanel.m`（来源时间探针的 UI 接线，测试不编译 UI）、`tests/app_message_probe_cases.h`、`tests/app_message_contract_test.py`、`tests/source_time_probe_contract_test.py`、`tools/diagnose_report.py`（appmsg 报告）、`docs/*`、`.workbuddy/`、`.build-cache/`。

### 统计更正（本轮修正上一版的口径错误）

上一版把 `media-quota-test` 算进 Objective-C 程序，并写成“23 个程序各三轮 = 69 次”。正确口径：

| 类别 | 程序数 | 轮次 | 执行次数 |
|---|---|---|---|
| Objective-C 程序 | 22 | 3 | 66 |
| C 程序（`media-quota-test`，`tests/media_quota_test.c`） | 1 | 3 | 3 |
| 单次程序（`pacing-test`、`operations-state-test`） | 2 | 1 | 2 |
| **合计** | **25 个程序** | | **71 次程序执行** |

依据：`build.yml` 的三轮循环列出 23 个程序（22 个 `.m` + `media-quota` 用 `clang -std=c11` 编的 `.c`），循环外另有 `pacing-test`、`operations-state-test` 各执行一次。验证脚本现在会自报这三个数字，`--check` 实测输出 `programs in three-pass loop: 23 (objc 22 + c 1)`、`programs run once: 2`、`expected program executions: 71`。

### 本地预演（真实执行）

用 `git archive HEAD` + 白名单覆盖在专用临时目录复现同一棵树：工作流 25 条 `clang` 共 53 个翻译单元，缺文件 0，未解析的引号内 `#import` 0；三轮循环 23 个程序（22 ObjC + 1 C）、单次 2 个、合计 71 次；被 `inputs.build_deb` 守卫的打包步骤 5 个；快照内 Python 140 项通过（完整工作区 156 项，差额 16 = appmsg 10 + 来源时间契约 6，为刻意排除）。

`--check` 前后：`main` HEAD `f652d5e`、完整 `status`、`ls-files -s` 索引内容、34 个白名单文件散列全部一致；`.git/objects` 松散对象 487 → 487，**没有任何对象写进真实仓库**（快照树是用临时 index + 临时 object dir 算出来的）。

### 本轮脚本加固（2026-10-22 第二轮，只改验证脚本）

`prepare_snapshot.sh`
- `--check` 记录基线：HEAD、`git status --porcelain=v1 --untracked-files=all` 全文与其摘要、`ls-files -s` 全文与其摘要、白名单清单摘要、34 个文件内容散列、以及预演出的快照树 ID，写入 `baseline.txt`（另有 `baseline.status`、`baseline.index` 原文）。
- `--commit` 先逐项核对上述值；HEAD 移动、状态变化、索引变化、白名单变化、任一文件内容变化，都在**创建 worktree 之前**以退出码 3 停止并要求重新预演。
- `--commit` 对真正要提交的快照依次执行三道闸门，全部通过才提交：暂存清单必须恰好等于白名单 → `git diff --cached --check` → `write-tree` 必须等于预演树 → 闭包检查 → Python 套件。任一失败都不产生提交，并明确打印 worktree 留在哪里。
- 提交之后重新采集一次状态（`write_state .../state.after`），主工作区比对**从这次新采集里取出**的 file 记录，不再用提交前那份 `current.files`：否则提交后检查恒真。提交后的任何失败都只报「已生成的 SHA + 停止推送」，不再说「没有创建提交」（退出码 5）。
- 主工作区保护不再只比较条目数：比较完整 status 文本摘要（附原文用于 diff）、完整索引内容摘要、以及每个白名单文件的内容散列。
- 临时目录清理前用 `guard_allows` 核对绝对路径：必须是 `$TMPDIR`（非 POSIX 形式时退回 `/tmp`）**直接**子目录、名字以 `sr-a3-native.` 开头、不是符号链接、不含 `..` 段；否则拒绝删除。`--selftest` 单独验证这个判定。

`dispatch_a3_native.py`
- 派发前用两条列表查询（分支 + `head_sha`）取并集，**逐页读完**（`per_page=100`，最多 10 页）后记下所有已存在 run 的 ID 并写入 `dispatch-request.json`；基线收集失败则不派发（失败关闭）。
- 最后一页仍然满 100 条（到达页数上限）视为**列表被截断**，抛错而不派发，绝不把「第一页」当作「全部既有运行」；响应缺 `workflow_runs` 数组同样按不可读处理。
- 只派发一次。之后只接受「ID 不在基线里」且 `head_sha`、`head_branch`、`event=workflow_dispatch`、`path=.github/workflows/build.yml` 全部匹配的新 run；`path` 是**必需字段**，缺失或为 `null` 一律不认领；因此**同 SHA 的旧成功运行永远不会被当成本次结果**。
- 恰好一个候选 → 固定该 run ID，此后只按 ID 跟踪（`/actions/runs/{id}`），不再按 SHA 搜索。
- 零个或两个以上候选 → 报 `UNCONFIRMED`，退出码 4，**不自动重复派发**；被固定的 run 身份发生变化 → 报 `MISMATCH`，同样不再派发。
- 退出码：0 成功、1 运行完成但结论非 success、2 用法、3 前置条件不满足（未派发）、4 已派发但归属未确认。`prepare_snapshot.sh --commit`：0 已提交并核对、1 提交前闸门失败（无提交）、3 基线与工作区不符（无提交）、5 已生成提交但提交后核对失败（**禁止推送**）。

### 离线反例（本机执行，均不访问远端）

`selftest_dispatch.py`：16 个用例全部通过——同 SHA 旧成功运行不被采用；两个新匹配 → 未确认且只 POST 一次；无新运行 → 未确认；分支不同 / SHA 不同 / `push` 事件 / 别的 workflow 文件 / **`path` 缺失 / `path` 为 null** → 均不认领；**目标 run 只出现在第 2 页时仍被找到（第 1 页满 100 条）**；**列表 10 页全满 → 判定截断、退出码 3、POST 为 0**；远端 ref 移动、仓库非公开、基线不可读 → 退出码 3 且 POST 为 0；`--watch` 按 ID 跟踪并取回 `success`；失败的运行返回 1；被固定 run 身份改变 → `MISMATCH` 且不重派。

`selftest_prepare.sh`：23 项全部通过——真跑一次 `--check`；随后对基线做单点篡改（删掉基线、改一个文件散列、改白名单摘要、改 status 摘要、改 index 摘要、改 HEAD、改预演树），前六类均以退出码 3 拒绝且**不创建任何 worktree**，第七类在提交前停止；最后核对工作区状态、索引、worktree 数量、目标目录均未变化，并跑一次清理守卫自测。第四段在**一次性临时仓库**里复现提交后竞态：`post-commit` 钩子在提交刚生成时改写一个白名单文件，工作区状态文本仍是同一行 ` M`，脚本必须退出码 5、打印真实 SHA、明确禁止推送，且不得声称「没有创建提交」；同时核对提交内容仍是预演内容、工作区确实已变成后来的内容。同一场景用修复前的比较方式跑一遍会退出 0 并输出「status/index/file hashes unchanged」，说明该反例确实打在这个洞上。整轮约 3 分 40 秒（`--check` 约 36 秒），主要是本机进程创建开销。

基线已在本轮修复后重新预演：`--check` 输出 53 个翻译单元、71 次执行、5 个打包守卫步骤，`snapshot tree` 仍为 `b29fe469`（34 个文件、HEAD `f652d5e`），`main` 的 status/索引/文件散列前后一致。

### 待批准的步骤

1. `prepare_snapshot.sh --check`（可重跑，确认基线与将要提交的内容一致）。
2. `prepare_snapshot.sh --commit`，核对输出的 `snapshot commit` 与 `snapshot tree`；`git diff --cached --name-only` 必须恰好是这 34 个文件。
3. `git -C <worktree> push origin HEAD:refs/heads/codex/operations-a3-native-20261022`（推非 `main` 分支不会触发运行，`on.push.branches` 只有 `main`）。
4. `dispatch_a3_native.py codex/operations-a3-native-20261022 <snapshot-sha> --watch`：先断言仓库公开、远端 ref SHA 等于快照 SHA，再用 `build_deb=false` 派发一次并按固定 run ID 跟踪。退出码 4 表示归属未确认，**需人工确认后才可再次派发**。
5. 下载 runner 日志与 `syntax-report`（若启用）到 `.build-cache/operations-native-tests/a3-native/`，逐项核对 71 次程序执行、Python 140 项、零 artifact。

### 仍未覆盖

- 本地无 clang/libclang，快照的 53 个翻译单元只做过源码清单与 `#import` 闭包核对，**没有本地编译**；符号级链接、ARC/`-Werror` 诊断、运行时行为全部依赖这次 CI。
- 两个自测脚本只在本机 Windows git-bash 实跑；`cp --parents`、`realpath -m` 都写了回退分支，但 macOS 上未实测。
- 只覆盖 `-I.` 下的测试程序，不构建 dylib/DEB，因此 UI、宿主接入、真机行为、库内容派发（`dispatchAvailable=false`）仍不在范围。
- 本轮结果只适用于该快照提交；旧 CI 的成功记录不能作为本次代码通过的证据。

## 后续：A-3 隔离快照五轮原生回归执行结果（2026-10-22）

白名单仍是上文审核过的 34 个文件；每轮均为 `build_deb=false`，结果只适用于该轮的精确提交，不外推。首轮快照提交保留在 `codex/operations-a3-native-20261022`（`6ea087d`）；第二至五轮在同一条链上追加于 `codex/operations-a3-native-2-20261022`。所有推送均为非强制快进（第二轮因父提交是 `f652d5e`、推原分支会非快进而改用新分支），未 amend、未强推、未从 `main` 重建兄弟快照。

| 轮次 | 提交 | 树 | run（编号） | 结论 | 首个真实错误 |
| --- | --- | --- | --- | --- | --- |
| 1 | `6ea087d8df437b5ac1de1b5bb0ecbf69a5502da5` | `b29fe4693f8ca16bc109de1c9051e268c60397d8` | [39798678147](https://github.com/andyzpl/SyncRelay/actions/runs/39798678147)（106） | failure | `Core/SRStore.m:980:89` block 捕获 autoreleasing 出参（`-Werror`，`-Wblock-capture-autoreleasing`），store-test 编译中止，22 个 ObjC 程序 0 次执行 |
| 2 | `e83c7cd088ae2a36d6be0270ac696d3891e9580d` | `12a34b1345948ef9aa3468403b18a439f8d503f1` | [39802864785](https://github.com/andyzpl/SyncRelay/actions/runs/39802864785)（107） | failure | `tests/media_budget_test.m:236:19` 链式取下标缺最外层中括号（`-Wint-conversion`） |
| 3 | `372b1397bc84270f9847b590e55b19574c7ac23e` | `d1d163957f18ad7d9e7122e3970ba0e8e318ec7f` | [39804450689](https://github.com/andyzpl/SyncRelay/actions/runs/39804450689)（108） | failure | `tests/automatic_progress_test.m:197` 断言迁移后 `user_version==13`（生产已是 14），Abort trap 6 |
| 4 | `06e5699542828367e859f9856b47524a550843fc` | `646218ed5882175d004be4faa27a86fbfabd4bdf` | [39805665490](https://github.com/andyzpl/SyncRelay/actions/runs/39805665490)（109） | failure | `tests/media_quota_test.c:51` 80% 预警带未触发；`Core/SRMediaQuota.c` 阈值公式分子分母写反 |
| 5 | **`90ed08af6b2687056358642aef1c66aa1a02c162`** | `ba9b583c91fead76f8294916b010007cf4dfc636` | **[39807280389](https://github.com/andyzpl/SyncRelay/actions/runs/39807280389)（110）** | **success** | — |

### 成功轮的核对（run 39807280389）

- 运行身份：`head_sha=90ed08af…`、`head_branch=codex/operations-a3-native-2-20261022`、`event=workflow_dispatch`、`path=.github/workflows/build.yml`；归属已确认（只认领 ID 不在基线内且上述字段全匹配的新 run）。
- Python：快照内 **143 项 OK**（日志 `Ran 143 tests in 1.946s / OK`）；主工作区全套为 **159 项**，差额是刻意未纳入快照的并行类型探针测试，不是漏跑运营用例。
- 程序执行：三轮循环内 23 个程序、循环外 `pacing-test` 与 `operations-state-test` 各一次 → **71 次程序执行**全部成功。日志共 110 条成功输出 = 108（36 条/轮 × 3）+ 2；每轮 36 条来自 23 个程序（其中一个程序输出 14 条、其余各 1 条），**不能读作 110 个独立程序**。
- 三轮一致性：36 条成功消息各出现 3 次，证明 pass 1/2/3 都完整跑完，不是把一轮结果重复计入。
- 关键项：`library-test`（含素材错误路径与确定性 COMMIT 失败注入）、`library-task-test`（占用投影与确认幂等）、`media-quota-test` 与首次真正执行到的 `media-budget-test`、`automatic-progress-test`（schema 14）均 PASS。
- 打包与产物：`build_deb=false`；Install build tools、Set up pinned toolchain、Build ordinary DEB、Verify package contents、upload-artifact 五步全部 `skipped`；**artifact 数 0**；插件版本 `0.2.21` 未改，未构建或安装 DEB。

### 五轮暴露并修掉的真实缺陷

1. `Core/SRStore.m` `saveLibraryImageData`：block 内捕获调用者的 `NSError **` 出参触发 ARC 诊断。改为 block 内局部变量承接、`__block` 强引用保存、方法返回后写回；并把失效行的删除移到素材写入成功之后，使素材失败时事务为空提交；新增"本次新建素材"引用，在 `perform` 最终失败（含 COMMIT 失败）时安全清理，复用素材永不删除；数据库错误与素材错误的优先级在方法返回后统一确定。
2. `tests/media_budget_test.m:236`：链式取下标缺外层中括号（编译期）。
3. `tests/automatic_progress_test.m`：残留 schema 13 期望与"14 是未来版本"夹具，随生产 schema 14 更新为 14 / 15；拒绝打开未来版本的断言保留。
4. `Core/SRMediaQuota.c` `SRMediaLevelFor`：预警阈值交叉相乘分子分母写反，等价 `used >= 1.25×limit`，而上一行 `used >= limit` 已判 Full，故 4/5 警告带实际永不触发；修正为 `used * policy.warn_denominator >= limit * policy.warn_numerator`。

### 回填主工作区（2026-10-22 收口）

按行回填，不从快照整文件覆盖：

| 文件 | 回填内容 |
| --- | --- |
| `tests/automatic_progress_test.m` | 197 行迁移后断言 13→14；198 行未来版本夹具 14→15；199 行"拒绝打开未来版本"断言保留 |
| `Core/SRMediaQuota.c` | 预警公式改为 `used * policy.warn_denominator >= limit * policy.warn_numerator` |
| `tests/media_quota_contract_test.py` | 源码文本守卫同步为同一正确公式 |
| `tests/media_budget_test.m` | 括号修复此前已同步，本轮未再改动 |

核对方式：34 个白名单文件用 `git hash-object`（Git 过滤后的 blob 哈希）与成功快照 `90ed08a` 逐项比对，**34/34 完全一致**；不以 `git status` 条目数代替内容比较。主工作区 Python **159 项 OK**、`git diff --check` 干净；`main` HEAD 仍 `f652d5e`、暂存区 0、索引与基线一致。本轮未提交、未推送、未合并、未重新派发 CI、未打包安装。

### 该结果未覆盖的范围

- 只覆盖 `-I.` 下测试程序在 GitHub 托管 macOS runner 上的编译、链接与模拟执行；**不是真机结果**，也不覆盖 arm64/arm64e 打包形态（本次未启用 Theos/SDK 步骤）。
- 宿主接入与真实微信 ABI：捕获来源的真机语义、`m_uiCreateTime` 的声明 ABI/单位/离线补同步仍缺证据；模拟通过、getter 存在不能替代。
- UI：快照刻意不含 `UI/SRPanel.m`；设置页、消息库管理、容量页面、胶囊状态与告警均未编译、未渲染、未验收。
- 消息库能力位：`dispatchAvailable` 对所有类型仍为 false，库内容派发未实现也未验证；视频三项均未实现；文件/链接/名片/表情/语音等后续类型未实现。
- dylib/DEB 的构建、安装与真机回归不在本轮范围，本次没有产生任何可安装包。
- 结果只适用于精确提交 `90ed08a`；源码再改动需重新验证，不能把本次结果外推到未测版本。

**因此不宣布阶段 A 整体验收**；不进入 B（UI）实现、不开放 C（自动捕获），也不把消息库派发、视频或 UI 标为完成。

## 后续：schema 14 只读采样组合与阶段包（2026-10-23）

用户明确继续后，按已列明范围执行一次隔离提交、公开推送和 `build_deb=true`，不包含安装、RootHide 转换或设备数据库迁移：

- 提交 `45c468418e0874bdece0dd39d2c52205d7521de6`，树 `a59a3ac3b31fa7a74e32107d8bb932efdda7358e`，分支 `codex/operations-a-device-probe-20261023`；版本 `0.2.27+aprobe.1`。
- [CI 39815504152](https://github.com/andyzpl/SyncRelay/actions/runs/39815504152)，job `119952916546`，success。macos-15-intel / macOS 15.7.9，原生测试北京时间 00:37:22–00:41:55。
- 精确快照本地及 CI 均为 160 项 Python 通过。22 个 Objective-C 程序各三轮（66 次）、media-quota C 三轮、两个单次 C 程序，合计 25 程序 / **71 次程序执行**。新增 probe 用例三轮通过。112 条 PASS 输出是分项/重复记录，不是程序总数。
- 与前次 34 文件快照不同，本次组合纳入当前 receiver/appmsg 结构探针、对应回归及设置入口，共 42 个工程文件；新增观察覆盖实际对象 getter ABI、图片/无服务器 ID 早期元数据、16 次排队预留、原方法前冻结、停止/重开及账号 getter 重入代次围栏。模拟对象仍不能证明微信时间单位或语义。
- 五个打包/上传步骤全部成功，生产源码（包括当前 UI 接线）在 arm64/arm64e 上实际编译/链接；未单独运行 Windows SDK 语法检查，不能据此说完成了 UI 渲染或真机交互验收。未对完全相同源码另开测试 CI。
- Artifact `12441329181` 仅一个；包 `365180` 字节，SHA-256 `c7864dca3f3f8c5dc58819621583444e66ff12b0319efe1367323d7fa197f07e`。下载后独立验证 digest、control/载荷/注入过滤、无安装脚本、两架构版本/提交/run/新入口及固定字段，完整信息见构建记录。
- 主 HEAD `f652d5e`、真实 index 和生产/测试文件字节保持未动；结果回填仅修改本地文档，不再为文档构建同一源码。运行证据在 `.build-cache/takeover-20261023/`，没有上传设备诊断、素材或新增私人记忆。

工程检查点已闭合：新增受控观察代码不再是“只写入、未编译执行”。下一关是核对手机当前身份与数据保全，再另取安装/迁移授权并采样；不是安装已经授权或已经发生。图片资源就绪仍无安全被动入口；`sourceTimeSemanticsVerified=false`、`imageReadinessObserved=false`，阶段 A/B/C/D 的验收边界不变。

## 后续：0.2.29+aprobe.4 生命周期候选原生与 DEB 核验（2026-10-24）

- 精确提交 `03abb9bfaccd46f05d68877f37f7eefeb92bee6b`，树 `b99c85596ad773a42bfc54998c8826236cd7e869`，非 `main` 分支 `codex/operations-a-device-probe-20261023-aprobe4`；版本 `0.2.29+aprobe.4`，schema 仍为 14。
- [run 39986009254](https://github.com/andyzpl/SyncRelay/actions/runs/39986009254)，job `120525271412`，success；只派发一次，未重跑前三次失败 run。
- Python **181 项通过**。全部 Objective-C 程序编译、链接并完成三轮模拟执行，新增 `checkInactiveGrace()` 在 `source-time-probe-test` 中实际执行通过；112 条 `PASS:` 是分项/重复记录，不是程序数。`pacing-test`、`operations-state-test` 各执行一次，`media-quota-test` 与其他 Objective-C 程序一同执行三轮。
- 生产源码完成 arm64/arm64e 编译、链接与签名；`lipo -verify_arch arm64 arm64e` 通过。两切片均含版本、提交、run、`SRSourceTimeProbe`、`sourceTimeProbe`、`schemaVersion`、`inactivePending`、`inactiveGraceLimit`、通知接线与未验证标志。
- Artifact `12514559998` 仅一个；包 `andyz.syncrelay_0.2.29+aprobe.4_iphoneos-arm.deb`，366852 字节，SHA-256 `9a45171f6270cbae4946c620b0e29e6925bec589bf555e9a30888aa91aba29af`。载荷仅 dylib/plist，过滤仅 `com.tencent.xin`，无安装/卸载脚本；两切片签名，不依赖 Mikoto。
- 前三次精确 CI 均未完成：第一次是新增 lifecycle 测试对幂等停止原因的期望错误，第二次是更早的既有异步等待超时，第三次是四处等待 block 返回 `int` 与声明的 `BOOL` 不兼容。修正只在测试与源码守卫，未改生产生命周期、schema、发送核心、receiver ABI 或媒体路径。
- 该结果只证明 CI 编译/链接/模拟执行、双架构构建与 DEB 静态核验；**不是真机、宿主 ABI、页面切换、数据库迁移或阶段 A 验收**。未安装、未 RootHide 转换、未迁移设备库、未发送、未读取或准备媒体。完整包证据见 `BUILD-0.2.29-aprobe.4.md`。

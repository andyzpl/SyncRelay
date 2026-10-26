# 阶段 A 本地集中检查收口（2026-10-25）

**2026-10-27 阶段 A 正式收口：实现完成 + 有限真实宿主证据（本轮只做文档收口、文档提交与修复分支推送，不合并 `main`）：** 本段是阶段 A 当前最新口径，取代下方各历史段落中的阶段状态描述；下方历史段落原文全部保留，不改写、不删除、不重排。**A = 实现完成 + 有限真实宿主证据；B/C 保持关闭。不得写"阶段 A 整体验收完成"。**

**代码与构建身份**（本机可复算的部分已复算，见本段末"复算来源"）：代码提交 `f920f39b042e49815e8b14b760b2a65b383ee73a`（父提交 `b296cc1119c79d19859134762449ca3a52997001`），分支 `codex/operations-a-receive-gating-fix-20261026`。macOS 原生 CI run `40357931611` 结论 success：**261 项 Python 契约通过**（日志行 `Ran 261 tests in 3.852s` + `OK`）、**25 条 clang 编译/链接命令全部成功**（测试步骤逐行核对，含 2 条 `-std=c11` 的 C 测试与 23 条 `-fobjc-arc -fblocks` 的 Objective-C 测试编译+链接命令）、**三轮原生测试完成且时间捕获 PASS 每轮出现**（`PASS: ordinary capture carries first-observation evidence, freezes its own time once and refuses a previous receiver round` 在日志中出现 3 次；全日志 127 条 PASS 行 = 42 个循环标记 × 3 轮 + 1 条单次标记）。该 run 以 `build_deb=false` 触发，**本次没有 DEB artifact**（打包步骤按门控 skipped）。

**真机证据**：真机报告代称 `102702`。该报告 `build.commit` = `f920f39b042e49815e8b14b760b2a65b383ee73a`、`build.ciRun` = `40360494942`、`build.plugin` = `0.2.21`——即该报告自证来自打包 run `40360494942` 的产物，**不是** `build_deb=false` 的 run `40357931611`。**这两条 run 不可混用**：run `40357931611` 只提供 macOS 原生测试证据，run `40360494942` 提供实际安装到设备上的包与该报告的身份字段。报告 `102702` 中普通捕获成功（`sourceCapture` = `{generation:2, state:preview, offered:1, rejected:0, lastReasonCode:0}`），两轮捕获均被接受并冻结，未出现 25（轮次冲突）。

**真机页面三行时间与报告的对应关系**（页面「锁定的一条源消息」区，与报告 `102702` 当前 launch 的事件链逐项对应）：

| 页面行 | 取值 | 与报告 `102702` 的对应 |
| --- | --- | --- |
| 插件首次观察时间 | `receivedAt` = `1793034158.768` | `receive_callback` 事件时间 `1793034158.767657`（同一秒） |
| 抓取完成时间 | `previewFrozenAt` = `1793034158.826` | `capture_accepted` 事件时间 `1793034158.8259401`（同一秒） |
| 宿主来源时间原始值（未验证） | `createdAt` = `1793034157` | 宿主 `m_uiCreateTime` 原始值 |

（页面按秒显示，`1793034158.767657` 与 `1793034158.8259401` 均落在 `1793034158` 这一秒内；页面三行的具体数值由用户在设备页面提供，报告本身不导出预览内容，故 `1793034157` 无法从 JSON 复算——见本段末"复算来源"。）

**`receivedAt` 与 `previewFrozenAt` 在 UI 中同秒显示，是因为展示精度到秒**（`yyyy-MM-dd HH:mm:ss zzz` 之外仍按秒取整），**不代表两个阶段没有区分**；两个阶段的差异由注入时钟的原生测试证明（`tests/receive_test.m` 中 `receivedAt` = `1002.5`、`previewFrozenAt` = `5000.25`、`createdAt` = `1001` 且 `createdAtStatus` = `unverified`、`createdAtSemanticsVerified` = `NO`）。**`createdAt` 按原始数字显示，单位与语义仍未验证，不能称为发送时间**；页面文案明确标注"原始值 · 单位/语义未验证"，实现上不交给 `NSDate` 转换（`UI/SRPlanScreens.m` 的 `SRSourceHostTimeText`）。

**人工目视证据（单列）**：用户在本对话明确目视确认预览出现、成员和内容对应。这是**人工目视反馈**，不是 AI 截屏解析，也不证明屏幕消息 ID 的对应性；本段不把人工目视伪装成自动化验证。

**本轮没有做、也不声称做过的**：没有发送、没有送达、没有多群执行、没有视频、没有主动图片、没有消息库派发。本轮没有新增设备操作、没有新导出报告、没有做 source-time probe。

**仍未闭合、且不应通过重复普通接收冒烟强行补齐的边界**：

1. **`createdAt` 的宿主单位、语义及旧/新消息边界未认证**——当前只能证明它是一个稳定的原始数字，不能证明是发送时间、不能证明与"新消息"的判定关系。**以后如确有必要，可在明确授权下做一轮有界 source-time 采样**（只读、单轮、拿到可关联样本或空样本即止）。
2. **本人消息"早期无 server ID → 后续补 ID"的同一消息关联，当前构建无真机样本**——同样归入上述那一轮有界采样，不另起轮次。
3. **页面级生命周期的可靠被动观察入口尚未确认**——**先做 ABI/入口调研**：不猜 selector、不轮询、不下载、不调用主动 getter；确认存在已证实的被动通知或只读状态字段后再登记，否则保持未覆盖。
4. **图片资源就绪没有安全的被动观察入口**——同第 3 项的处理方式：先只读调研，不以主动 getter、轮询、下载或准备媒体补证。

**版本与能力边界**：微信 `8.0.76` 未测，但**不阻塞当前有限 A**（按版本分别登记，不外推）。其他诊断布尔字段的 `0/1` 一致性**不是本轮接收功能的阻塞项**（不改变业务行为，另行授权处理）。**B/C 继续关闭。**

**复算来源（本机实际复算 vs 仅依据用户提供）**：
- **本机已复算**：提交/父提交/分支身份（`git rev-parse`）；远端 `main` 与修复分支的相对关系（`git rev-parse origin/main` = `b296cc1119c79d19859134762449ca3a52997001`，即修复分支的父提交；本机 `main` 引用仍停在 `f652d5e97180a15f43437fd1e449f3b3063e87fc`，**本轮未更新本机 `main` 引用、未合并 `main`**，`git ls-remote` 确认远端修复分支仍指向 `f920f39b042e49815e8b14b760b2a65b383ee73a`）；run `40360494942` 的 261 项 Python、25 条 clang、三轮一致（`rounds_textually_identical = true`）、时间捕获标记 3 次、127 条 PASS 行（读本机 `.build-cache/40360494942/logs/build_3_Test production core on macOS.txt` 与 `log-verification.json` / `round-verification.json` / `target-coverage.json`）；该 run 的 artifact 身份（id `12668910980`、artifact zip SHA-256 `d90910429dca3e364dfde7014cf123668ad49a28228eb03e81fd0b3d20454854`）与 DEB SHA-256 `fa23e69bc6c16cbf019186684c9086994dce91c53201de32b83260f3e04de90b`（`deb-inspection.json`，含 ar 成员、`control` 字段、fat 头 arm64 + arm64e、内嵌完整 commit 与 ciRun 计数）；报告 `102702` 原始 JSON 的 `build.commit` / `build.ciRun` / `build.plugin` 与事件链时间戳。
- **本机未复算、仅依据用户提供的设备材料**：报告 `102702` 原始文件本身位于用户侧路径（`E:\微信聊天记录\...`），本轮**直接读取该原始 JSON 完成身份与事件链核对**，其**预览页面三行时间的显示值**（含 `createdAt` = `1793034157`）由用户在设备页面目视/截图提供，**本机无法从 JSON 复算**——报告刻意不导出预览内容（`102702` 顶层无任何 `preview` 相关键，`sourceTime` 的 4 次命中全部来自 `sourceTimeProbe` 等既有键名），故三行时间值以页面证据为准。**run `40357931611` 的日志与产物在本机无缓存**（本机仅有 `40281941160` / `40284279686` / `40360494942` 三个 run 目录），其 261/25/三轮结论来自本机对 `40360494942` 同源日志的复算与既有记录，**未在本机重新下载 `40357931611` 原件核对**。**不得沿用旧包 `2e63369` / `40284279686` 冒充本轮包身份**——本轮真机报告自证的包是 `40360494942` 的产物。

**2026-10-26 报告 `102604` 接收冒烟证据收口 + 阶段 A 剩余门槛梳理（本轮只改本文件，未提交、未推送、未跑 CI、未打包、未安装、未操作设备）：** 本轮是证据收口与剩余门槛梳理，不是新设备测试授权；下列结论来自对报告 `102604`（原报告）、本机限定采集记录（`device-smoke-20261026-211735-247365` 目录下的 `summary.json`）与既有脱敏核验摘要的离线复算，以及对总计划 `OPERATIONS-CAPSULE-PLAN.md` 第 9/10/12/13/14 节与 `OPERATIONS-V2-CONTRACTS.md`、`OPERATIONS-A-DEVICE-READINESS.md`、`OPERATIONS-SOURCE-TIME-DEVICE-CHECK.md` 的对照；历史证据均标注其适用构建，未读取原件的一律写明"历史文档记载"，不作为本轮独立复核。

**固定包身份（报告 `102604` 自证，与固定包一致）**：`plugin` = `0.2.21`、`commit` = `2e63369f0d8725416263bb3d72412f23a8065562`、`ciRun` = `40284279686`；`storageReady` 在原始 JSON 字节中为 `true`，Python 解析类型为 `bool`（同一文件内该键共 15 处出现，值均为 `true`）；`schemaVersion` 为整数 `14`；宿主为微信 `8.0.79` / `8.0.79.35`，iOS `16.0.3`。

**有效捕获开始时的配置**：`dirty=false`、`senderCount=1`、`includesSelf=false`、`senderFilterCount=1`、`textEnabled=true`、`imageEnabled=false`、`textOnlyCandidate=1`、`ruleCount=1`、`sourceSelected=1`、`targetCount=17`。

**结果**：`sourceCapture.state=preview`、`offered=1`、`rejected=0`、`lastReasonCode=0`、`generation=1`；类型普查 `rows` 仅一条 `type=1`（`count=1`）、`sequence=[1]`；方向样本 `path=receive`，`fromIsGroup=true`、`fromIsSource=true`、`toIsAccount=true`、`messageType=1`、`typeReadable=1`，即所选来源群到当前账号；`source_candidate=1`，随后出现 `capture_accepted` 与 `receiver_stopped`（`receiverGeneration=4`、`armed=false`）。**接收器已停止，但报告导出时 `sourceCapture.state` 仍为 `preview`——不得写成用户已放弃预览。**

**必须披露的两处情况**：① 首次 `capture_attempt` 的 `facts` 为 `dirty=true`，同一次点击被 `capture_blocked`（`reasonCode=1`，对应 `UI/SRPanel.m:1047` 的"请先保存"分支）拦截；随后出现 `draft_saved`，再次 `capture_attempt`（`dirty=false`）才出现 `receiver_arm` / `capture_started` 并成功。**不能写成"首次点击直接成功"。** ② 本轮 `counters` 为 `receive_callback=4`、`receive_wrong_session=3`，`sessionRejections.receive_other_string=3`；而 `runtimeLog` 中同类事件行只有各 1 行。已核对 `note:` 实现（`Adapter/SRWeChatReceiver.m:468`）：计数器对**每次**回调累计，`trace` 只在同类**首次**记录，因此**不能用 runtimeLog 的事件行数代替计数器**。最终只有 1 条匹配消息进入类型普查与预览。**不能写成"零拒绝"**；在没有原始会话标识的前提下，不断言那 3 条来自哪个群，也不认定为产品故障。

**人工证据（单列）**：用户在本对话明确确认"预览出现、成员和内容对应"。这是**人工目视反馈**，不是 AI 截屏验证，也不证明屏幕消息 ID 的对应性。报告本身不导出 wxid、群 ID、server ID 或会话标识，因此"来源成员就是所选的那一位"由**配置侧（单成员、排除本人）+ 人工目视**共同支撑，而非由 JSON 自动认证。

**发送状态**：发送实验关闭；`submissionAttempted=false`、`deliveryOutcome=not_submitted`、`hostReturned=false`；本轮无插件发送提交事件。报告中的 `text_attempt_claimed` / `image_attempt_claimed` 属**跨会话保留的历史持久占位**，不是本轮发送，**不清理、不重试**。

**限定采集记录**：21:17:35 至 21:20:35（Asia/Shanghai），180 秒到时自动结束；三条独立的同名微信进程 PID 过滤流，合计 3659 条记录，其中 SyncRelay 标记为 0 条；未保存原始系统日志。同名进程**不能**证明当前活动实例或构建身份，构建身份仍以报告 `102604` 为准；系统日志中无插件记录**不构成接收失败**，也不能补出成员或消息 ID。

**结论边界**：本轮可写——"固定包在微信 8.0.79 上的单成员、非本人、仅文字接收预览冒烟通过；预览成员和内容对应由用户目视确认。"整体状态仍为 **A = 实现完成 + 有限真实宿主证据**。**不得写**阶段 A 整体验收完成；不得写自动捕获或新旧消息判断已经可靠；不得写 server ID 的屏幕对应性已验证；不得写发送、送达、多群、主动图片或消息库派发已通过。`sourceTimeSemanticsVerified=false`、`newMessagesOnly=false`、`imageReadinessObserved=false` 等能力位原样保留，不因本轮结果翻转；B/C 继续关闭。

**本轮补齐的旧缺口**：① 接收预览在**单成员、排除本人、仅文字**的正确配置下成立，补齐了 `102603` 遗留的"来源过滤器为两人且含本人"配置偏差；② "首次点击被未保存配置拦截、保存后再次开始才成功"这一真实产品行为被记录在案（`capture_blocked`/`reasonCode=1` → `draft_saved` → 成功）；③ `receiver_stopped` 之后预览仍保留这一状态关系被明确，避免误读为用户已放弃。**本轮未补齐**：消息 ID 与本次消息的屏幕对应性仍未证（报告不导出 server ID）；`receive_wrong_session` 的 3 次来源仍无法归因。

**阶段 A 剩余门槛表（整理于本轮，依据总计划第 9/10/12/13/14 节的优先规则与当前实现）**：

| 项目 | 证据及适用构建 | 剩余缺口 | 缺测试 or 缺安全观察入口 | 阻塞完整 A | 最小下一步 |
| --- | --- | --- | --- | --- | --- |
| 来源时间 ABI、单位、语义与离线旧/新消息边界 | 报告 `102604`（构建 `2e63369`）：`sourceTimeProbe` 为 `state=off`、`samples`/`hookSamples` 均空、`getterDeclaredReturnEncoding=not_observed`、`actualWrapABIObserved=0`、`sourceTimeSemanticsVerified=false`；历史文档记载：`.5` 包（commit `12e3a99…`、CI `40064748000`）的同轮旧/新边界与停止后保留——**不同构建，本轮未读取原件复核** | 实际消息对象逐对象返回编码、时间单位与语义均未认证；离线补同步与同轮停止后保留在当前构建上无证据 | 缺测试（探针入口已在当前构建内，可用） | 是 | 在已安装的同一固定包上做**一轮**只读文字采样，覆盖"他人实时文字"与"离线补同步"两个场景，导出后按既有分析器判据核对 `createdAt`/`listeningSince` 关系与严格策略接受；停止条件=拿到可关联样本或出现空样本（记证据不足）即止，不做第二轮 |
| 本人延迟补 server ID 与首次回调关联 | 报告 `102604`（构建 `2e63369`）：`ownTextState=waiting`、`ownTextPending=0`，本轮未触发本人消息路径；历史文档记载 `.5` 包上的同轮关联样本——**不同构建，本轮未复核** | 当前构建未复现"早期无 server ID → 后续补 ID"的同一消息关联 | 缺测试 | 是 | 并入上一项同一轮采样：由本人发一条合成文字，核对 `hookMessageOrdinal` 与交付样本 `messageOrdinal` 一致且分析器不报关联不完整；只取一轮 |
| 停止/代次隔离与生命周期 | 报告 `102604`（构建 `2e63369`）：`receiver_arm=1`、`receiver_stopped=1`、`sourceCapture.generation=1`、`receiverGeneration=4`、停止后预览保留、窗口内除上述 3 次会话拒绝外无其他拒绝计数；历史文档记载 `.5` 包的后台停止、同轮 stop-pair、宿主页面切换未观察到被动通知——**不同构建** | 宿主**页面级**被动生命周期信号在当前构建上无证据（当前源码只接入 `WillResignActive`/`DidBecomeActive`，`UIWindowDidBecomeKey` 仅刷新入口 UI）；`resumedAfterInactive` 字段在当前构建存在但本轮未触发 | 缺安全观察入口（页面级被动信号） | 是 | 先只读调研宿主是否存在可靠的页面级被动通知 ABI：有则登记只读字段，无则登记为"缺入口"并保持未覆盖；**不要求用户重复切页采样** |
| 图片资源就绪（被动观察入口） | 报告 `102604`（构建 `2e63369`）：`imageReads=0`、`imageSource.reads=0`、`imageReadinessObserved=false`、`imageSendPreparation.selectedSelector=none`、`originSelectorCompatible=false`、`longSelectorCompatible=false`；历史文档记载 `.5` 包仅有 type 3 早期元数据——**不同构建** | 没有可靠的被动就绪通知或只读状态 ABI，无法在不触发资源写入的前提下观察就绪 | **缺安全观察入口** | 是 | 不要求用户重复采样、不猜 selector；先做只读入口调研，确认存在已证实的被动通知或只读状态字段后再登记，否则保持未覆盖。禁止以主动 getter、轮询、下载或准备媒体补证 |
| 宿主版本矩阵 | 报告 `102604` 只覆盖微信 `8.0.79`（构建 `2e63369`）；当前允许清单为 `8.0.76` 与 `8.0.79`（`Adapter/SRWeChatReceiver.m:509`），本轮未在 `8.0.76` 取证 | `8.0.76` 无真机证据 | 缺测试 | 否（按版本分别登记，不外推） | 保持分别登记；待有 `8.0.76` 设备时再单次取证，不为凑齐版本矩阵重复当前设备采样 |
| 诊断布尔字段一致性 | 报告 `102604`（构建 `2e63369`）：`storageReady` 已是 JSON 布尔 `true`（含源码契约测试），但 `sendingEnabled=0`、`accountReadable=1`、`centerClassPresent=1`、`sessionClassPresent=1`、`contactClassPresent=1` 仍为 int | 除 `storageReady` 外，其余诊断布尔仍以 `0/1` 序列化 | 缺测试（需契约测试锁定显式装箱写法） | 否（不改变业务行为，但违反诊断布尔契约的一致性） | 另一次授权下按 `storageReady` 的既有做法统一显式装箱并补契约测试；本轮不改代码 |
| 发送、送达、多群、主动图片、消息库派发 | 报告 `102604`：发送关闭、`submissionAttempted=false`、无提交事件；总计划第 12/13/14 节的发送与派发能力按 C 排期，`dispatchAvailable` 对所有类型仍为 false | 全部未验证 | 缺测试（且属 B/C 范围） | 否（阻塞的是 C，不是 A） | A 收口后按第 12/13/14 节排期推进 B/C，不在 A 内提前开放 |

**推荐的唯一下一步（只提方案，本轮不执行）**：在**已安装的同一固定包**（`2e63369` / run `40284279686`）上做**一轮**只读来源时间采样——由选定的来源成员发一条他人文字、由本人发一条本人文字，若条件允许再覆盖一次断网期间的旧消息补同步；导出报告后用既有离线分析器核对 `createdAt` 与 `listeningSince` 的时间关系、严格策略接受情况及本人 `hookMessageOrdinal` 关联。**预期证据**：同轮可关联的他人/本人文字样本各一条，且时间关系可判；**停止条件**：拿到可关联样本、或出现空样本（记证据不足）、或采样到 16 回调/120 秒上限即止，**不做第二轮、不切后台、不锁屏、不改系统时间**。该轮**不需要代码改动，也不需要重新构建或安装**（采样入口已随该包存在），只需设备侧操作授权与用户各发一条合成文字；本轮不执行。

**2026-10-26 阶段 A 收口结论（实现完成 + 有限宿主证据，sender/消息 ID 两条显式留缺口；本轮只改本文件）：** 修复分支已 fast-forward 合入 `main`（远端 `main` = `b296cc1119c79d19859134762449ca3a52997001`，7 个提交、累计 74 文件 / +12790 / −476）；主线 CI run `40319466204`（`push` 事件、head `b296cc1`）结论 `success`，该 run 的打包/DEB 步骤按 `build_deb` 门控全部 `skipped`、artifact 数为 0——这是预期行为，不表示产生过新包。**本轮唯一有效的真机包仍是** `commit 2e63369f0d8725416263bb3d72412f23a8065562` / CI run `40284279686` / DEB SHA-256 `d19ac21711f81751511b3bf99ce415aa60018651a33ff131279ed76b10ee6d0b`（`Version=0.2.21`、`iphoneos-arm`、脂肪头 arm64 + arm64e）；该包与 `main` 当前产品树的产品文件差异为 0，故"与 `main` 等价"属由 0 差异推出的**推断**，不是在 `b296cc1` 上重新打包得到的直接产物。

本轮新增一条**直接**证据（此前只能推断）：经 USB + `pymobiledevice3 syslog live -m SyncRelay` 只读采集，命中唯一一行 `WeChat{SyncRelay.dylib}[…] <NOTICE>: [SyncRelay] 0.2.21 initialized.`（2026-10-26 21:07:39）。os_log 的图像标注 `{SyncRelay.dylib}` 表明该行由 dylib 内的代码在 `com.tencent.xin` 进程内发出，且走的是构造函数**成功分支**（既非 `Storage unavailable` 也非 `Recovery failed`）——即**注入成功、启动期存储初始化与中断恢复均成功**，`storageReady` 在启动时刻即成立。该行只携带版本号，不含 commit/ciRun，故构建身份仍只能由导出报告的 `build.commit`/`build.ciRun` 区分（`0.2.21` 在 `2e63369` 与 `9616a17` 两个包上取值相同）。

接收侧目前唯一正面样本为报告 `102603`：`receive_callback=1` → `source_candidate=1` → `capture_accepted=1`；类型探针 `rows=[{type:1, count:1}]`、`sequence=[1]`；`sourceCapture` 为 `offered=1`/`rejected=0`/`lastReasonCode=0`/`generation=1`；方向样本 `fromIsGroup`/`fromIsSource`/`toIsAccount` 均为真、`messageType=1`；该窗口内 `receive_wrong_session`/`receive_no_server_id`/`receive_type_filtered`/`account_changed` 均为 0，捕获期间仅 1 次 `inactive` 且发生在 `capture_accepted` 之后（导出/分享面板所致）——故**接收预览（候选冻结）在固定包上一次成立**，来源群方向、类型与轮次隔离均无污染。

**两条显式缺口（本轮结论：不再尝试用现有通道闭合）：** ① **来源成员精确性未证**——该次配置为 `senderCount=2` 且 `includesSelf=true`，并非单选成员；报告不导出 wxid，只能证明该消息落在该过滤内，无法排除本人或另一被选成员。② **消息 ID 对应性未证**——`sourceCapture` 不导出 server ID；且 `Adapter/SRWeChatReceiver.m` 的 `note:` 对 `source_candidate`/`capture_accepted` 等接收事件一律传 `facts:@{}`，事件本身不携带 sender 或消息 ID，这是刻意的隐私设计。两条均**无法由 JSON 或 syslog 补证**：tweak 全仓仅 `Tweak/SRBootstrap.m` 三处 `NSLog`（全在启动路径），逐条消息的判定只进内存环形缓冲与微信容器内 `Library/Application Support/SyncRelay/runtime-log.json`，该路径 AFC 不可达；设备为 Dopamine roothide 越狱、无 openssh（22 端口无监听），也无法 SSH 读取。补证只有两条路且均需另行授权：以**单成员 + text-only** 配置重跑一次接收冒烟，或改代码为事件补充 facts（需重打包重装，`build.commit` 变化会使 `102601`–`102603` 的身份证据作废）。本轮选择**不补**。

**收口口径（本段为阶段 A 当前最新结论）：** A = **实现完成 + 有限宿主证据**。成立的部分：实现与合入、主线 CI 的 macOS 原生测试、打包与产物身份可追溯、真机安装/启动/诊断布尔/schema 14、dylib 注入直证、接收预览一次成立。不成立或未涉及的：来源成员精确性、消息 ID 对应性、预览卡片的屏幕呈现（需目视）、任何发送与送达、多群执行、视频、主动图片、消息库派发。**不得表述为"真实微信宿主整体验收完成"**；阶段 A 未整体验收，B/C 继续关闭。本轮只改本文件，未改代码、未跑 CI、未重新打包、未安装、未迁移、未清理设备数据。

**2026-10-26 定向冒烟包真机有限核验（固定包 commit `2e63369f0d8725416263bb3d72412f23a8065562`、CI run `40284279686`、DEB SHA-256 `d19ac21711f81751511b3bf99ce415aa60018651a33ff131279ed76b10ee6d0b`；本轮只做文档收口）：** 用户在设备侧按授权覆盖安装上述固定包（产物 artifact `12633951110`；`Package=andyz.syncrelay`、`Version=0.2.21`、`Architecture=iphoneos-arm`，脂肪头 arm64 + arm64e），完全退出并重新打开微信后导出两份新报告，代称 `102601`、`102602`。**两份报告的 `build.plugin` / `build.commit` / `build.ciRun` 三个身份字段完全一致**，说明两次导出都来自同一构建、没有旧包混入；上一份包 commit `9616a17` / run `40281941160` 与历史报告 `102501` / `102502` 本轮均未使用，只作历史证据保留。`storageReady` 在原始 JSON 字节中为 `true`，Python 解析类型为 `bool`；`schemaVersion` 为整数 `14`。由于该字段已是真正的 JSON 布尔，`tools/diagnose_report.py` 本轮**不再输出** `storage_readiness_invalid`——该固定代码只在字段缺失或类型非布尔时出现，本轮既未放宽分析器、也未删除该分支，`0/1`、`null`、`"true"`/`"false"` 仍按原规则拒绝。报告中的 `image_attempt_claimed` 与 `text_attempt_claimed` **按契约保留**：它们是单条文字/图片实验的持久占位记录，本轮**不重试、不清理、不删库、不做 schema 11 迁移**，保留原样以便后续审计看到"该账号已存在占位"。**本轮结论严格限定在有限设备核验范围内**：只证实该固定包可安装、可启动、两次导出的构建身份一致、`storageReady` 序列化为 JSON 布尔、`schemaVersion` 为 14；**不代表阶段 A 整体验收**，也不构成任何发送、送达、多群执行或 B/C 能力的证据。本轮未改代码、未跑 CI、未打包、未迁移、未清理设备数据；**提交前核对时**工作树为 `codex/operations-a-receive-gating-fix-20261026`、HEAD `2e63369f0d8725416263bb3d72412f23a8065562`、暂存区为空，改动仅限本文件；随后本段以文档提交 `28061e6f2a8d9065d84f1055eee6a0453d92b9f6` 收口（该提交只含本文件的两行追加）。

**2026-10-26 最小补回 storageReady JSON 布尔修复（隔离工作树 `codex/operations-a-receive-gating-fix-20261026`，基于 `9616a17e0a4121a1cf71b20db3121e85e0202096`）：** 修复分支 `9616a17` 遗漏了 `5d31177638f5f864a8b7e3b1f46e1f371fcac188`（"Fix diagnostic storageReady JSON boolean"）中的生产布尔修复——该提交在主线上，本次修复分支未带入，因此 `UI/SRPanel.m` 的 `report[@"storageReady"]` 仍是 `@(self.store != nil)`。该写法在 Objective-C 中是 `int`，导出 JSON 会序列化成 `0/1`，违反诊断布尔契约（这正是上一轮已记录、本轮才补回的已知缺陷）。本轮**最小补回，不整笔 cherry-pick、不带入该提交的历史文档调整**，只改两处：① `UI/SRPanel.m` 改为 `report[@"storageReady"] = self.store ? @YES : @NO;` 并加说明注释（显式装箱以避免 `0/1`）；② `tests/settings_ui_contract_test.py` 新增 `test_storage_readiness_exports_a_json_boolean`，锁定该键**唯一**赋值为显式 `@YES`/`@NO` 形式，并显式拒绝旧的 `report[@"storageReady"] = @(` 写法。守卫先进：新测试在**未改**的生产旧写法上确实失败（`Lists differ: ['report[@"storageReady"] = @(self.store != nil);'] != ['report[@"storageReady"] = self.store ? @YES : @NO;']`），改生产后通过，故该断言具备判别力，不是恒真。**未放宽分析器、未接受 `0/1`、未删任何断言**；其余布尔字段（`sendingEnabled`、`settingsFooterRecoveryActive`、`floatingEntryEnabled` 等）未统一整理，schema、sender/type 门禁、ABI、捕获/发送逻辑与既有接收测试均未改。本地验证：focused `tests.settings_ui_contract_test` **10 项通过**（原 9 + 新增 1）、完整 Python **247 项通过**（原 246 + 新增 1，与预期一致）、`py -3 -m compileall -q tools tests` 通过、缓存 libclang 双架构语法检查 **106 单元零诊断**（arm64/arm64e 各 53，含 `UI/SRPanel.m`）、`git diff --check` 干净。以上均为**源码契约与语法层**证据：Objective-C 原生链接/执行、CI、DEB 打包、安装、真机均不由此证明，待本提交的 `build_deb=true` CI 验证。**旧包口径**：commit `9616a17` 的打包 run `40281941160`（artifact `12632572605`，DEB SHA-256 `45d81c5b88952d4385b4d2905076b3470e68c5143e4028fcc860066b2eacf0f2`，版本仍 `0.2.21`）身份核验通过，但它**不含本次布尔修复**，因此**不再作为最终定向冒烟对象**，仅作历史证据保留。旧 CI（`40274440125`/`40277683819`/`40280396194`/`40281941160`）与历史包 `102501`/`102502` 均**不构成本新提交的运行证据**。schema 14 直接初始化，B/C 继续关闭。

**2026-10-26 接收门禁类型配置漂移修复（隔离工作树 `codex/operations-a-receive-gating-fix-20261026`，基于 `edeee3020dcb5010a1f8c1971e72b8b1e2829858`，本地未提交/未推送/未跑新 CI）：** 两次 CI 的首个失败点已按顺序确认。run `40274440125` 首个观测到的失败是共享 tap 竞争断言（`tests/receive_test.m` 原第 651 行：8.0.79 receiver 仍持有 `ReceiveManager` 共享 tap 时，一个新 8.0.76 receiver 被误期望 arm 成功）；提交 `edeee30` 的 run `40277683819` **已越过该断言**（原生执行中 `658–662` 五条竞争断言全部成立），首个观测到的失败变为配置 arm（原第 704 行 `[receiver armForAccount:current configuration:draft()]` 返回 NO）。根因是测试夹具漂移，不是生产门禁错误：测试 `draft()` 继承生产 `SRConfiguration emptyDraft()` 的 `types={text,image}`，而文本用途的 receiver 没有 `prepareImage`/`discardImage`，于是命中 `Adapter/SRWeChatReceiver.m:607` 的图片能力门禁。本轮只改测试：`receive_test.m` 的 `draft()` 显式 `types={text}`（`draftForSender()` 继承该文本配置），图片场景（`checkImageCapture`、`checkSourceTimeEvidence` 的图片分支）继续显式选择 `image` 并保留其能力块；新增原生负向用例 `checkImageCapabilityGate()` 并在 `main()` 中调用——无图片能力块 + 显式选 image 必须 arm 失败，错误域为 `SyncRelay.Receiver` 且信息含 `Image snapshot preparation is unavailable`，receiver 保持未 armed 且不消费回调；随后同一 receiver 的 text-only 配置仍能 arm、投递，并在 `stop` 后把共享入口释放给下一个 owner。生产端 `emptyDraft()` 默认类型、图片能力检查、tap 单 owner 互斥、selector/ABI 与能力范围全部未改。本地验证：focused Python 契约 **37 项通过**（新增 `tests/receive_type_config_contract_test.py` 9 项 + 既有 28 项）、完整 Python **246 项通过**、`py -3 -m compileall -q tools tests` 通过、缓存 libclang 双架构语法检查 **106 单元零诊断**（arm64/arm64e 各 53）、`git diff --check` 干净。以上仅为源码契约与语法层证据：**Objective-C 原生链接/执行未执行，待授权 CI 验证**；本轮没有新的 CI 证据，因此"配置 arm 漂移已修复、receive-test 可完整退出 0、`checkAppMessageProbe`/`checkOutgoingTypeCensus` 断言成立、pass 1/2/3 三轮一致"均**尚未证实**。schema 14 仍为直接初始化。

**2026-10-26 竞争 receiver arm 断言修正（隔离工作树 `codex/operations-a-receive-gating-fix-20261026`，基于 `fed471b4c54e44cbcea63ba01f589da02d55a412`，未提交/未推送/未跑 CI）：** 上一提交 `fed471b` 的 CI run `40274440125`（build_deb=false）首个观测到的失败点是 `tests/receive_test.m` 原第 651 行——一个 8.0.79 receiver 已占用 `ReceiveManager` 共享 tap 时，内联新建的 8.0.76 receiver 被误期望 arm 成功。本轮**只修测试**：改为具名竞争者，断言其 arm 返回 `NO`、错误域为 `SyncRelay.Receiver` 且信息含 `Another receiver owns this capture entry`、原 receiver 仍 `armed`、竞争者未 `armed`；生产端共享 tap 的单 owner 互斥（`SRWeChatReceiver.m:526`）保持不变，未放宽门禁、未改版本允许清单、未停原 receiver，并保留约 702 行"原 owner 停止后 8.0.76 可成功 arm"的正向用例。本地验证：聚焦 Python 契约 **28 项通过**、完整 Python **237 项通过**、`py -3 -m compileall -q tools tests` 通过、缓存 libclang 双架构语法检查 **106 单元零诊断**（arm64/arm64e 各 53）、`git diff --check` 干净。**修复后的 Apple 原生链接/行为执行、CI、DEB 打包、安装、迁移、真机采样仍未验证**（语法检查不等于 Objective-C 原生执行）；schema 14 直接初始化，B/C 继续关闭。

**2026-10-26 本轮出站普查/探针隔离收口（当前工作区，未提交/未打包/未安装/未跑 CI）：** 依据验收方确认的口径，补齐出站路径的三条原生断言并更正 server ID 门禁的文字表述。`tests/receive_test.m` 新增 `checkOutgoingTypeCensus()`（并在 `main()` 中调用）：① 出站 type 1 + 有效 server ID + 已选 text → `observedMessageTypes` 记录 type 1（`messageTypeProbe.rows/sequence` 各一条 type 1）；② 出站 type 49 → `appMessageProbe` 可观察（`state=parsed`、`subtype=5`、body 读取一次），但 `observedMessageTypes` 不增、无 pending readback、无 source candidate、无发送；③ 出站 type 49 **无** server ID → 仍只做只读探针，`ownTextPending` 为假、`ownTextState` 停在 `waiting`、`receive_type_filtered` 记一次、`GetMsg:LocalID:` 回读未发生（`manager.lookupGroup == nil`）、`source_candidate` 计数为 0、`sendingEnabled` 为假。生产端只改注释，未改任何门禁、ABI、能力范围：`Adapter/SRWeChatReceiver.m` 的收/出站注释、`docs/APP-MESSAGE-PROBE.md` 的 Scope 段与本项目记忆的门禁顺序约定均改为按路径区分——**server ID 不是跨路径统一的身份门禁**：收路径 `observeSession:` 的 server ID 是硬门禁（relay/census 路径要求 server ID），出站路径 `observeOutgoingManager:` 没有 server ID 身份门禁，server ID 只是结算门禁，出站 type 49 只读探针可在无 server ID 时观察但不产生业务结果。

本轮本地验证：聚焦 Python 契约 **28 项通过**（`tests.receive_failure_modes_contract_test` + `tests.source_time_probe_contract_test`）、完整 Python **237 项通过**、`py -3 -m compileall -q tools tests` 通过、缓存 libclang 双架构语法检查 **106 单元零诊断**（arm64/arm64e 各 53）、`git diff --check` 通过。**仍未执行**：Apple 原生链接与行为执行、CI、DEB 打包、安装、迁移、真机采样（这些只能由 CI / macOS / 设备提供证据）。schema 14 **直接初始化**，不做 schema 11→14 迁移，也不准备 schema 11 测试库；阶段 A 真实宿主语义仍未整体验收，B/C 继续关闭。

**2026-10-26 本轮复审收口（当前工作区，未提交/未打包/未安装/未跑 CI）：** 在前述 P1/P2/P3 实现基础上，修正 `tests/receive_test.m` 的 Objective-C 静态语法问题（将对 `id` 的 `.count` 访问改为显式 `NSArray`），并把与当前 fail-closed sender filter 一致的错误发送者及回调计数断言收紧；同时更新 receiver 注释，明确未选类型、错误 sender、旧 generation 和时间证据失败均不得进入 `observedMessageTypes`。聚焦契约 **25 项通过**、完整 Python **234 项通过**、`compileall` 通过、缓存 libclang 双架构语法检查 **106 单元零诊断**、`git diff --check` 通过。仍未执行 Apple 原生链接/行为、CI、DEB、安装、迁移或真机；schema 14 直接初始化，B/C 继续关闭。

**2026-10-26 追加复核（当前工作区，未提交/未打包/未安装/未跑 CI）：** 在保留全部既有修改的前提下，复核并补强了本轮 P1/P2/P3 的原生测试源码边界：成功投递用例统一使用带 sender filter 的 configuration arm；新增低层 `sourceGroup` arm 的 fail-closed 运行断言；观察类型用例确认只有当前账号、当前 generation、当前允许类型且通过时间门禁的回调进入 `observedMessageTypes`；来源捕获用例确认重新 arm 清零 `offered/rejected/lastReasonCode`，取消后迟到 offer 不再递增旧轮计数。未改 schema、宿主 ABI、图片主动链路或设备流程；本轮生产端另补了账号边界在诊断记录前的 fail-closed 复核。工作区仍为 `main`、HEAD `f652d5e97180a15f43437fd1e449f3b3063e87fc`，暂存区为空，既有约 74 项修改全部保留。

本轮验证：新增/聚焦 Python 契约与来源时间契约共 **25 项通过**；完整 Python 套件 **234 项通过**；`py -3 -m compileall -q tools tests` 通过；缓存 libclang 双架构语法检查 **106 单元零诊断**（含 `tests/receive_test.m`、`tests/relay_pipeline_test.m`、`Core/SRSourceCapture.m`、`Adapter/SRWeChatReceiver.m`）。这些语法检查不是 Objective-C 链接或行为执行；本轮未运行 macOS 原生程序、CI、DEB、安装、迁移或真机。阶段 A 真实宿主语义仍未整体验收，B/C 继续关闭。

**2026-10-26 最新本地代码/契约/测试审查（当前工作区，未提交/未打包/未安装/未跑 CI）：** 本轮只做阶段 A 的本地代码、源码契约与测试审查，严格遵守只读边界：未 reset、覆盖检出、clean、删除或回退任何既有用户修改，未提交、推送、运行 CI、构建 DEB、安装、迁移或清理设备。当前产品为全新设计、按 **schema 14 直接初始化**；schema 11→14 迁移不是本阶段功能，也未准备 schema 11 测试库或迁移设备验证。工作区仍为 `main`、HEAD `f652d5e97180a15f43437fd1e449f3b3063e87fc`、暂存区 0；约 75 项工作树修改全部保留。

完成的三处修复（源码改动，非新能力）：
- **P1 — senderIDs 空窗口 fail closed**（`Adapter/SRWeChatReceiver.m` 的 `allowsSender:`）：把旧 `if (self.senderIDs && ![self.senderIDs containsObject:sender])` 改为 `if (self.senderIDs.count == 0 || ![self.senderIDs containsObject:sender])`，`nil.count==0` 同样拒绝；未配置/空过滤不再放行任意发送者。低层 `armForAccount:sourceGroup:` 仍置 `senderIDs = nil`，因此该旧式 arm 现在默认拒绝，必须用 `armForAccount:configuration:` 提供 senders 才能放行。
- **P2 — observedMessageTypes 记录时机**（`observeSession:` / `observeOutgoingManager:` / `observeMessageType:generation:`）：先评估投递门禁（allowsSender + acceptsTimeEvidence），再仅在 `probeAllowed`（当前 generation + senderIDs 非空 + sender 在过滤内）时记录 `observedMessageType`；`observeMessageType:generation:` 在非 armed 或 generation 不匹配时直接 return，陈旧/迟到回调不能追加到当前诊断。未知/未选类型（包括 34/42/47/49）在类型门禁处拒绝，不进入当前诊断；此前“保留未知类型路由探针”的表述已被本轮复审取代。
- **P3 — SRSourceCapture 轮次隔离**（`Core/SRSourceCapture.m`）：新增 `generation` 单调令牌，`armForAccount:configuration:` 在重置计数前 `self.generation++`；`offerEnvelope:` 在 `!self.waiting` 时先于 `offered++` 直接 return，取消/确认失败/停止后的迟到回调不污染当前轮计数；`diagnostics` 现暴露 `generation`。

本地验证（明确区分层级）：
- **聚焦 Python 源码契约（新增 `tests/receive_failure_modes_contract_test.py`）：9 项全部通过**，逐条断言 P1/P2/P3 的守护子句存在且顺序正确（`allowsSender` 空过滤拒绝、`observeMessageType:generation:` 早返回、`observeSession`/`observeOutgoingManager` 先门禁后 `probeAllowed`、`offerEnvelope` 先 `!waiting` 再计数、`diagnostics` 暴露 `generation`）。
- **完整 Python 套件：`python3 -m unittest discover -s tests -p '*_test.py'` 实际执行 234 项通过**（原 225 + 新增 9），无回归。
- **C / Objective-C（含 `tests/receive_test.m`、`SRSourceCapture` 相关原生用例）：本轮未执行。** 当前环境 PATH 上无 clang/gcc，相邻 `OwnHide/.build-cache` 的缓存 libclang 本轮未调用；原生编译/链接/执行仍只在 CI / macOS 主机可执行，不冒充通过。

遗留风险与证据缺口（需用户/开发确认，非本轮擅自修改）：
- **receive_test.m 旧式 arm 需转写**：约 17 处 `armForAccount:current sourceGroup:@"mother@chatroom"` 期望投递成功，但在 P1 fail-closed 下 `senderIDs=nil` 会全部拒绝。这些用例须改用 `armForAccount:configuration:draft()`（draft() 已含 senders/sourceGroup/types/rules）才能继续验证投递；涉及用户既有修改之一，未擅自改写。
- **8.0.76 允许清单与用例自相矛盾（既存）**：`SRWeChatReceiver.m` 第 504 行允许清单已含 `@"8.0.76"`，同一文件 `receive_test.m` 第 547 行 `CHECK(![makeReceiver(@"8.0.76", …) armForAccount:current sourceGroup:…])` 却期望 8.0.76 **失败**，而第 597 行又期望 8.0.76 **成功**。这是工作树中既存的版本清单/用例不一致，需确认预期版本集合后再统一，不替用户改版本号或测试。
- **SRWeChatReceiver.m ~600–790 行未逐行复核**：P1/P2 编辑通过精确字符串匹配成功落位，但本机无 clang，编译期校验缺失，须在 CI 或 macOS 主机确认语法/链接。

下一层阶段 A 验收仍只缺需要真实微信宿主语义的证据；B/C、视频、消息库实际派发继续关闭。

**2026-10-25 最新打包状态（当前精确快照，未安装）：** 按授权从当前开发快照建立隔离分支 `codex/a-package-20261025`，提交 `02cf7fb963fb4e34bb2a83a35d68fd1415e2aa87`，运行一次 `build_deb=true` CI `40179290423` / job `121126667336` 并成功。Python **225 项**通过；22 个 Objective-C 目标各执行 3 次，pacing/operations-state 各执行 1 次、media-quota 执行 3 次；普通 `iphoneos-arm` DEB 已由 CI 用 `dpkg-deb` 检查并用 `lipo` 验证 `arm64`/`arm64e`。包 SHA-256 为 `bedb3a3a722dd10dbeed51ee857e4e9eaaf6fecd83666c6ee235df0a9e9692d5`，artifact ID `12592629882`，详情见 [BUILD-0.2.21-apackage.1.md](BUILD-0.2.21-apackage.1.md)。本次没有安装、迁移、清理设备数据或新增真机采样；A 的真实宿主语义仍未整体验收，B/C 继续关闭。

**2026-10-25 先前原生状态（已被上方打包结果覆盖）：** 按授权在隔离分支 `codex/a-probe-clock-invalid-native-20261025-r3` 提交/推送 `aa01abe451a5bd4254f6e3df829ac4fdb8032f29`（tree `bca12cb7a48ba08fa119725936e61afcc1119b1f`），仅运行一次 `build_deb=false` CI `40169810412` / job `121098186039`。Python **224 项**通过；22 个 Objective-C 目标编译/链接并各执行 3 次（66 次），3 个 C 目标按配置执行 5 次（pacing/operations-state 各 1 次、media-quota 3 次）；25 个目标、71 次配置执行与日志成功标记逐项一致。探针字段夹具修正及 inactive 起始 clock 为 NAN/负值/异常时的 `clock_invalid` 安全停止行为均已原生三轮通过。5 个打包步骤全部跳过、artifact=0；无生产包、安装、迁移或设备动作。主工作区 `main`、HEAD `f652d5e97180a15f43437fd1e449f3b3063e87fc`、真实暂存区及既有修改保持不动；全新 schema 14，A 的真实宿主门槛仍未整体验收，B/C 关闭不变。

**2026-10-25 先前本地增量（已纳入上方 CI）：** 离线诊断分析器现在要求 `storageReady` 为明确 JSON 布尔值；缺失或其他类型只输出固定 `storage_readiness_invalid`，不把真值/假值强转为数据库可用性，也不继续解释 `schemaVersion`。新增回归后本地完整 Python **225 项**通过；当时尚未进入原生快照，现已由上方 `40179290423` 的 225 项 CI 覆盖。

**2026-10-25 本轮本地验收复核（无源码增量、无外部动作）：** 复跑完整 Python **225 项**、`compileall`、双架构语法检查（53 个 Objective-C 单元 × arm64/arm64e，共 **106 单元零诊断**）及 `git diff --check`，均通过；使用缓存 Zig **0.14.1** 将 pacing、operations-state、media-quota 三个纯 C 测试按 `-std=c11 -Wall -Wextra -Werror` 分别编译，并各运行 **3 次**，共 **9 次通过**。可执行文件只写入系统临时目录。此处不产生新的 Objective-C 链接/模拟、生产构建、DEB、安装、迁移或真机证据；既有 CI 的 **224 项**与本地新加的第 **225** 项仍分开记录。工作区 `main`/HEAD、空暂存区和原有开发修改未覆盖；下一层 A 验收只缺需要真实宿主语义的证据，不要求重复空采样。

**2026-10-25 较早失败快照（历史，不覆盖上方成功结果）：** 分支 `codex/a-probe-lifecycle-native-20261025`、commit `004712eaa969de8a0d22768e99dcd3f95cdb2703`、tree `f68d41abadb5893fc44ecb0cffa8ca870b5b779b`，CI `40164827983` / job `121083632151`、attempt 1，只有一个匹配该快照的运行。8 个 Objective-C 目标首轮通过；pacing 和 operations-state 各通过 1 次。`source-time-probe-test` 首轮在 `tests/source_time_probe_test.m:478` 失败，之后的目标及后两轮没有执行；media-quota 仅编译、未执行。网络派发超时后先多次只读核对无运行，再取得 204 确认；最终运行数为 1。运行前后主工作区 `main`/HEAD/真实暂存区保持原样，未生成安装包。随后两份测试文件和八份文档的本地修正已进入上方 `40169810412` 成功快照。

**2026-10-25 修复前快照的原生回归（不覆盖后续增量）：** 分支 `codex/a-native-validation-20261025`、提交 `d02de94` 由 CI `40154276666` / job `121052172029` 以 `build_deb=false` 完成；当时 Python **211 项**通过，22 个 Objective-C 目标完成编译/链接并各执行 **3 次**；3 个 C 目标均编译通过，`pacing-test`、`operations-state-test` 各执行 **1 次**，`media-quota-test` 执行 **3 次**。此前已按实际日志纠正“三个 C 均三轮”的误记，不为凑次数重跑 CI。准备本轮快照时核对 **119 个源码/测试/工具/构建文件**：与该旧 CI 有 6 个不同文件，即 `Adapter/SRSourceTimeProbe.m`、`tests/source_time_probe_test.m`、`tests/source_time_probe_contract_test.py`、`tests/native_build_contract_test.py`、`tests/diagnose_report_test.py`、`tools/diagnose_report.py`。这些增量已进入上方失败 CI 快照，不能把旧成功 CI 或本轮编译成功写成三轮执行通过。Makefile/workflow 未改；主工作区 `main` 未提交、暂存区为空。

**2026-10-25 schema 门禁覆盖补强：** Python 与原生夹具现在都用空数据库覆盖旧标记 `1/13` 和未来标记 `15`；拒绝发生在任何表/触发器创建、WAL 或媒体目录副作用之前。它们只是版本门禁反例，不是 schema 11 数据，也不要求用户准备旧库或做迁移。

**术语边界：** schema 14 里仍有 `operations_legacy_adoptions`/`adoptLegacyOperationsRun`，这里的 “legacy” 指产品层对未关联旧运行的显式接回，不是数据库 schema 11→14 升级；它不会让旧 schema 文件被接受，也不是当前设备验收项。

**2026-10-25 历史隔离原生回归（迁移路径移除前快照）：** 在不移动主工作区 `main` 的前提下，隔离分支 `codex/operations-a-local-closeout-native-20261025` 的提交 `c35fb7181bc211d2b1d19e1de6c92a9b8bee9609`（树 `e5f3928a0ac229a150965e8d6a132d8edc595158`，父提交仍为 `f652d5e97180a15f43437fd1e449f3b3063e87fc`）由 CI `40147383615` / job `121031524021` 以 `build_deb=false` 完成当时快照的 Python **214 项**、Objective-C 原生目标编译并三轮执行及 C 目标编译/执行；DEB、安装、迁移和设备步骤均未运行。该历史结果不覆盖移除旧库升级路径后的源码；这部分原生链接/执行缺口已由上方 `d02de94` / CI `40154276666` 补齐，无需再次授权相同回归，阶段 A 仍未整体验收。

**2026-10-25 范围纠正：** 当前产品是全新设计、按 schema 14 直接初始化；schema 11→14 迁移不是本阶段功能，也不是 A 阶段设备验收门槛。当前源码已移除旧库升级路径和 `migrationDiagnostics`，不要求用户准备 schema 11 测试库、降级、清库或重复迁移操作；若未来重新决定支持旧库升级，再单独立项和授权。

## 1. 实际完成了什么

**结论：授权的一次原生 CI 已成功完成当前快照的编译、链接和模拟执行；阶段 A 的本地/原生门槛已补齐，但真实微信宿主语义仍未整体验收。** 不把“源码已审查”“语法检查通过”“C 执行通过”“macOS 模拟通过”“生产包通过”“真机语义通过”合并成一种证据，也不宣称已经穷尽所有潜在缺陷。这是开发侧测试/行为修正与宿主证据边界，不转成重复设备采样任务。

- 实查根目录 `AGENTS.md`，未发现更深层规则；工作区仍为 `main`，HEAD `f652d5e97180a15f43437fd1e449f3b3063e87fc`，暂存区为空。已有大量未提交开发成果全部保留，未 reset、覆盖检出、清理、删除或回退主工作区文件。
- 已阅读七份指定文档顶部最新状态，以及总计划第 12–14 节；旧包和旧回归只对其各自源码有效，不能覆盖本次工作区。
- 已把本轮 schema 测试镜像改为读取临时库实际 `PRAGMA user_version`，增加“unsupported version 在任何 schema DDL 前拒绝”的空库用例；Objective-C 夹具也只验证通用拒绝门禁，不再构造或要求 schema 11 测试库。
- 对数据库打开/当前 schema 完整性、版本与媒体引用、冻结任务幂等、取消/恢复、协调器身份/重入、receiver/只读探针、容量/提醒以及脱敏分析器做了一次集中审查，并执行下表对应本地检查。
- 实际修复资源管理的三个缺口，未改 schema 14、宿主 ABI、发送核心、库内容派发或 B/C 界面。
- 此前已复现并修复旧接线契约的漏检：在内存中删掉 `store-test` 的执行行后，旧测试仍通过。现从指定 CI 测试步骤逐项核对仓库内全部 `.m`/`.c` 测试的唯一编译目标和精确执行次数；注释、仅 echo、重复/遗漏、循环外挪动、吞失败、提前退出及其他步骤内的同名命令不能充当本步骤执行接线。这里只验证配置，不把脚本解析当成实际执行证据。
- 本轮复现成对分析器接受 `[null]` 作为已保留样本、单份分析器因超大整数抛出 `OverflowError` 的问题，再补回归和修复；非对象样本、超过 16 条、跨 round/generation、乱序/重复 ordinal、不同 listening boundary、容器型枚举、伪整数 schema 和越界能力标记都不能产生成对一致结论。手动停止后的保留样本仍绑定停止前 generation，不误绑已经递增的 receiver generation。
- 此前已补齐 `noteApplicationInactive`、`noteApplicationActive` 和 inactive 分支 `tick` 对原 round / 区间 generation 的校验。原生夹具包含 18 个停止/重开组合、1 个 tick 内恢复、9 个相同时间戳区间替换组合及 3 个当前区间时钟故障；字段夹具改为校验样本内的 `receiverGeneration` 与 `round` 后，CI `40169810412` 已将这些场景编译、链接并三轮执行通过。旧实现未通过的 6 个源码门禁反例仍只作为修复前记录，不冒充当前失败。
- 本轮定位并修正我新增测试误读不存在顶层字段的问题：保留样本数量断言，改用冻结 receiver 代次校验样本 `receiverGeneration`，并独立校验样本 `round`；不删除身份断言、不增加生产报告字段来迁就测试。随后发现 inactive 回调入口的 monotonic clock 异常、非有限或负值会静默略过，未能建立 2 秒宽限；现于 round/interval 重入复核后以 `clock_invalid` 停止探针并保留已有样本，加入 NAN/负值/异常 Objective-C 用例。Python 契约先在旧实现失败，修正后通过；上述生产逻辑、聚焦测试和契约增量随后已纳入隔离分支并由 CI `40169810412` 三轮执行通过。

| 本轮修复 | 修改及失败闭环 | 回归证据 |
| --- | --- | --- |
| 同目录多个实例的并发保护不完整 | `SRImageAssetStore` 原来只共享 C 账本，各实例的扫描/写入锁、临时文件集合和预留 token 集合互不共享。现以同目录共享状态作为递归 monitor，串行化 scan → reserve → write → commit 和清理，且各实例都能看到在用 token；在用素材不计入可回收容量 | 新增源码契约；新增 Objective-C 跨实例引用保护、64 路预留、被暂停写入与并发扫描用例。双架构语法检查和隔离 CI 原生编译/三轮执行均通过 |
| 阈值只校验 policy 上限，漏查快照实际采用的上限 | 阈值比较前同时复核有效快照上限的乘法范围；不可表示的输入保守返回 full / reminder hold，不因整数回绕错误提醒或清除提醒 | 新 C 断言在旧实现实际失败，修复后实际编译并三轮执行通过；包含巨大快照上限、合法小上限配超大比率、原策略无效的反例 |
| 多个 Store 可以同时领到同一次 80% 提醒 | 将 read → hysteresis → persist 放进 `SRMediaAlertState` 同一个进程级 monitor。Store 不再拆开读写提醒标记，不新增平行状态源 | 新增源码契约；新增双 Store、64 路领取以及降至 reset 后再次跨线的 Objective-C 用例。语法检查和隔离 CI 原生执行通过 |
| 原生接线护栏只检查三目标，却声称覆盖所有目标 | 改为核对全部 **25 个目标**及 **71 次配置执行**，准确区分循环内三次和循环外一次；未知脚本结构直接拒绝，避免静默高估 | 旧护栏实际接受漏跑 Store 的变体；新护栏拒绝 **13 种**破坏变体，聚焦 **11 项**和全量 **224 项**通过，并由 CI `40169810412` 按同一矩阵执行。配置次数只用于核对接线，不当作额外原生测试 |
| 离线分析器把损坏/跨轮次样本当成一致证据，非法数值/枚举可使其退出 | 单份与成对分析共用固定字段校验；成对样本须有界、顺序完整并绑定原轮次/代次/统一时间边界，探针须保持只读和未验证能力关闭；错误只输出固定码 | 新增 7 项回归；旧实现出现 77 个断言失败子例与 13 个异常子例，修复后分析器 58 项、全量 **224 项**及三种真实 CLI 调用通过。仅用合成数据，不新增真机语义证据 |
| 时钟同步重入后旧生命周期结果可修改新状态 | 读取时钟前冻结 round / inactive generation，停止、恢复和新 inactive 使旧区间失效；同时间戳不作为身份依据。当前区间真正的无效时钟仍安全停止 | CI `40169810412` 已将重入、同时间戳和恢复边界三轮执行通过 |
| 新增重入测试误读不存在的报告顶层代次 | 用捕获的 receiver 代次比较样本代次，保留数量并补样本 round 校验；不改变生产报告结构 | 修正后的探针契约 **16 项**、完整 Python **224 项**及双架构语法通过；Objective-C 原生三轮通过 |
| inactive 起始 clock 失效时没有建立宽限或停止 | 读取结果仍先核对 round / inactive generation，只有仍属当前区间的异常、非有限或负时钟才以 `clock_invalid` 安全停止；已采样内容保留 | NAN、负值、异常三类 Objective-C 故障用例已在 CI 三轮执行通过 |
| 诊断把非布尔 `storageReady` 当作可用性 | 分析器现在严格接受 JSON 布尔值；缺失、`null`、数字、字符串和容器统一输出 `storage_readiness_invalid`，并停止解释 `schemaVersion` | 新增 Python 边界回归；完整本地 Python **225 项**通过。该 1 项未进入既有 CI，不冒充原生/真机证据 |

共享锁保证的是**同一进程、同一目录路径**的实例，不承诺多进程或不同路径别名的协调。新增原生用例只操作测试临时目录中的自有文件、合成 SQLite 库和稀疏压力文件，不读取微信媒体或操作设备数据。

## 2. 编译/测试/模拟/打包/真机分别验证了什么

### 当前累计证据（区分本轮执行与既有结果）

| 层级 | 实际结果 | 不代表什么 |
| --- | --- | --- |
| 聚焦 Python / SQLite / 源码契约 | 相关模块随当前全量回归通过 | 不执行 Objective-C 文件 I/O 或宿主对象 |
| 完整 Python | 隔离 CI 快照 **224 项通过**；本地最新实际执行 **225 项通过**，包含本次 `storageReady` 边界回归，不能把本地增量外推为 CI/原生证据 | 源码契约不等于真实微信对象或宿主语义 |
| 离线 CLI | 单份报告、`--pair`、`--stop-pair` 三种真实 Python 子进程调用均对损坏合成数据返回固定诊断码，无 traceback 或私人字段回显 | 没有读取新设备报告，不认证来源语义、页面切换或图片资源就绪 |
| Python 编译 | 本轮 `py -3 -m compileall -q tools tests` 通过 | 不是 Objective-C 编译 |
| C 编译和执行 | 本轮实际重跑：缓存 Zig **0.14.1**，`-std=c11 -Wall -Wextra -Werror`；operations-state、pacing、media-quota 三个程序均编译成功，各运行三轮，**9 次执行通过** | 这是 Windows C 程序，不得和 macOS CI 的 C 执行次数混写 |
| Objective-C 双架构语法 | 本轮实际重跑：缓存 libclang **18.1.1** / iPhoneOS **16.5 SDK**，target iOS 15.0；53 个生产/测试单元 × arm64、arm64e，共 **106 单元通过，零诊断**，包含本次探针/原生测试增量 | 没有生成/链接生产二进制，也没有执行 Objective-C 测试程序 |
| diff 与保留核对 | `git diff --check` 通过，只有既有换行转换提示；另核对新增/未跟踪测试和本轮编辑文件；HEAD、暂存区及本轮范围外文件保持原样 | 不是行为验证 |
| macOS 原生模拟 | 本轮 CI `40169810412`：22 个 Objective-C 目标编译/链接并各执行 3 次，3 个 C 目标按既有配置执行 5 次；25 个目标、71 次配置执行与日志成功标记逐项一致，探针三轮通过 | 只证明 Foundation/SQLite 与模拟对象行为，不证明真实微信对象、页面生命周期或图片资源就绪 |
| 生产构建/DEB | **本次未执行** | 无新包、无新安装授权 |
| 真机/迁移 | **本次未操作** | 不新增来源语义、页面生命周期、资源就绪或迁移证据 |

工具链说明：本次实查发现相邻 `OwnHide/.build-cache` 中已经存在 SDK/libclang/Zig 缓存，故实际复用了本地工具，未下载、安装工具链。此前“本机无工具链/语法检查未执行”的段落保留为当轮历史；不能继续用该段描述本次结果，也不能反过来用本次结果替旧源码补证据。

### 集中检查覆盖矩阵

| A 检查面 | 本次检查依据 | 当前证据边界 |
| --- | --- | --- |
| 打开/当前 schema、触发器刷新、外键与复合账号关系 | `operations_schema_test.py`、`library_model_test.py`；审查 `SRStore` 的事务、提交前关系校验与清理顺序 | SQLite 合成数据回归通过；当前生产/原生测试源码的隔离 CI 已覆盖 Objective-C 打开/回滚；旧库升级不是当前产品能力 |
| 不可变版本、旧 token 的 owner 保留、完整媒体登记 | `library_model_test.py`、`library_test.m`；审查新建/追加版本和失效素材重导入 | 当前隔离 CI 已编译/链接/三轮执行相关原生用例；仍不宣称恢复丢失字节 |
| 任务冻结、账号/确认键/版本/目标身份及幂等 | `library_task_test.py`、`library_task_test.m`；审查创建、回读、启动占位、历史重发冻结 | 库任务仍仅创建 awaiting_resume + pending 占位，无 attempt/派发；`dispatchAvailable=false`，继续/claim/旧结果入口保持拒绝 |
| 取消、在途收尾、重启恢复与历史保留 | `operations_schema_test.py`、`store_test.m`、`relay_coordinator_test.m`；审查 pending-only 撤销和迟到结果路径 | SQL/契约及隔离原生模拟通过；不改既有发送结果语义，不把模拟回执解释成真实宿主回执 |
| 协调器身份、generation、手动许可撤销和同步生命周期重入 | `coordinator_safety_contract_test.py`、`operations_state_test.c`、`relay_coordinator_test.m` | C 状态/门禁真实执行通过；Objective-C 端口重入/错误注入已由隔离 CI 三轮执行；没有接入 B UI，不证明宿主真实页面信号 |
| 只读探针与 receiver 边界 | `source_time_probe_contract_test.py`、`source_time_probe_test.m`、`receive_test.m`；审查轮次、区间代次、16 样本/120 秒、文字过滤和生命周期接线 | 当前探针原生三轮通过；采样仍不捕获/预览/发送/准备图片，宿主来源时间和资源就绪标记仍未认证 |
| 256 MiB 共享预算、预留、扫描失败、提醒与引用保护 | `media_quota_contract_test.py`、`media_quota_test.c`、`media_budget_test.m` | C 及 Objective-C 跨实例文件保护/原子提醒用例已有实际执行证据；不开放清理界面或新清理动作 |
| 诊断脱敏、历史字段忽略、成对报告来源 | `diagnose_report_test.py`、`runtime_log_test.m`；审查固定字段、缺失/错误标记、同构建/同进程/递增导出与样本身份判据 | 本地分析器 58 项聚焦及完整 Python 225 项、真实 CLI 损坏数据回归通过；新增 `storageReady` 非布尔拒绝仅有 Python 证据，隔离原生日志导出用例既有证据不变。不新增设备报告，空样本继续判证据不足，不输出原始身份/正文/路径 |
| 构建闭包与测试接线 | `native_build_contract_test.py`、Makefile、语法清单和 CI 测试清单 | 本轮逐目标接线与 13 种破坏变体通过；既有 CI 已实际编译/链接/执行原生程序，不冒充生产链接/打包 |

本地记录位于忽略目录 `.build-cache/phase-a-batch-20261025/`：本轮编辑前副本/散列、旧实现失败日志、聚焦和全量测试日志、C 编译执行日志、语法日志/JSON、最终证据 manifest。记录不包含设备报告、凭据或原始媒体。该目录不是需要推送的源码产物。

较早接线复核记录另存于忽略目录 `.build-cache/a-native-evidence-20261025/`：编辑前文件散列、旧护栏漏检复现、11 项聚焦/212 项全量日志及 119 文件的 CI 快照逐文件比较。没有复制设备报告或导出凭据；该目录属于修正前历史，不覆盖当前 224 项 CI / 225 项本地结果。

较早离线分析器记录位于忽略目录 `.build-cache/a-pair-evidence-20261025/`：编辑前散列与相关文件副本、旧实现漏判/异常复现、预期失败日志、58 项聚焦/219 项全量结果、三种真实 CLI 调用结果及 119 文件的 CI 快照比较。数据均为测试合成，不包含设备报告或凭据；当前以 224 项 CI / 225 项本地结果为准。

较早探针重入记录位于忽略目录 `.build-cache/a-probe-lifecycle-20261025/`：185 个既有文件的编辑前散列、11 个范围内文件副本、旧源码未通过新增门禁的记录、14 项聚焦/222 项全量日志、双架构语法报告、119 文件 CI 快照比较及本轮增量 patch。没有原生程序执行记录，不复制设备报告或凭据；修正后的原生结果以 CI `40169810412` 为准。

较早授权失败 CI 与修正记录位于忽略目录 `.build-cache/a-probe-native-ci-20261025/`：独立 index/隔离 commit、精确快照的 222 项本地测试、单个 CI 的请求/状态/完整日志、失败定位及逐目标实际成功次数、5 个打包步骤跳过与零产物核对；并保存测试夹具修正前副本、新契约预期失败、后续时钟故障修正的本地回归、16 项/224 项本地结果和 106 单元语法报告。没有第二轮 CI，也不包含设备报告或凭据。

当前成功 CI 记录位于忽略目录 `.build-cache/a-probe-clock-invalid-native-20261025-r3/`：提交/树身份、224 项 Python 快照、CI 请求与 job 日志、逐目标 71 次配置核对、5 个打包步骤跳过和 artifact=0 复核均在此；本地 `storageReady` 增量尚未进入该目录或 CI；不含设备报告、凭据、生产包或媒体文件。

## 3. 剩余风险和证据缺口

1. **完整来源时间语义与页面级生命周期**：保留 `102417`、`102421A/B`、`102422` 等已有有限后台停止/同轮边界/本人 ID 关联证据，但 `102424` 没有页面 inactive/active 信号，`102425` 只确认随后安全停止。没有可靠可观察信号前不再要求重复切页。
2. **被动图片资源就绪**：`102423` 的 type 3 早期元数据和 getter 编码 `I` 不等于资源就绪；`imageReads=0`、`imageReadinessObserved=false`。没有已证实的被动入口就保持未覆盖，不调用主动 getter、下载或准备媒体。
3. **空采样**：`102428` 的 samples/hookSamples 为空，只记证据不足。无需继续导出同类报告。

历史 CI `40104958294` 及 `0.2.30+migdiag.1` DEB 的编译/模拟/双架构/包核验成功结论保留为历史，不覆盖本次新修改；其设备基线也不关闭上述缺口。阶段 A 未整体验收，B/C、视频、消息库实际派发继续关闭。

## 4. 下一步需要谁做什么

- **用户现在无需操作手机。** 不重复页面切换、空采样或同类报告导出；若已停止采样，保持现状。
- **开发侧下一关**：原生模拟回归已完成，不再追加同类 CI。继续由开发侧做本地契约、文档和边界一致性审查；只有出现需要重新构建的实际代码变更，才另行明确范围，不默认提交、推送、打包或安装。
- **用户现在无需补迁移证据**：当前新设计不把 schema 11→14 升级列为验收项，当前源码也会直接拒绝旧版本。不要改当前 schema 14 设备的 `user_version`，不要清库、降级或安装旧包；只有未来明确恢复旧库兼容需求时，才另行定义测试范围。
- **后续设备缺口由开发先准备可判定方案**：页面信号和图片就绪先确认可靠被动可观察入口。只有方案能产生新证据、范围获授权后，再合并成一次必要设备配合。不能先让用户刷重复操作，再把空报告当进度。

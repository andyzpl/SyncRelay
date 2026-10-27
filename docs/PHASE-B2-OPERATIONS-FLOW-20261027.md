# Phase B-2 运营链路（2026-10-27）

本轮把「运营首页 → 分组列表 → 执行详情」补成一条实际可用的只读链路加显式命令。
它不开放阶段 C：自动捕获、总开关联动监听、自动下一组、主动重新发送、消息库派发、
主动图片链路、视频、新群自动入组、备份恢复仍然全部关闭。

## 1. 范围与边界

- 三个页面都只投影 Core 状态和当前 `SRSmallGroupSession`；打开、刷新、进入、返回
  页面不启动捕获、不建计划、不恢复运行、不发送。
- `SRRelayCoordinator` 的宿主接线仍属后续阶段：本轮**没有**把它当作权威运行状态，
  也没有为了取数调用任何会启用、监听、建计划或恢复任务的方法。
- UI 不写 SQL，不修改 claims/runs/deliveries；本轮不改 schema、不做迁移、不改宿主
  ABI、捕获门禁、来源时间语义、媒体准备或发送实现。

## 2. 权威数据源

| 用途 | API | 性质 |
| --- | --- | --- |
| 当前/最近内容（协调器路径） | `SRStore operationsContentForAccount:` | 只读 |
| 已确认计划 | `SRStore plansForAccount:limit:offset:` + `plan:account:` | 只读，本包实际来源 |
| 冻结分组与每组进度 | `SRStore ruleCardsForPlan:account:` | 一次有界读取，含 latestRun/counts |
| 单次运行统计 | `SRStore smallGroupRun:account:` | 只读、账号归属校验 |
| 取消 vs 结束 | `SRStore operationsCancellationForRun:account:` | 只读，`ended` 行才有区分意义 |
| 异常与未发项 | `SRStore exceptionsForRun:account:limit:offset:` | 既有分页 |
| 无内容时的分组 | `SRStore configurationForAccount:` | 只读草稿，不可发送 |
| 活动运行 | `SRSmallGroupSession.status` / `currentRunID` / `progressBelongsToCurrentAccount` | 唯一在途事实，绑定账号 |

首页解析「当前内容」的顺序：本账号内存中的预览 → 已准备内容 → 最新已确认计划 →
无内容。预览始终是预览，不会被提升为已确认内容，也不会自动确认。

## 3. 页面身份

| 页面 | 身份 |
| --- | --- |
| 运营首页 | account + verifyAccount；活动运行另由 `currentRunID` 与 `progressBelongsToCurrentAccount` 绑定 |
| 分组列表 | account + planID（冻结计划；nil 表示无已确认内容，只读）+ configuration（该内容捕获时冻结的配置，仅 planID 为 nil 时投影） |
| 执行详情 | account + planID + ruleID + runID，全部在进入页面时捕获并显示 |
| 异常与未发项 | account + runID（复用既有 `SRRecordScreen` 分页页） |

页面之间不传「当前任务」，只传上述标识。

## 4. 运营首页

正文四段固定为：运行状态 → 当前内容 → 分组概览 → 最近一次结果。

- **运行状态**：状态、进度（已处理/总数、在途），以及当前会话拥有的运行所对应的
  「查看本组执行详情」「暂停」「继续未发」。收尾中显示为不可操作文字，不提供重复继续。
  「暂停」「继续未发」把按钮生成时的那一个 runID 一起保存进行内，点击时原样传入处理函数；
  处理函数不再自己读 `currentRunID` 当作目标，而是先核对账号、会话归属，再要求「当前挂载
  runID 与动作里的 runID 相同」，然后才发命令。缺失、已变化或已失效时只提示并刷新，
  不调用暂停/继续；`resumeRun:` 用的就是传入的那个绑定 runID。
- **当前内容**：摘要（图片只描述已保存的元数据，不读取宿主图片）、插件捕获时间、
  插件来源时间（观察 / 抓取完成，含秒与时区）、宿主来源时间原始值（标注未验证）。
  点开进入既有完整内容查看页；预览状态进入既有预览页，确认流程仍由那一页负责。
- **分组概览**：实际分组数、目标群数、已处理进度、未开始分组数；入口直接以本内容的
  planID 打开分组列表。「全部内容计划」是另一行，不再作为分组入口。
- **最近一次结果**：按持久插入顺序（`creationOrder`）选取该内容（优先归档内容的计划）
  最近一次终态运行，并携带其 planID/ruleID/runID 进入详情；不会指向新建的当前任务。

无内容、无分组、读取失败、账号失效分别是四种不同显示，不合并成「已完成」。

## 5. 分组列表

- 有已确认内容时使用该内容/plan 的冻结分组；无内容时只读显示**该内容捕获时冻结的配置**
  （预览取 `capture.status[@"configuration"]`，已准备内容取 `operations_contents.configuration`），
  全部标记为不可执行（「尚未确认内容，只能查看分组和群名单，不能发送」）。只有完全没有当前
  预览/已准备内容时，才回退 `configurationForAccount:` 的已保存配置；之后修改设置不会改变
  已显示内容对应的分组。
- 只读分组的点开行为：用该行**已经投影出的** `name` / `targets` / `targetNames` 组装目标清单，
  复用既有只读文本查看页（同一个 `verifyAccount` 回调做账号核对）。它不进入
  nil-plan 的占位详情页、不创建假 plan、不调用 `smallGroupRulePreview:`、不重查宿主、
  不读取图片，也不出现任何执行动作。
- 每组显示：分组名称、实际目标数、本次内容处理进度、状态文字（未开始/执行中/已暂停/
  收尾中/处理完成/有异常/已结束/已取消/状态待核对）。
- 支持按组名与群标识搜索，以及全部、未开始、进行中、已完成、有异常筛选。
  搜索与筛选只是对同一数组重新投影，不写库、不改冻结数据，也不在搜索回调里查库。
- 冻结计划的群标识来自 `SRStore ruleCardsForPlan:` 的 `targetIdentifiers`（按 allocations
  的冻结 position 顺序，一次读取整份计划）。冻结计划不持久化群名称，因此
  `targetNames` 保持为空，列表不显示也不猜测名称；列表也不调用
  `smallGroupRulePreview:` 来实现搜索，避免额外校验图片资源或实验状态。
- 超过每条 20 群的分组明确显示「不可执行；不会截取前 20 群」，不截断、不扩额。
- 占用运行时的门禁沿用既有路径：开始仍走 `SRSmallGroupSession startRule:`，会话忙时
  拒绝；列表另用 `accountOccupied` 作为显示层提示。
- 每页只在 `reload` 里读一次库（含取消标记），cell 不再重复扫库；异常列表复用既有分页。

## 6. 执行详情

- 展示本次分组与目标范围（目标标识按冻结顺序只读列出，不发送）、批次 ID、原始业务状态
  （持久化值）、展示状态、进度、未尝试/在途/已提交/已确认送达/失败/结果未知/已取消、
  已持久化的开始与结束时间。
- 时间统一 `yyyy-MM-dd HH:mm`，按设备本地时区；缺失时显示「未记录」，不用页面打开时间
  或当前时间填充。取消显示「已取消」与结束时间，不会被写成处理完成。
- 命令复用既有 API：`startRule:account:`、`pauseForAccount:`、`resumeRun:account:`、
  `cancelRun:account:`、`endRun:account:`。
  - 开始只对已确认、目标数 ≤20、顺序已解锁且账号无占用批次的分组开放。点击时读取冻结卡与
    `smallGroupRulePreview:`；确认框被接受后**再读一次** `ruleCardsForPlan:`：分组必须仍在
    该账号的冻结计划中、`latestRun` 仍为空、20 群/解锁/无占用三项仍成立，之后才做冻结预览
    校验并调用 `startRule:`。确认期间出现新批次时不会开始，页面刷新为 stale 状态。
  - 继续只走原批次未尝试项；在途收尾时先拒绝，不重复继续。
  - 取消只有一次必要确认，说明已提交无法撤回、在途仍可能完成、其他分组不会自动开始。
  - 取消或结束后不自动开始下一组。
- 每个命令执行前都重读 `ruleCardsForPlan:` 并核对 account + planID + ruleID + runID；
  账号变化、批次被替换、分组已不在冻结计划中，一律拒绝而不是改操作别的对象。

### 页面身份与 stale 规则

页面打开时记下它显示的 run（可能为空），此后只用这个身份：

| 页面记录的 runID | reload 时的当前 run | 结果 |
| --- | --- | --- |
| 有（runID=X） | 仍是 X | 正常，操作可用 |
| 有（runID=X） | 缺失，或变成 Y | **stale**：开始/暂停/继续/取消/结束全部关闭 |
| 无（runID=nil） | 仍无 | 正常，可开始 |
| 无（runID=nil） | 出现了任意 run | **stale**：不接管这个后来出现的 run |

- stale 判断在 `buildActions` 的最前面完成，早于任何 active 分支，因此运行中的新批次
  不能绕过 stale 状态。
- stale 页面不显示其他批次的统计：`summary` 置空，批次行显示本页记录的标识并注明已失效。
- `startPressed` 与 `revalidateRun:` 都先拒绝 stale 页，再核对 store。
- 唯一允许改写 `self.runID` 的路径是本页自己 `startRule:` 成功之后采纳
  `execution.currentRunID`；失败时不采纳。
- 判断本身是纯函数 `SRRunProjection pageIsStaleForBoundRun:currentRunID:`，
  由 `tests/run_projection_test.m` 用五个形状执行（macOS CI），本地另由 Python 镜像
  执行同一张表并锁定其源码条件。

## 7. 新增纯投影

`Core/SRRunProjection.h/.m`：Foundation-only、无状态，只接收 `SRStore` 已经产出的字典。

- 时间：`localDateTimeText:` / `localDateText:` / `localTimeWithZoneText:` /
  `unverifiedHostTimeText:` 及 envelope 三个来源时间入口。
- 运行：`phaseForState:cancelled:counts:`、`phaseText:`、`phaseIsActive:`、
  `runSummary:`、`countLinesForSummary:`、`progressTextForSummary:targetCount:`。
- 页面身份：`pageIsStaleForBoundRun:currentRunID:`（纯函数，供详情页判定 stale）。
- 分组行：`groupRowsForCards:`（冻结计划）、`groupRowsForConfiguration:`（只读配置）、
  `rows:matchingText:filter:`、`filterIdentifiers`、`titleForFilter:`。
- 汇总：`overviewForGroupRows:`（只统计已有运行的分组）、`latestRunInCards:`。

阶段映射（不替代持久状态，原始 state 仍原样展示）：

| 持久 state | 条件 | 阶段 |
| --- | --- | --- |
| 空 | — | `not_started` 未开始 |
| running | — | `running` 执行中 |
| paused / awaiting_resume | submitting=0 | `paused` 已暂停 |
| paused / awaiting_resume | submitting>0 | `settling` 收尾中 |
| completed | failed+uncertain=0 | `completed` 处理完成 |
| completed | failed+uncertain>0 | `abnormal` 有异常 |
| ended | 有取消记录 | `cancelled` 已取消 |
| ended | 无取消记录、无异常 | `ended` 已结束 |
| ended | 无取消记录、有异常 | `abnormal` 有异常 |
| 其他 | — | `unknown` 状态待核对 |

## 8. 明确未支持

- 分组列表不显示冻结计划的目标群**名称**：`allocations` 只持久化目标标识，名称只在可编辑
  配置里。页面因此按组名与群标识搜索，并在详情页只读列出标识。
- 首页的「查看本组执行详情」只对属于当前内容/最近内容计划的运行开放；其他内容的运行需从
  各自内容进入，页面不会用「当前任务」去猜。
- 消息库冻结任务的运行详情、重新发送批次、自动下一组、视频与新群入组均未实现。
- `SRRelayCoordinator` 未接入宿主，`operations_contents` 路径在本包中通常为空；首页因此
  以最新已确认计划作为实际内容来源。

## 9. 验证层级

已实际执行（本机 Windows，最近一次为 §11.6 收口轮）：

- 聚焦 Python：`tests.phase_b2_ui_contract_test` 49 项通过；与 `tests.phase_b_ui_contract_test`
  合计 70 项通过。
- 完整 Python：`331` 项通过（基线 282 项，未删减旧测试）。
- `py -3 -m compileall -q tools tests` 通过。
- 双架构语法检查（缓存 libclang 18.1.1 / iPhoneOS 16.5 SDK，target iOS 15.0）：`55` 个翻译
  单元 × arm64/arm64e 共 `110` 单元零诊断，含新增 `Core/SRRunProjection.m`、
  `tests/run_projection_test.m` 与修改后的 `UI/SRPlanScreens.m`。这是语法层，不是链接、
  执行或行为结果。
- `git diff --check` 干净。

未执行（Windows 无法提供）：

- `tests/run_projection_test.m` 与 `tests/plan_queries_test.m` 的 Objective-C 编译、链接与运行；
  这两个程序的**行为**结论只能由 macOS CI 给出（`plan-queries-test` 已在既有清单中，
  `run-projection-test` 已登记到 `.github/workflows/build.yml`，均为编译 + 三轮执行）。
  本机只做了语法层检查；`run_projection_test.m` 里断言的具体取值（占用/未解锁门禁顺序、
  `excerptForEnvelope:limit:8` 的截断、秒+时区文本形状）**没有在本机执行过**。
- UIKit 行为：分组列表搜索框、筛选菜单、详情页行数、导航返回、告警确认顺序，均未在模拟器
  或真机上观察。
- 打包、安装、真机运行与真实发送。

因此本轮**不宣称**阶段 B 已验收；Python 契约与语法检查不等于 UIKit 或真机通过。

## 10. 注册位置

- `Makefile`：`SyncRelay_FILES += Core/SRRunProjection.m`。
- `.github/workflows/build.yml`：`tests/run_projection_test.m` 的编译命令与三轮执行列表。
- `tools/syntax_check.py`：新增 `Core/SRRunProjection.m`、`tests/run_projection_test.m`。
- 以上只做文件/测试注册，未改权限、触发条件、工具链固定版本或编译安全参数。

## 11. 两个阻断问题的修复（2026-10-27，修复轮）

### 11.1 冻结计划的群标识搜索失效

- **根因**：`groupRowsForCards:` 固定输出 `targets=[]` / `targetNames=[]`，而
  `SRStore ruleCardsForPlan:` 只返回 `targetCount`，没有返回 allocations 里的目标标识，
  因此列表根本没有可搜索的群标识。
- **修复**：`ruleCardsForPlan:` 为每张卡新增 `targetIdentifiers`，从
  `SELECT rule_id,target FROM allocations WHERE plan_id=? ORDER BY rule_id,position`
  一次读完整份计划并按冻结 position 分组；`groupRowsForCards:` 只把它复制进
  `rows[@"targets"]`。不返回也不猜测名称（`targetNames` 继续为空），不调用
  `smallGroupRulePreview:`，搜索与筛选仍只对同一份投影数组执行。
  `targetCount`、`latestRun`、`initialUnlocked`、`accountOccupied` 行为不变。
  详情页的目标范围也改用这份冻结标识，不再为展示范围去调预览接口。

### 11.2 执行详情的迟到页面身份

- **根因**：`replaced` 只在「页面有 runID 且当前 run 不同」时成立，漏掉
  「页面 runID 为空、之后出现 run」和「已绑定 run 之后 latestRun 消失」两种情况；
  同时 `replaced` 分支写在 active 分支之后，运行中的新批次可以直接绕过 stale 判断；
  `startPressed` 也没有 stale 检查。
- **修复**：新增纯函数 `pageIsStaleForBoundRun:currentRunID:`（空字符串视为无 run），
  在 `reload` 里统一判定；`buildActions` 把 stale 判断提到最前并直接返回，
  `startPressed` / `revalidateRun:` 先拒绝 stale，`revalidateRun:` 另加
  「命令必须指向本页记录的 runID」；只有本页 `startRule:` 成功后才会写入
  `self.runID`。stale 页面不再展示其他批次的统计与操作。
  分组列表进入详情时传入该行当前显示的 runID，避免已开始的分组被当成「当时没有 run」。

### 11.3 迟到确认只做预览校验（2026-10-27 收口）

- **根因**：`startConfirmedRule:` 在确认框接受后只重调 `smallGroupRulePreview:`，没有再读
  `ruleCardsForPlan:`。确认框停留期间另一个入口若已为该组创建运行，命令仍可能被发出。
- **修复**：确认处理器现在的顺序是：账号 → `self.replaced` → 以 `self.planID` + account
  重读 `ruleCardsForPlan:` → 按 `self.ruleID` 取 card（取不到即拒绝）→ `latestRun` 必须仍
  为空 → 目标数 ≤20 / `initialUnlocked` / 账号未占用 → `smallGroupRulePreview:` →
  `startRule:`。任一步失败都只提示并刷新，不调用命令；只有 `startRule:` 成功后才读取
  `execution.currentRunID` 写入 `self.runID`。暂停、继续、取消、结束路径与门禁未改。
- **覆盖**：`tests/phase_b2_ui_contract_test.py` 锁定该顺序与每条拒绝都必须 `return`，
  并本地执行 start 门禁表（含「确认期间出现新 run → 不可开始」），且把该表钉在源码条件上。

### 11.4 冻结配置错配与旧计划页命令入口（2026-10-27 收口）

#### 11.4.1 预览/已准备内容的冻结配置

- **根因**：首页 `resolveContent:` 用捕获时的内容（内存预览或 `operations_contents`），
  但 `loadGroups:` 在 `planID` 为空时总是重新调用 `configurationForAccount:`。用户捕获后修改
  设置，首页显示的内容与其分组配置就来自两个不同时刻。
- **修复**：`SROperationsHomeScreen` 增加 `nullable frozenConfiguration`，在 `resolveContent:`
  中与内容一起解析：内存预览取 `self.capture.status[@"configuration"]`，已准备内容取
  `current[@"configuration"]`（`operations_contents` 持久化的冻结行）；已确认计划仍只用
  `plan` + `ruleCardsForPlan:`，不从当前设置推断。`loadGroups:` 在无 plan 时先投影
  `frozenConfiguration`，只有完全没有当前内容时才回退 `configurationForAccount:`。
- **分组列表**：`SRGroupListScreen` 增加 `nullable configuration`，`SRCreateGroupList` 增加该
  参数（`UI/SRPlanScreens.h` 同步），运营首页进入分组列表时传入 `frozenConfiguration`。
  `planID` 为空且未传入配置时才读已保存设置；两种情况都仍是只读（`readOnly=YES`，
  `startRule/resume/cancel/end` 一个都不出现）。只读行的点开方式见 §11.6.3。
- **不做的事**：不用页面时间、不重新读取宿主、不调用 `smallGroupRulePreview:` 来修补展示。

#### 11.4.2 旧计划页的命令入口

- **根因**：首页「全部内容计划」可进入旧 `SRRecordScreen`（`SRRecordPlan`），旧 `ruleActions:`
  确认后直接调用 `startRule:`，绕过 B-2 详情页在确认框之后的迟到冻结卡复核。
- **修复**：删除旧计划的 `ruleActions:` 与 `performExecution:`（约 50 行），规则行改为
  `openRule:` → `SRCreateRunDetail(account, planID=self.identifier, ruleID=rule[@"id"],
  runID=该行显示的 latestRun.id)`。计划列表、规则历史与异常查看保留：分组详情新增只读
  「查看本组历史批次（只读）」，打开既有 `SRRecordHistory`（`historyForRule:`）；异常仍由
  「查看异常与未发项」进入既有分页页。未新增第二套执行状态源。
- **结果**：全文件 `startRule:` 只剩详情页一处；旧页面不再有任何 start/pause/resume/cancel/end
  调用点，规则区页脚改为「点击规则进入执行详情」。
- **覆盖**：`tests/phase_b2_ui_contract_test.py` 新增 6 项契约，锁定冻结配置 A 优先于当前保存
  配置 B（含本地执行的行投影镜像）、无内容时仍只读、旧页无命令调用点、规则行身份
  （account + planID + ruleID + 当前 runID）传入新详情页、历史/异常入口未删除、
  `startRule:` 唯一入口仍是详情页。

### 11.5 验证记录（2026-10-27 上一轮收口，本机 Windows）

- 完整 Python：`329` 项通过（更早基线 `323`，该轮新增 6 项，未删减旧测试）；
  `tests.phase_b2_ui_contract_test` 47 项、与 `tests.phase_b_ui_contract_test` 合计 68 项。
- `tests/small_group_contract_test.py` 的 20 群/命令入口断言改为钉在新详情页与旧页「无命令」上，
  避免旧页被重新加回命令时仍然通过。
- `py -3 -m compileall -q tools tests` 通过。
- 双架构语法检查（同一缓存）：`55` 个翻译单元 × arm64/arm64e = `110` 单元零诊断。
- `git diff --check` 干净。
- 未提交、未推送、未派 CI、未打包、未操作设备。

### 11.6 三项收口（2026-10-27，本轮）

#### 11.6.1 首页暂停/继续绑定点击时保存的 runID

- **根因**：`buildRunActions` 已经把 runID 存进行内，但 `didSelect` 只把 `kind` 传给
  `performLiveAction:`，处理函数又自己再读一次 `execution.currentRunID`。按钮画出来之后若
  挂载批次换成另一条，命令就会发到新批次上。
- **修复**：`didSelect` 传 `action[@"runID"]`；`performLiveAction:runID:` 的判定顺序是
  账号核对 → runID 非空 → 会话属于当前账号 → 当前挂载 runID 与绑定 runID 相同 →
  在途收尾门禁 → 命令。任一项不成立只提示并 `reload`，暂停/继续调用次数为 0；
  `resumeRun:` 用绑定 runID，不再替换成新读到的批次。原有账号门禁、在途收尾门禁与
  环境门禁未改。
- **覆盖**：`tests/phase_b2_ui_contract_test.py` 新增 1 项，锁定动作行携带 runID、点击传递
  runID、门禁顺序、每条拒绝都在命令之前且都 `reload`，并本地执行门禁表：
  同批次允许、A→B 拒绝、批次消失/runID 缺失/账号不符/会话不属于该账号全部拒绝。

#### 11.6.2 `tests/run_projection_test.m` 的三处矛盾

- **占用测试**：`rule-c` 的 fixture 原来是「未解锁 + 占用」，而断言要的是「已解锁但账号占用」，
  与生产门禁顺序（先未解锁、再占用）冲突，运行时会拿到「等待前序分组结束」。改为
  `unlocked=YES, occupied=YES` 并断言「账号仍有活动批次，不能开始另一条」；另加一张
  「未解锁 + 占用」的卡断言仍报「等待前序分组结束」，把门禁优先级固定在测试里。
  生产门禁顺序未改。
- **excerpt 截断**：`limit:8` 对 `"Synthetic body"` 只能得到前 8 个字符 `"Syntheti"`，
  原期望 `"Synthetic"` 是 9 个字符。修正期望，并保留边界覆盖：长度正好等于 limit 原样返回、
  多一个字符即被截断、`limit` 大于长度原样返回。
- **来源时间**：`localTimeWithZoneText:` 的格式是 `yyyy-MM-dd HH:mm:ss zzz`，长度 16 的
  `wellFormedMinute` 永远不成立。新增独立的 `wellFormedSecondsWithZone()` 检查秒与时区后缀，
  来源时间与 envelope 两个入口改用它；运行开始/结束时间的分钟格式检查保持不动。
  产品格式与预期都没改，没有删断言、没有跳过目标。
- 同时纠正 `tests/phase_b2_ui_contract_test.py` 首部说明：`tests/run_projection_test.m` 只是
  Foundation 纯投影测试，不覆盖 UIKit 布局、触摸或页面导航。

#### 11.6.3 只读分组的群名单入口

- **根因**：只读分组行点开后进入 `planID=nil` 的执行详情，那里只有一句占位文案，
  用户看不到这一组的目标群。
- **修复**：只读行改为打开既有只读文本查看页（`SRSourceTextScreen`，同一个
  `verifyAccount` 回调），正文由该行已投影的 `name` / `targets` / `targetNames` 组成，
  名称缺失时只显示标识。不创建 plan、不进入占位详情、不调用 `smallGroupRulePreview:`、
  不重查宿主、不读图片、不开放任何执行动作；数据仍来自内容冻结配置，只有在完全没有内容时
  才来自已保存配置。
- **覆盖**：`tests/phase_b2_ui_contract_test.py` 新增 1 项，锁定只读分支不再进入详情页、
  查看页只使用行内字段且复用既有 viewer、无 store/host/media 访问、账号核对在打开之前，
  并本地执行 A/B 构造：冻结 A（两条目标）与保存 B（另一条）不同，打开的只读正文仍是 A 的目标，
  不含 B 的标识；无 plan 时页面上没有任何执行命令。

#### 11.6.4 本轮验证

- 完整 Python：`331` 项通过（上一轮 `329`，本轮新增 2 项，未删减旧测试）；
  `tests.phase_b2_ui_contract_test` 49 项、与 `tests.phase_b_ui_contract_test` 合计 70 项。
- `py -3 -m compileall -q tools tests` 通过。
- 双架构语法检查（同一缓存）：`55` 个翻译单元 × arm64/arm64e = `110` 单元零诊断。
- `git diff --check` 干净。
- `tests/run_projection_test.m` 的**运行**未在本机执行（Windows 无 Foundation）；
  该文件本轮只做了语法层检查，三处断言的实际取值结论仍待 macOS CI。
- 未提交、未推送、未派 CI、未打包、未安装、未操作设备、未发送、未迁移。


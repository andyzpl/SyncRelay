# 运营 v2：阶段 A 数据与事务契约

日期：2026-10-22。以 OPERATIONS-CAPSULE-PLAN.md 第 12 节为准。本文件区分**已实现的底层**和**待实现的契约**；后者不能据此显示为可用功能。阶段 A 的 macOS 原生回归现已取得实际通过证据，真实来源时间语义仍待专项真机核验；详见第 8 节。未变更 1–20 群上限、串行调度及失败/未知不自动重试。

2026-10-23 工程验收更新：schema 14 页面切换修复候选 `51803d43fe06` / `0.2.27+aprobe.2` 在单次 CI `39920510733` 中通过 160 项 Python、原生模拟执行、生产双架构构建与下载后核验。设备已加载 `.2` 并导出八份报告：本人和他人实时文字各 3 条；第 5、6 轮各自观察到旧消息 `older_than_boundary/strict=0` 与新消息 `after_boundary/strict=1`，但两轮 `listeningSince` 与 receiver generation 不同，不能互相证明同一轮停止后保留；图片轮取得 1 条 type 3 早期 hook，实际 getter `I`、server ID 和边界可观察，且无图片读取；最新本人轮只有正常有 server ID 的回调，未取得延迟补 ID 证据。页面切换没有成对前后快照；同一轮离线停止保留、图片资源就绪或完整图片派发观察仍未完成，A 仍未整体验收。产物、安装和迁移边界见 `BUILD-0.2.27-aprobe.2.md` 与 `OPERATIONS-A-DEVICE-READINESS.md`。

2026-10-23 状态更新：双来源消息库、胶囊联动及资源容量管理遵循总计划第 13、14 节，其余第 12 节继续有效。当前 schema 14，A-1/A-2/A-3 已取得精确快照的 macOS 编译、链接及模拟执行通过证据；不包含整个 receiver/UI 工作区的宿主验证。库模式不要求母群/成员，不得伪造群消息身份。UI、库内容实际派发及视频未实现。当前只读设备核验入口、未覆盖项和构建范围见 `OPERATIONS-A-DEVICE-READINESS.md`。

新增资源验收要求：SyncRelay 自有媒体共享 256 MiB 总预算，80% 开始可见提醒、设置页提供容量及安全清理；提醒去重、满额/磁盘不足分类、实际可回收容量、跨账号权限和在用引用保护详见第 13.3–13.6 节。现有随机 UUID 快照、群来源 claim 和仅文字/图片校验并不等于消息库/去重仓库已实现；备份仍仅含配置，不夹带库内媒体或覆盖发送账本。

## 1. 范围对照与顺序

| 定稿项 | A 当前进展 | 后续落地/验收 |
| --- | --- | --- |
| 12.1 开启前置条件 | 已保存配置的完整性校验、固定缺项 ID；协调器运行前复核 | B 设置页缺项到入口；D 运行中校验失败验证 |
| 12.2 三页面与唯一入口 | 协调器与纯读取快照已新增，尚未挂载宿主 | B 三页面、搜索筛选、保存/未保存提醒；D 退出旧设置球 |
| 12.3 日期时间 | 保留 runs.ended_at；取消请求时间与实际收尾时间分开存储 | B 统一完整日期、本地时区格式化；D 跨天/时区回归 |
| 12.4 短胶囊多形态 | 业务状态仍独立于 UIKit，新增取消状态 | B 三种形态、菜单、进入页面只收纳、原生视觉与手机验证 |
| 12.5 暂停/取消 | 新取消事务仅取消 pending；在途保留、占住互斥位直至收尾；不会恢复 | B 一次确认与取消收尾 UI；D 真机在途回执验证 |
| 12.6 去重/主动重发 | 原 claims 保留；本文件定义目标级账本与重发批次契约，**尚未实现** | C 迁移回填、目标级 claim、明确重发及双击幂等 |
| 12.7 新群自动分组/排除 | 既有分组器可规范化排除；本文件补齐基线、偏好与撤销授权契约，**尚未接通活动任务** | C 按账号长期开关、自动补逻辑组、原子撤销未发授权 |
| 12.8 免密码备份恢复 | 本文件固定首版封装与原子恢复方案，**无导入/导出实现** | C 编解码、回滚事务、设置导入；宿主文件菜单单独适配 |
| 12.9 测试入口退出 | 尚未删除，避免联动未就绪却丢失诊断入口 | D 联动验收后清理日常入口，不清校验及发送占位 |
| 12.10 统一控制与事务 | 新协调器全部命令互斥且绑定显示账号/内容/运行 ID，集中开始/暂停/继续/取消及显式接回旧运行；未挂载旧入口；内容/计划关联、取消、旧运行接回各有事务；macOS 模拟回归三轮通过 | A 真实来源时间专项核验；C 接通重发/排除/配置恢复；D 验证所有入口共用同一实例 |

A 未整体验收前不进入 B 视觉实现。不用“未在首包”排除重发、新群、备份，也不为了 UI 先清理既有去重或放宽执行限制。

## 2. 已实现的账号内容记录与协调器

当前 schema 14。schema 10 在 8/9 的基础上增量添加：

- `operations_contents`：账号、母群、服务器 ID 唯一；每账号最多一个未归档内容。持久冻结配置、素材引用、捕获时间、关联 plan ID 和归档时间。尚只接纳已经准备好的素材，图片准备中占用需在 C 接入。
- `operations_cancellations`：run ID 唯一；请求时间 requested_at 与最终收尾 drained_at 分离。结束时间仍以 runs.ended_at 展示，不以刷新/打开页面时间代替。
- 图片引用保护扩展为 plans + operations_contents（包括最近归档内容）。损坏引用仍保守不清理。暂不清除旧内容行；C 需增加有界素材/摘要保留策略，同时保留独立防重复标记，不以删 claims 换取空间。

schema 11 再增量添加 `operations_legacy_adoptions(content_id, run_id, adopted_at)`，不重建旧表。`operationsContentForAccount` 纯读投影增加 `legacyRun`；未关联的旧活动运行仍阻止开启/新捕获。新增显式 `recoverLegacyRun` 命令与 store 接回事务：只能处理同账号、已有小规模授权、paused/awaiting_resume 且无 submitting 的旧运行，核对原 source_claim、plan/run 来源快照与 allocations/deliveries；在同一事务内新增内容和接回关系。重复命令返回同一内容，插入关系失败则整笔回滚。原 plan/rule/run/delivery/attempt/receipt/claims 均不改，不用新配置重建冻结来源或范围，不自动开启或恢复发送。

### A-1 消息库数据模型（schema 12，仅存储与兼容迁移）

schema 12 增量加入消息库底层，不重建旧表、不改发送 ABI；库内保存不创建 plan/run/delivery/claim，也不发送：

- `library_items`：账号级稳定条目 ID，只有 `kind`（text/image）、创建/更新时间和当前版本指针；不含群 ID、服务器消息 ID、claim、计划或运行引用。
- `library_versions`：条目内 `ordinal` 单调递增的内容快照。触发器拒绝 UPDATE 与 DELETE，编辑只能追加新版本，旧版本永不被改写；过期编辑器的 `expectedVersion` 不匹配时整笔拒绝。
- `media_assets`：`(account, scope_sha256, sha256)` 唯一。同账号相同字节复用同一 token，跨账号不共享；复用只省一份文件，不合并条目、版本、计划或发送任务。
- `media_references`：素材引用关系，`owner_kind` 限定 `library_item` / `library_version` / `plan` / `run` / `history`。启动清理改为“计划/内容/活动运行快照引用 ∪ 引用表”，旧随机 UUID 素材只要仍被引用就不会被当孤儿删除。A-1 只写前两类，其余留给 C。
- `content_sources`：捕获内容来源标识 `group_sync` / `message_library`。迁移把既有 `operations_contents` 逐行幂等回填为 `group_sync`；读取投影在缺行时按 `group_sync` 返回（当前唯一的写内容路径）。库来源内容必须在 C 接通时显式写入该行，不能依赖默认值。

11→12 仍是 `CREATE TABLE IF NOT EXISTS` + `PRAGMA foreign_key_check` + `PRAGMA user_version=12`，同一事务内失败整体回滚；不 DROP、不清空、不改旧行，旧 UUID 图片继续按原 payload/scope 读取。256 MiB 总预算、20 MiB 单文件上限、单群 20 目标上限和串行调度均未变。

### A-3 库内容冻结与幂等任务（schema 13→14，共享执行主干、仍不派发库内容）

schema 13 增量加入 `plan_sources` 与 `library_tasks`，schema 14 再增量加入 `library_deletions` 与 `operations_source_modes`；仍是 `CREATE TABLE IF NOT EXISTS` + `PRAGMA foreign_key_check` + `PRAGMA user_version=14`，一个事务内失败整体回滚；不重建 `plans`/`rules`/`runs`，不改文字/图片发送 ABI。库表触发器改为在同一事务内 `DROP ... IF EXISTS` + `CREATE`，见下方返修小节。

- `plan_sources`：`plan_id` 主键，`source_kind` 限定 `group_sync` / `message_library`；库来源必须同时带 `library_item_id` 与 `library_version_id`，群来源两者必须为空。触发器拒绝给“仍带 source_group 的计划”登记库来源，因此不能靠伪造群 ID 把库计划伪装成群来源。缺行仍按 `group_sync` 解释（与 `content_sources` 同一约定）。
- `library_tasks`：一次显式确认 = 一个独立 task 身份。含 `confirmation_id`（幂等键，`UNIQUE(account, confirmation_id)`）、冻结的 `item_id`/`version_id`、独立 `plan_id`/`rule_id`、启动后唯一的 `run_id`、`frozen_snapshot` + `frozen_sha256`、`target_sha256`/`target_count`、`origin_task_id`（重发来源）。触发器拒绝任何改写冻结字段的 UPDATE（只允许 `run_id` 由 NULL 置一次）与任何 DELETE。
- 冻结快照形如 `{type, payload, account, sourceKind:"message_library", itemID, versionID, generatedByRelay:false}`，**不含** `group`/`sender`/`messageID`；库计划的 `plans.source_group` 为空串。因此 `matchesEnvelope`、`smallGroupSourceForRule` 与 `SRRunner` 的来源校验永远拒绝它，也不写 `source_claims`。
- 确认只写 plan/rule/allocations/task，**不建 run、不建 delivery、不发任何消息**。`startLibraryTask` 才建立唯一 run（`awaiting_resume`）与全部 pending delivery；重复 start 返回同一 run。
- 三个不同入口：普通继续 = 既有 `resumeRun`（只吃 pending）；重新发送 = `resendLibraryTask`（新 `confirmation_id` → 新 task，快照取原冻结字节，绝不读可编辑条目，不删 claim）；取消 = 既有 `cancelOperationsRun`。
- 互斥：冻结任务与启动都要求账号无未归档群内容、无活动运行；群捕获要求账号无活动运行（库 run 也在 `runs` 中，天然互斥）。同一素材可用不同 `confirmation_id` 建两个独立任务，但同一时刻只有一个活动执行（既有 `one_active_run`）。未启动的库任务不占发送位。
- 旧回调：`resumeRun`、`claimNextForRun`、`recordResultForDelivery` 先查 `library_tasks.run_id`；`startRule` 与 `smallGroupSourceForRule` 先查 `plan_sources`。库任务不可能被旧原生发送链路取得 delivery、写入结果或复用规则。
- 本批**不派发库内容**：`libraryTask.dispatchAvailable=false`，继续入口对库 run 明确拒绝而不是伪造运行态。观察到的事实是“本构建没有实现、也没有验证任何库内容派发路径”；之前写成“需要与转发群消息不同的组合式发送 ABI”属于未验证判断，不作为结论引用。

旧计划未保存的显示名称仅用稳定 ID 作占位，不能猜新名称；旧规则间隔不一致、来源损坏、无授权或范围不一致时明确拒绝，原记录保留。旧版没有可信捕获时间，数据库 captured_at=0 仅作接回记录哨兵；读取时返回 `captureTimeKnown=false`、`captured_at=null`，另附真实 adopted_at。B 必须显示“捕获时间未知”，不可展示 1970 日期或用接回/页面打开时间代替。缺失图片不妨碍结构化接回、保留历史和取消，但既有执行器的素材校验仍拒绝继续。

### A-3 返修（schema 14 增补：占用投影、幂等键、冻结约束）

本轮不新增 UI、宿主菜单、视频或发送 ABI，只修正 A-3 审查发现的四处缺陷。schema 保持 14（`library_deletions`、`operations_source_modes` 为前一批增量），改动都在既有表上的约束与读取投影。

**占用投影。** 把库 run 从 `legacyRun` 排除后，账号不能因此被当成空闲：`operationsContentForAccount` 增加账号隔离的 `libraryOccupancy`（`taskID` / `runID` / `state` / `startedAt`，仅取 `running` / `paused` / `awaiting_resume`），它既不是可接回的 legacy 内容，也不是群内容。协调器把 `content != nil || libraryOccupancy != nil` 作为 `occupied`，并在 `updateCapture` 的状态判断之前就返回：库任务占用期间不 arm，也不把已监听的捕获留在运行；`captureState` 投影为 `library_occupied`。快照新增只读 `libraryTask`，不提供任何库内容派发入口，`dispatchAvailable` 仍为 false。这是为了避免“先启动群捕获、再在 `saveOperationsContent` 必然失败”的路径，而不是开放库发送。

**幂等键。** `confirmation_id` 是**整份请求**的键，不是任务指针。重复确认必须同时匹配：条目、解析后的版本、目标集合与顺序（`target_sha256` + `target_count`）、发送间隔（`rules.minimum/maximum`）、以及操作来源（create 为 NULL，重发为原任务 ID）。完全相同才返回原任务；任一不同即拒绝，绝不返回另一份任务。`resendLibraryTask` 因此不能复用 create 的键，也不能借用另一个任务的键。`version=nil` 只在首次确认时解析为“当时的最新版本”，条目编辑后带同一 key 重试会解析到新版本并被判为不同请求而拒绝，不会静默换版本；需要旧版本必须显式传该版本 ID。

**冻结约束。** `library_tasks` 唯一允许的修改是 `run_id` 与 `started_at` 由 NULL 一次性置值（两者必须同时给出）；身份（`id`/`account`/`confirmation_id`/`item_id`/`version_id`/`plan_id`/`rule_id`）、`frozen_snapshot`/`frozen_sha256`、`media_token`、`target_sha256`/`target_count`、`origin_task_id`、`created_at` 全部不可变，已挂 run 后任何 UPDATE 都被拒绝，DELETE 永远被拒绝。比较一律用 `IS` / `IS NOT`（正确处理 NULL），因此“NULL 改成非 NULL”同样被拦住。读回时 `media_token` 必须与冻结 payload 里的 `mediaReference` 一致，且该 token 属于本账号的 `media_assets`；`startLibraryTask` 建立 run 级引用时取冻结 payload 里的 token，不取未核对的列值，所以不会为错误 token 建立运行引用。

**触发器升级。** `CREATE TRIGGER IF NOT EXISTS` 不会替换已有定义，schema 13 开发库会一直保留旧触发器。改为在同一个迁移事务内 `DROP TRIGGER IF EXISTS` + `CREATE TRIGGER`，源码成为唯一定义来源；不重建表、不改写任何行、不清库，失败整体回滚。该做法对 schema 13 与 14 的开发库都有效。

### 消息库类型范围与能力位（契约，仅文档）

首期类型为文字、静态图片、视频；文件、链接、名片、自定义表情、语音为后续计划，本轮不实现。库条目、不可变版本、冻结任务、素材引用与配额是通用底座，不为任何类型复制表或任务身份；类型差异只在 payload 校验、素材准备、预览和发送适配四处。

每个类型分别给出 `importAvailable` / `previewAvailable` / `dispatchAvailable` 三个能力位，互不蕴含，取值只能来自已实现与已验证的能力，禁止用单个 supported 掩盖缺口。当前状态：文字与静态图片导入链路的精确隔离快照已在 macOS 原生模拟执行通过，不是宿主主动导入入口或真机验收；**任何类型的库内容派发都未实现**，视频三项均未实现。

payload 格式版本按类型独立：图片有 `snapshotSchema`（当前 1），文字 payload 无版本字段、缺省按版本 1 解释；写入只写当前版本，历史版本不就地升级（版本不可变）。未知类型、未知版本或损坏 payload 一律保留记录、拒绝预览与派发，不猜字段、不降级成文字发送。

`library_items.kind` / `library_versions.kind` 的 CHECK 目前只允许 `text` / `image`。新增类型必须用单事务表重建（建新表 → 原样复制 → 删除旧表 → 重命名 → 重建索引与触发器），期间按外键依赖关闭并复核 `PRAGMA foreign_keys` + `foreign_key_check`，保留全部旧行、不取消既有触发器与唯一约束。本轮不执行该迁移。

`SRRelayCoordinator` 仅依赖 store、捕获控制端口和执行端口，主线程接收命令；`snapshot` 深冻结返回，纯读取不建计划、不启动、不监听。刷新生命周期可重新 arm，但只有可信账号、开启、前台、无占用、来源时间能力可信且无锁存故障时允许。无来源时间证据投影为 source_check_required，不冒充正在监听。持久化/捕获故障锁存安全停止，需要明确纠正或重新开启，不靠页面重绘悄悄恢复。

第三批把互斥覆盖到开启、保存后刷新、候选提交、分组准备、归档和旧运行接回，而不只开始/继续。端口抛出异常时使用固定错误安全停止，不显示宿主异常原文；暂停后最多再读一次验证落盘，端口虚报成功不会无限递归刷新。宿主调用中重入的生命周期事件先使当前投影不可信、旧捕获代次失效，再在当前命令结束前有界应用最新状态；不在重入栈里开启第二个命令。配置不完整或总开关关闭时，可信账号的安全暂停/取消/归档仍可用，不允许用这些入口恢复派发。

第四批补正两类边界：编辑配置 JSON/字段损坏时，冻结内容和任务单独读取，缺项投影为 configuration_invalid 并锁存故障、暂停派发；只要冻结任务及当前账号仍可核对，暂停/取消/归档不被编辑配置损坏连带封死。`stateLoaded` 不等于配置已就绪，开始/继续/捕获仍受原完整校验及故障门槛限制。配置修好后也不自动恢复，需要显式重新开启。

安全命令以自己的持久结果及同账号任务投影复核为准：编辑配置仍损坏不妨碍已确认的取消/归档返回成功，但故障提示保留，不宣称重新监听。任务投影读回失败则不报成功，明确取消/归档可能已提交，重读后沿原 ID 处理，不能为了“失败回滚”删除真实取消或恢复 pending。已接回运行的重复 recoverLegacyRun 只返回现有关系，不清故障、不改手动继续许可、不把已恢复的健康运行误暂停。

第五批把操作身份纳入公开 API：快照增加可信 `account`，账号不可核对时为 null；`setEnabled`、`startGroup`、`recoverLegacyRun` 接受预期账号，`prepareGroupsForContent` / `startGroup` / `finishContent` 同时接受内容 ID，`pauseRun` / `resumeRun` / `cancelRun` 同时接受运行 ID。每个命令在统一 owner 内重新核对当前账号和所指记录，错误账号/旧运行/旧内容不能作用到新的占用任务。B/C 入口必须从用户当时查看的快照保存这些标识，确认回调不能用新快照替换目标；不提供无标识的“取消当前组/结束当前内容”旁路。生命周期本身的安全停止仍可执行，拒绝旧操作不等于跳过真实账号切换保护。

结束内容在当前账号任务投影可信时，可对最近归档的相同内容 ID 幂等返回，包括首次归档提交后读回失败、之后恢复读取的情况。它不再次调用归档事务，不重写日期、不解除故障锁存；即使已捕获替代内容也只确认原记录，不结束替代内容。更老或未知 ID 明确拒绝，不能降级为操作当前内容。开始分组也先验证冻结规则属于本内容的已加载列表，再调用执行端口，避免晚点击旧分组时顺手为新内容建计划。

### 脱敏运行诊断（第六批）

协调器状态转移和失败路径使用 `SRRuntimeLog` 的固定事件 allowlist。成功事件覆盖总开关、捕获接收、计划准备、分组开始/继续/暂停/取消、旧运行接回及内容归档；预期拒绝记录 `operations_command_rejected`，端口异常、未提供错误的失败或重复生命周期重入记录 `operations_fault`。每条协调器诊断只携带数值 `reasonCode`，不会把账号、群/成员 ID、运行/内容 ID、正文、图片路径或宿主异常原文写入日志。日志仍受既有 300 条内存上限、持久化大小限制和数字 facts allowlist 约束；重复的纯快照刷新不产生事件。

`SRRuntimeLog` 的脱敏测试覆盖固定事件保留、非数字字段丢弃和敏感标识不落日志。该诊断仍是维护/验证证据，不表示协调器已经接入宿主，也不替代 macOS 执行、真实来源时间语义或真机验收。

第七批补充失败分类边界：协调器在创建 fallback `NSError` 前保留端口是否提供错误的事实；执行端口返回 `NO` 但未提供错误时记录 `operations_fault`，同时保留冻结计划和可重试状态，不把静默端口故障标成普通命令拒绝。

第八批补充账号确认顺序：所有带账号的公开命令先读取当前宿主账号并与页面保存的账号比较，再调用 `reloadAllowPause`。这样旧页面的延迟确认会在无副作用的预检阶段拒绝，不会借账号切换的安全关闭流程关闭或暂停新账号；生命周期自身的账号切换刷新仍按原规则安全停派并要求新账号显式开启。

第九批将配置编辑保存后的刷新回调也纳入同一边界：公开入口为 `configurationSavedForAccount:error:`，先做当前宿主账号预检，再 reload 并复核同一账号；不提供无账号的配置刷新旁路，避免旧页面保存通知改写新账号状态。用例同时核对全部带账号命令在宿主已切换、生命周期尚未刷新的间隙不会调用执行端口或改写新账号开关。

第九批同时修正最近运行投影：运行卡片和历史查询统一返回 `creationOrder`（沿用现有历史的 `runs.rowid` 插入顺序），有活动运行时仍优先活动运行，无活动运行才选最后插入的记录。`started_at` 可能相同或回拨，不再用它决定记录先后；`started_at` / `ended_at` 只作为真实日期显示来源，不被刷新、排序或重开库改写。该变化不改 schema、发送账本或执行限制。

第十批将异步捕获也纳入 reload 前预检：回调必须仍属于已监听的代次，envelope 账号必须与原 owner 一致，当前宿主账号也必须可读且相同。旧/错误代次或账号事件直接拒绝，不能触发新账号安全关闭、暂停或无关的状态读取故障；生命周期刷新仍负责真正的账号切换。预检不代替 reload 的配置重读及后续代次/时间校验，配置已保存但未通知时，旧条件产生的内容仍会拒绝。

第十批最近归档投影改按 `operations_contents.rowid` 的持久插入顺序：唯一活动内容约束保证先归档再创建下一条，因此顺序与同账号占用结束顺序一致。回拨或相同的 `archived_at` 不再把最近完成摘要和幂等重试对象误选成旧内容；原始时间值、内容占用、取消记录及所有发送账本保持不变。当前不删除/重插历史内容；C 后续有界保留仍须保住最近摘要及该顺序，不能以刷新或清理改写实际日期。

第十一批补充同账号生命周期重入：端口执行中，后台→前台或来源能力撤销→恢复可能被合并成最终前台，但中间的停派要求不能被覆盖。纯 C `SROpsPauseRequired` 将待处理生命周期列为强制暂停条件；开始/继续端口返回后重新加载时，若运行仍为 running，先暂停并有界复核，最终处理延后通知前再次清空 `manualRun`。一次健康重入不关闭开关、不要求额外重新开启，但必须由用户再次明确继续；不重建运行、不清 pending/claims，不自动下一组。反复重入、暂停不落盘仍保留原故障门槛。

第十二批将故障入口也纳入许可撤销：设置故障后、调用捕获/暂停端口前清除 `manualRun`。只保留 fault 不够，因为重新开启会尝试清除故障；如果暂停拒绝或虚报、持久 run 仍为 running，旧许可不能随重新开启复活。端口恢复并实际落盘暂停后，开启成功也只保留原 pending 等待手动继续，在途回执与 claim 仍按原记录收尾。

打开分组是 `prepareGroupsForContent` 命令，在内部建立并关联计划，不需要额外确认页面；成功后返回冻结计划规则 ID。计划/规则/分配/来源 claim/内容关联在一个事务提交。启动失败保留同一计划及已建立的暂停 run，准确原因出现在命令结果和状态快照；继续操作只附加原 run。

当前执行端口仍用既有公开小规模执行 API，保留旧版“前组结束后可开始后组”的限制。v2 分组任意选择需要 C 的运营专用启动事务消除这个旧流程门槛（不改变单运行互斥）；不能用界面解锁提示绕过存储校验。自动结束全部内容、图片准备阶段持久化也尚未接通，不宣称完整闭环完成。

生命周期与捕获代次只过滤捕获事件。执行结果始终按原 run/delivery/attempt 写入 store，之后以当前账号重新投影；关闭、账号变化不能丢弃旧回执。协调器构建不恢复发送，宿主恢复前要先在单一生命周期 owner 中调用 interrupted-run 恢复，不能在两个活跃 owner 间重复执行此恢复。

宿主桥接仍未实现：当前 UI/SREntry 未实例化新协调器，receiver 也未实现新捕获端口。不能同时启用新旧控制器，不能通过轮询设置页或自动点击旧按钮接线。

### 来源时间证据测试接口（未开放自动捕获）

`SRWeChatReceiver` 新增注入时钟、receivedWithTimeEvidence 回调和默认关闭的 newMessagesOnly 严格模式；现有手动入口仍走默认模式。严格接口要求有声明的整数 m_uiCreateTime getter、有效时钟和证据回调。读整数依据真实声明 ABI，不信任对象覆盖的 reflection，不调用浮点/指针/仅转发 getter，负数或不可精确表示的超大值不作时间证据。

hook 在调用宿主原方法前冻结 receivedAt、createdAt、listeningSince 和原代次；原方法仍只调用一次，宿主异常仍由宿主传播。后续文字主队列、本人消息服务器 ID/readback、图片等待/资源准备均沿用这份证据，时间被改写或 stop/rearm 后晚回调不能变成新候选。严格模式复用 C 策略：旧/同秒/未来/无效时间拒绝，墙钟倒退也安全拒绝；历史图片在原生资源准备前拒绝。素材交给消费者后，即使消费者抛异常，也不由 receiver 擅自删除可能已持久引用的素材。

这是可模拟的适配方案，不是实际微信字段语义认证。诊断明确返回 sourceTimeSemanticsVerified=false，只记录能力布尔与固定事件计数，不记录每条源 ID/正文或素材路径。C 宿主桥必须在独立核验字段含义后才能给协调器 sourceTimeVerified=true，不能因 getter 存在或模拟测试通过就自行放开自动捕获。

## 3. 取消事务与 pending 语义

已实现的取消事务：核对账号/run → 插入唯一取消记录 → 暂停 run → 只将 pending 写为 cancelled → 若无 submitting，写 ended 和实际收尾时间；否则保持 paused，占用账号互斥位。

原有提交结果事务在落盘回执后检查取消收尾，最终状态为 ended 而不是 completed。中断恢复把 submitting 变为 uncertain，再完成取消；不会写成“取消成功送达”。重复取消不改变日期，也不会再建 run。取消后的普通 resume 被存储拒绝。

新执行端口的 `cancelRun` 不使用旧 `endRun` 清理在途项：不清 host，不增加发送观察代次，不丢弃在途观察。旧 end 如果遇到已进入新取消语义的在途项，也不能把它提前改写为未知并释放互斥位。runner 在实际 ended 后释放内存 owner；没有在途项的取消立即完成，并清理 session 的 busy，不能被已 halted 的 runner 卡住。执行诊断中旧 targetLimit=3 修正为现有真实限制 20，不扩大执行范围。

人工排除不等于取消整组，待 C 接入独立撤销授权记录。普通继续保持：pending 消费一次；submitting 等待；submitted/confirmed 跳过；failed/uncertain 不重试；取消/排除的目标不回 pending。

## 4. 目标级去重与重发批次（待实现）

当前 source_claims 限制来源只建一个计划，native_attempt_claims 限制 delivery 的宿主调用；这不替代 v2 所需“跨分组/重建计划”的源+目标账本。上线重发前必须增加并验证以下事务，不能直接向 UI 暴露低级 `replay:YES`。

- 永久基础账本键：`account + source_group + server_message_id + target_group`。首次尝试登记后不退回未尝试；与分组名称/当前配置无关。用事务内唯一约束，而非内存集合或发送后补记。
- 明确批次记录：batch ID、kind（initial/replay）、account、content ID、原 run ID、冻结目标集合、确认 request ID、确认时间。`account + request ID` 唯一，重复确认返回同一批次。相同 request 但不同源/范围必须拒绝，而非覆盖。
- 批次内尝试账本：`batch ID + target` 唯一，关联原 delivery/attempt。普通初发需同时取得基础账本；重发需有明确授权的 replay 批次，允许基础账本已存在，但每个新批次每目标仍只能取得一次尝试。
- 迁移从旧有效来源快照、attempt/native claim、两个实验账本回填基础账本；旧占位及提交/未知历史全保留。历史重复行只保留历史，不为合并而清空。无法核对来源的记录安全拦截宿主派发并给出原因，不能猜来源 ID。
- 普通恢复只读取原 deliveries pending；不建新批次，不删除 ledger，不复制全量目标。重发确认后才冻结选定范围并建关联新 run；不复用“继续”。20 群、素材就绪、总开关、账号、互斥在事务/宿主前置双重核验。
- 重发尚未完成时其他页面开始也经同一协调器；UI 的 disabled 仅辅助，不承担幂等或互斥。run 与 selected targets 的一致性校验需支持冻结子集，不得削弱旧规则的完整集合校验。

验收：跨组同源同目标、旧计划重新建、进程中断、双击确认、错误 request 范围、旧实验占位、缺图、21 群均覆盖。只可宣称避免重复提交，不宣称网络端 exactly-once。

## 5. 排除与 claim 的原子顺序（待实现）

`saveExclusions` 必须是独立协调器命令，不只是 `saveConfiguration`。store 在同一写事务内：规范化配置并删出被排除目标/空组 → 记录当前内容/运行未发目标的撤销授权及原因 → 把确实未尝试的 pending 标为跳过/取消（保持 allocations/deliveries 行及顺序）→ 提交后才显示成功。失败保留原配置和原授权。

claim 在同一 store 写序列中先查撤销授权，再建立尝试。若排除事务先提交，之后不能取得该目标的新 claim。若尝试先取得，UI 明确列为在途/已尝试，不能许诺撤回。宿主 native claim 之前还需复核撤销授权，覆盖 runner claim 后、主线程宿主调用前的空隙；已开始的素材准备/调用采用保守在途语义，回执正常落盘。主线程宿主桥与配置命令共用 owner，不能有两个队列各自认为对方尚未提交。

撤销授权独立于冻结快照；不删除分配行，不重排剩余目标，不自动补位。解除排除不清旧撤销记录、不恢复旧 pending；新配置需明确重新分配。新群自动加入也不能向旧冻结内容补目标。

验收：排除先/claim 先/runner claim 与 native claim 之间三种顺序，写盘失败回滚、重启、解除排除、两处入口并发保存、全空分组和历史一致性。

## 6. 新发现群与偏好（待实现）

按账号保存一份 `newGroupsAutoAssignEnabled`（默认 false），设置页和自动分组页读写同一存储接口，不能各有 NSUserDefaults 布尔值。逻辑分组容量来自保存的分组规格；旧分组不能从当前 partial 目标数猜容量，未有可靠规格时要求先设置，不静默以 20 或 100 代替用户规格。逻辑 100/200 不代表可实发超过 20。

账号群发现账本保存首次可靠枚举基线与历次 seen ID 的并集；暂时漏读不能删 seen。母群、排除群、已分配群即使不入组也记入基线。首次只记基线不入组；开关关闭时仍记录新发现但不分配，之后打开也不把这些群伪装成刚加入。无法可靠完成首次基线时不做增量自动加入，说明能力不足；无加入时间证据只称“新发现”。

后续稳定新 ID 才按开关处理：在事务内读最新排除与已分配集合、先填未满逻辑组，再建同规格逻辑组，保存配置与 seen/处理结果一起提交。失败两者均不更新，下一次安全重试；不创建微信群，不调用执行器。汇总轻提示，不逐群确认。当前内容冻结配置不变。

验收：首次、漏读重现、开关关闭/打开、两个页面一致、已有分配/母群/排除去重、满组、新建组、事务失败及当前内容范围不扩大。

## 7. 免密码备份 v1 与原子恢复（待实现）

首版工程默认采用**不加密的封装文本**，不提供密码输入，也不声称保密。Base64 只是编码；SHA-256 只检测损坏，不是身份认证或防恶意伪造。这里不使用内置密钥，不把 wxid 当密钥。此选择满足“不直接展示 JSON”的封装要求，不给出“加密安全”承诺。

固定格式建议文件后缀 `.srbackup`；ASCII、LF、正好五行（末行换行）：

```text
SYNCRELAY-BACKUP/1
encoding=base64-bplist
digest=sha256:<64 lowercase hex digits>
payload=<strict RFC4648 base64, no line wrapping>
END
```

摘要针对解码后的二进制 plist 字节。文本总上限 2 MiB，解码上限 1 MiB，无压缩，无附件；读取前检查文件大小，并有界读取（不能先把超大文件读入内存再判断）。拒绝未知头/版本/编码、重复行、额外字段行、无效 base64、digest 错误、过深结构、错误字段类型及资源超限。具体 codec 在 C 以这些固定规则实现和测试，变更格式需增加版本，不静默容忍未知算法。

payload 白名单：formatVersion=1、sourceAccount、exportedAt、配置（母群、成员、类型、间隔、分组、排除）、newGroupPreference/分组规格、capsuleAppearance（边缘、归一化纵坐标、收纳/隐私偏好）。设备账号需稳定且完全匹配。属性列表不得包含 NSDate/NSData 等不在白名单的对象，未知字段拒绝；不递归解释字符串中的路径、URL、指令。

不包含正文、图片/素材路径、凭据、内容占用、run/delivery/attempt、source/target claims、群发现账本。允许配置内的合法群/成员 ID，不把它当认证。换设备只恢复配置，不承诺发送历史/未发任务或防重复记录跨设备继承。

设置导入与微信文件预览菜单共用 `decode → validate → preview → confirmedRestore`。preview 返回来源、组数、目标数、替换差异与确认令牌；令牌绑定账号、摘要和本地配置 revision，确认时全部重检。恢复期间禁止新的开始、捕获或配置提交。旧内容/候选、活动或暂停/在途 run 均要求先明确结束/处理；不能靠关闭总开关就绕过。

确认事务：再次检查稳定账号/无占用/无活动 run/配置 revision → 写本地回滚副本（仅配置/偏好/外观）→ 完整替换配置+新群偏好+外观 → 关闭运营总开关 → 更新 revision 并提交。任何一步失败全部回滚，不删除/导入/修改任何发送账本。外观若仍在 NSUserDefaults，需要先把该业务恢复的权威记录纳入 SQLite；提交后应用外观只是投影，不能先写 defaults 再假称跨存储原子。

本地回滚副本以最近一次成功恢复前配置保存，不随导出携带；恢复成功仍需用户检查并手动开启。读不到的群标为待核对，不自动删除。文件预览菜单适配失败只禁用该入口，设置页导入仍独立可用。

验收：损坏/截断/超大/重复字段/错误类型/未知版本/错误账号/无账号、嵌套资源上限、确认期间配置变化、事务各步骤故障注入、回滚副本、claims 完全未变、导入后开关关闭且无发送；两个入口使用同一模块。

## 8. 当前证据与未验收门槛

### 最新 macOS 原生执行证据

- 运行 [39723869319](https://github.com/andyzpl/SyncRelay/actions/runs/39723869319) 为 `success`；独立分支 `codex/operations-a-native-20261022`，源码 `cadae524da26b01ab31b3fc609dc6bcb71699dec`。18 个 Objective-C 程序完成实际编译/链接并各执行三轮，覆盖下列各批次协调器、存储和来源时间模拟用例；不再以语法检查冒充行为执行，也不再把 macOS 执行列为未完成门槛。
- 隔离快照 86 项 Python、两个 C 程序通过；本地完整工作区 96 项中的额外 10 项为未纳入快照的并行类型探针。运行日志 91 条 PASS 是分项及重复执行输出，不是 91 个独立测试程序。
- `build_deb=false`，五个打包/上传步骤均跳过，artifact 为 0。只向用户指定仓库的独立分支发布运营源码测试快照；main、真实暂存区及并行类型文件未变，没有上传个人诊断或第三方内容。
- 上述运行是首次原生回归，精确来源、后续文字采样回归和日志位置见 OPERATIONS-A-NATIVE-VALIDATION.md；真实宿主语义仍不能由模拟对象认证。后续专项普通 DEB `0.2.21+timeprobe.1` 已构建核验，见 BUILD-SOURCE-TIME-0.2.21-timeprobe.1.md，文字子集的真机步骤与完整待验矩阵见 OPERATIONS-SOURCE-TIME-DEVICE-CHECK.md。

### 来源时间文字采样子集（非运营功能）

`SRSourceTimeProbe` 已复用全局唯一 receiver 接入设置页诊断；默认关闭、明确开始/停止、16 个文字回调/120 秒，保留原始创建整数/首回调/监听边界、另列消费时间；只输出匿名顺序与固定关系码。账号/配置失效清样本；关闭页面不停止，后台停止且不自动重开。采样期间捕获、预览、发送和接口实验互斥，不生成内容/计划/run/claim，不修改发送核心或保存配置。2026-10-23 本地补充：`WillResignActive` 仅启动 2 秒单调时钟宽限，`DidBecomeActive` 在清除 pending 前重算超时；超时或 `DidEnterBackground` 立即按 `inactive` 停止并释放 receiver。该补充只改变观察器生命周期，尚未取得成功的原生编译、模拟、打包或真机验证；`.3` 包不含此补充。首次 `.4` CI 已实际编译并执行到新增 lifecycle 程序，但测试错误地期望超时后的幂等手动停止改成 `stopped`；实现保留 `inactive`，测试已修正，未自动重跑。当前本地 Python 全量 180 项通过（分析器 44、probe 契约 10）。页面切换验证必须在 2 秒内返回，A/B 均要求 `inactivePending=false`；超过 2 秒应停止，不能当作“切页后仍可采样”。

采样 arm 仅在配置副本选择 text，不进入图片资源准备链。实际 wrap 的逐对象 ABI、图片延迟、被 receiver 提前过滤的事件仍未覆盖；配置类 getter 编码或假设 epoch 秒的本地策略命中，均不能把来源语义认证从 false 改为 true。该模块的匿名消息序号是本轮有界关联，不是目标级持久防重，不冲抵第 3–7 节的 C 阶段实现。首轮采样原生回归已通过；复核另补同步停止通知内明确重开时的轮次围栏及模拟用例，最新本地 102 项 Python、C 状态/间隔及双架构 98 单元语法通过。逻辑提交 `91b310d...` 已独立通过 19 个 Objective-C 程序各三轮、92 项 Python 和两个 C 程序，证据见 OPERATIONS-A-NATIVE-VALIDATION.md。

随后独立打包提交 `c9be95413384e30416abdc356505295a947ac9df` 只调整隔离版本/范围说明，不改生产逻辑或测试；[39730283085](https://github.com/andyzpl/SyncRelay/actions/runs/39730283085) 一次 `build_deb=true` 成功，重新通过相同规模的回归和精确快照 98 单元语法检查。普通 DEB 的散列、包身份、两架构内嵌版本/提交/run/文字入口均已复核；不是 RootHide 转换，不包含并行类型新增功能。与已有插件共用包 ID，切换前核对当前构建及 schema，不清数据库或 claims 来降级。当前没有本包安装或真机采样结果。

### 各批次本地检查记录（保留当时状态）

以下“尚待 macOS”“只有语法证据”等是各批次当时的记录，已由上述实际运行补齐；不将这些历史限制重复列为当前缺口。

- C 状态机执行测试通过：补充取消收尾、取消恢复不变普通继续、来源时间旧/同秒/未来/异常值拒绝；第十一批新增停派策略 2560 组布尔/阶段/配置/延后通知组合，最终前台也不能覆盖待处理生命周期的暂停要求。
- 本地 Python 当前全套 96 项通过（包含并行类型探针用例及第十二批新增的源码顺序守卫），其中运营 SQLite schema/关键 SQL 实际执行测试为 17 项；第四批增加 schema 11 版本/表一致性、9/10→11 的配置/内容/取消与全部发送账本逐行保留、外键损坏时新表及 user_version 整体回滚，第五批增加归档 SQL 对活动/在途任务的阻断、按原内容 ID 更新且不影响其他内容及发送账本，第九批增加回拨/同时间戳下卡片与历史按插入顺序一致，第十批增加回拨/同值时最近归档不误选、账号隔离、当前内容及所有账本不变；保留第三批接回唯一/FK 和写盘失败回滚用例。SQLite 用例执行抽取的生产 SQL；源码守卫只检查撤销许可先于端口调用，旧实现失败、修改后通过；二者均不执行 Objective-C 迁移或协调器 owner。C 状态与间隔执行测试通过。
- arm64/arm64e 共 94 个编译单元语法检查通过，报告为 `.build-cache/syntax-report.json`，第十二批日志为 `.build-cache/syntax-operations-a12.log`；`git diff --check` 通过。这些检查不包含链接、Objective-C 执行、打包或真机行为验证。
- 新增 Objective-C 用例覆盖：schema 9→11 保留旧 claims/回执并显式接回、接回失败回滚/幂等/账号隔离/未知捕获日期、缺图不允许继续但可取消；全部命令重入拦截、能力撤销后的旧代次、端口抛异常/暂停虚报成功/生命周期重入；声明时间 getter、离线旧消息/同秒/未来/时钟倒退、延迟本人消息/图片的原始证据、准备期间时间变化和消费者异常后不删已交付素材。已纳入 macOS 测试入口，但本机未执行 Objective-C 程序，尚待 macOS 验证；未公开推送或触发 CI。
- 第四批 Objective-C 用例再覆盖：编辑配置损坏后仍可安全暂停/取消/归档、归档写入失败保留当前内容、取消已提交但投影读回失败后的原 ID 幂等重试、接回后手动继续再重复接回不暂停/重建。这些用例只有语法证据，不能标为执行通过。本批未修改并行开展的消息类型适配。
- 第五批 Objective-C 用例覆盖：错误账号操作不影响健康运行；旧运行的暂停/继续/取消不转移到下一组；旧内容的准备/开始/结束确认不建新计划或结束替代内容；切换账号后旧设置页不能开启新账号；归档提交后读回故障沿原 ID 重试，日期、取消记录、计划数量不变，故障锁存不因幂等确认自动解除。既有调用用例同步为带标识 API，仍只有双架构语法证据，未执行 Objective-C 测试。
- 第六批新增运行日志用例覆盖协调器诊断事件 allowlist、非数字 facts 丢弃、账号/运行 ID 等敏感字段过滤；协调器端口异常用例核对只记录 `operations_fault` 而不暴露宿主异常文本。相关 Objective-C 测试仍只有双架构语法证据，未在 macOS 实际执行。
- 第七批新增静默执行失败用例：端口返回 `NO` 且不写入错误时记录 `operations_fault`，冻结计划仍可重试；相关 Objective-C 测试仍只有双架构语法证据，未在 macOS 实际执行。
- 第八批新增跨账号延迟开关用例：当前宿主账号已切换时，旧账号命令在 reload 前被拒绝，新账号的持久开关不被误关；相关 Objective-C 测试仍只有双架构语法证据，未在 macOS 实际执行。
- 第九批新增跨账号延迟配置保存及全部带账号命令矩阵；另增两组结束后时间回拨、同时间戳及重开库的当前运行投影用例，核对真实结束日期、取消记录与统计不变。相关 Objective-C 测试只有双架构语法证据，尚待 macOS 链接执行。
- 第九批修复 macOS 协调器测试源清单遗漏 `SRRuntimeLog.m`，本地 Python 增加链接源及测试执行入口清单回归；这里只校验配置，不冒充实际链接或执行，没有触发 CI。
- 第十批新增 Objective-C 旧捕获代次/错误或不可读账号的无副作用拒绝、配置已保存但未通知时重验、归档提交后读回失败叠加时间回拨/同值/重开库及原 ID 重试用例；不关闭新账号、不因无关读故障锁存健康监听、不重写真实日期或结束替代内容。上述执行用例尚待 macOS；本批不修改并行消息类型适配。SQLite 归档排序用例已实际在旧查询复现失败，修复后通过。
- 第十一批新增 Objective-C 同账号前台通知、后台→前台及来源能力撤销→恢复分别重入开始/继续端口的用例，核对最终先暂停、不开新运行、不重置 pending、保持开启及后续显式继续。只有对应纯 C 停派策略已在本机执行；完整协调器重入用例尚待 macOS 链接执行，不能用语法通过冒充已运行复现。
- 第十二批新增 Objective-C 四组故障恢复用例：任务读回失败后，暂停拒绝/虚报分别组合有/无在途；重复开启不能重获旧许可，修复端口后实际暂停但不自动继续，在途原回执可收尾、旧 native claim 不释放、原内容/计划/运行及 pending 不重建。源码顺序守卫已经执行，完整协调器行为用例仍只有语法证据，尚待 macOS 链接执行。
### 当前仍未验收的范围

- A 尚缺真实宿主来源时间的 ABI、单位、语义与离线补同步证据；不能因本次模拟通过而认证字段。此前缺少的 macOS 实际执行现已补齐；文字专项包已核验但仍未覆盖实际 wrap ABI/图片延迟，全部真机证据仍待采样；旧类型探针包不能替代，A 不标整体验收通过。
- 旧运行显式接回、可验证时间方案和脱敏诊断已有实现及本次原生模拟执行证据。协调器仍未接宿主，图片准备阶段占用、全部组结束自动归档及完整自动闭环待 C；重发账本、撤销授权、新群及备份模块也按 C 推进，不提前标为通过。
- B/C/D 未开放；当前手机包仅供文字来源时间采样，打包不等于运营闭环交付。没有上传第三方包或个人诊断，不删减 v2 第 12 节已纳入 C 的新模块。
- A-1（schema 12 消息库数据模型）只有本地 SQLite/模型执行证据：新增 12 项库模型用例，全套 Python 共 115 项通过；新增 `tests/library_test.m` 已加入 macOS 测试清单，但本机无 clang，尚未链接执行，不能把清单检查或语法检查说成运行通过。图片/视频导入入口、UI、长按菜单、库→计划/发送链路与视频类型均未开始。
- A-2（共享媒体配额、预留与安全清理底座）落地为纯 C 账本 `Core/SRMediaQuota.{h,c}` + 持久提醒 `Core/SRMediaAlertState.m`，未改 schema（仍为 12）、未改发送链路、未接 UI。口径：256 MiB = 268435456 字节为**全局唯一**预算，覆盖群同步快照、消息库媒体、派生文件与临时文件，跨账号共享；按 `st_dev/st_ino` 去重，同一物理文件只计一次；SQLite 与微信自身缓存不计。80% 用整数交叉相乘判定（`used*5 >= limit*4`），75% 为可覆盖的回落带默认值。写入前先预留，检查与累加在同一把锁内完成；写失败释放预留且不留半成品（临时名 `.srtmp` → `renameat` 到 `.srimage`）。错误码区分配额满(3)/设备满(21)/单文件超限(20)/读取失败(6)/写入失败(4)/统计不可用(22)，配额满携带 `shortfallBytes`。清理只针对无引用（快照 ∪ `media_assets` ∪ `media_references`）且无活动预留的 `.srimage` 与超期 `.srtmp`，不递归、不删微信文件/claims/计划/历史。证据边界：新增 `tests/media_quota_test.c`（含 8 线程并发预留）与 `tests/media_budget_test.m` 已加入 macOS 清单与三轮执行，本机无 C/ObjC 编译器，二者**未在本机执行**；本机实际执行的是 15 项静态契约用例与 132 项 Python 全量测试。设置页、胶囊提醒、派生媒体生产者、视频仍为 0。
- A-3（库内容冻结与幂等任务，schema 13）只有本地 SQLite 与源码级证据：新增 `tests/library_task_test.py` 11 项（迁移 12→13 幂等、确认幂等、同素材双任务、编辑不影响冻结、条目/版本/任务不可删、互斥、账号隔离、重开恢复、旧回调守卫），全套 Python 共 143 项通过。新增 `tests/library_task_test.m` 与 `library-task-test` 目标已加入 macOS 清单与三轮执行，本机**没有 clang，未链接、未运行**，因此 `createLibraryTask`/`startLibraryTask`/`resendLibraryTask` 的 ObjC 语义（参数校验、账号归属、真实文件下的素材保留）仍只有代码与 SQL 级证据。库→发送、设置页、长按菜单、视频均未开始；库内容不可派发，`dispatchAvailable=false`。
- A-3 返修（2026-10-22，schema 14）：修正四类缺陷——库 run 的占用投影与协调器门禁、确认键的整份请求绑定、`library_tasks` 冻结约束与媒体 token 回读、触发器升级方式。SQL 侧 `tests/library_task_test.py` 由 11 项增至 20 项并在本机实际执行：同 key 不同目标集合/顺序/数量/间隔/origin、create↔resend 交叉用键、`version=nil` 编辑后重试、单次 run 挂载与全字段不可变（含 NULL→值的拒绝）、schema 13 旧触发器被替换且旧行逐列不变、占用投影按账号隔离且取消后释放、触发器重建与 token 回读的源码契约；全套 Python 154 项通过。原生侧改写 `tests/library_task_test.m`（重发键跨来源反例、占用投影、触发器和媒体回读）并新增 `tests/relay_coordinator_test.m` 的 `checkLibraryOccupancyGate`（库任务活动时不 arm、重启后仍占用、取消后释放、其他账号不受影响、已在监听的捕获被停止）。本机**没有 clang，本轮未编译、未链接、未执行任何 Objective-C 程序**，这些原生用例一律标为**待验证**，不能算通过。Python 用例执行的是抽取后的生产 SQL 与迁移 DDL，不执行 ObjC 分支；源码守卫只核对调用顺序，不代替行为验证。
- A-3 返修复审（2026-10-22，第二轮）：只修编译错误与重启用例，未新增 schema、UI、视频或发送 ABI。① `Core/SRStore.m::libraryTaskUnchecked:account:` 曾被整体复制，导致 `snapshot` 在同一作用域重复声明（编译失败）并重复摘要/身份校验；已删除重复段，保留摘要→身份→禁群标识→`media_token` 与冻结 payload `mediaReference` 一致→token 属于本账号 `media_assets` 的完整链条。② `Core/SRRelayCoordinator.m::updateCapture:` 的 `![self.stopCapture]` 改为 `![self stopCapture]`，并复核全仓 `[self.<属性>]` 形态无第二处。③ `tests/relay_coordinator_test.m::checkLibraryOccupancyGate` 的工厂改为接收 store/执行端口/捕获端口，重启段以 `reopened` 新建执行端口与捕获端口，后续取消、读回、释放与重新捕获均走重开库。另加两条源码守卫并实际执行（`libraryTaskUnchecked` 内局部变量不重复声明、`Core/*.m`+`UI/*.m` 无缺选择器的 `[self.<属性>]` 发送，合法下标不误报）。证据：Python 全套 156 项通过、`git diff --check` 通过；本机无 `clang`/`gcc`/`zig`/`libclang`，亦无 `tools/syntax_check.py --cache` 要求的 `syntax/iPhoneOS16.5.sdk` 与 `python-tools`，因此**真实 Objective-C 语法检查与原生编译/链接/执行均未发生**，未安装或下载任何工具链，原生用例继续标待验证。A 与 A-3 均不因本轮整体验收。

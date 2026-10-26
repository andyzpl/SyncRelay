# 运行诊断与维护流程

**2026-10-25 最新本地状态（未追加 CI/打包/设备动作）：** 离线分析器现在要求 `storageReady` 明确为布尔值；缺失、`null`、数字、字符串或容器值只输出固定的 `storage_readiness_invalid`，不把真值/假值强转为数据库可用性，也不继续解释 `schemaVersion`。新增边界回归后本地完整 Python **225 项**通过；既有隔离 CI `40169810412` 的 **224 项**结果不外推到本次未提交的本地增量。当前 A 阶段不重复页面切换、空采样或同类报告导出；没有新设备报告或宿主语义证据。最新范围见 [本地收口记录](OPERATIONS-A-LOCAL-CLOSEOUT.md)。

日期：2026-10-21。顶层诊断格式为 `reportSchema: 1`；0.2.5 的方向子格式为 1，0.2.6 升为 2，以区分字符串读取依据。已收到 0.2.5 实例签名路径拒绝报告，0.2.6 已用实际 runtime 声明读取修正并在 0.2.7 的 8.0.79.35 报告中观察到本人文字进入预览。诊断不启用发送，不改微信消息处理结果，也不等于真实转发成功证明。最新复现步骤见 `DEVICE-CHECK-0.2.7.md`。

## 手机端怎么回传

1. 从「我 → 设置 → SyncRelay 转发」进入。
2. 重现一次问题：更换母群、重新勾选来源成员并保存，点击等待；如果能够等待，由指定成员或本人发一条普通文字，保持前台。
3. 失败后尽量先不要重启微信，立即打开「更多设置 → 运行诊断」，或直接点「导出运行诊断」。
4. 系统分享面板会提供 `SyncRelay-diagnostic-<随机编号>.json` 文件。用户自行选择存到文件或回传；插件不自动上传，也不把诊断发到任何群。
5. 告知大概复现时间和你看到的提示；正文及真实 wxid 无需提供。重启前导出有利于保留当前回调计数。

## 导出什么，不导出什么

- 版本与来源：插件版本、编译提交、CI run、微信版本/构建、iOS 版本、报告生成时间。没有编译身份文件时明确为 `working-tree` / `local`，不假装来自某个发布包。
- 草稿概要：母群是否已选、来源人数、是否包含本人、规则和目标数量、文字/图片开关及未保存状态。**不导出草稿本体、群名、群 ID、账号 ID、来源 wxid 或消息正文。**
- 当前捕获：等待/预览/空闲、候选数量、拒绝数量和数字原因码，不导出源消息。
- 接口观察：入口和 getter 签名、开始时间、固定事件计数、本人文字等待状态与固定错误信息。报告不会主动扫描历史或额外请求服务器。
- 最近操作：固定事件名、时间、会话随机编号及白名单数字字段。事件最多 300 条；同一次等待中，接收过滤分支仅首次写事件，后续只累计计数，避免正常消息刷满日志。
- 本地日志按秒合并写盘，失败时保留内存报告并标为 `write_failed`；可写时跨重启保留最近事件，但突然退出可能丢失最后约一秒。旧日志只接受白名单字段重载。没有接管全局异常处理器，也不能承诺捕获所有闪退。
- 导出文件写在应用临时目录并使用完整文件保护，分享由用户发起。临时导出副本由系统管理；已另存或分享的副本由用户管理。

## 如何定位

先看 `build` 和 `reportSchema`，再看 `draftSummary`、`sourceCapture`、`receiveCandidate.counters`，最后结合 `runtimeLog.events` 时间线。不能仅凭一次回调计数就判断版本兼容或发送成功。

`schemaVersion` 只在 `SRStore` 完成 schema-14 初始化/当前库完整性检查后读回，表示当前 `PRAGMA user_version`。新库从 `user_version=0` 创建并原子设置为 14；旧版本不会被升级。`storageReady` 必须是 JSON 布尔值；缺失或其他类型时解析器输出 `storage_readiness_invalid`，并停止解释数据库可用性及版本。`storageReady=true` 但字段缺失时输出 `database_schema_unverified`；字段为 `null`、非整数或不是 14 时输出 `database_schema_invalid`。`storageReady=false` 时字段应为 `null`，此时只保留 `storage_unavailable`，不重复归因数据库版本。

旧诊断包可能带有 `migrationDiagnostics`；当前分析器只输出 `migration_diagnostics_ignored` 历史提示，不解析其中的源版本、行数或“迁移通过”结论。当前产品不要求、不接受 schema 11 测试库或迁移报告。

| 证据 | 可确定的情况 | 后续动作 |
| --- | --- | --- |
| `capture_arm_failed.errorCode = 14` | 缺少来源成员 | 更换母群后重新勾选本人或指定成员并保存 |
| `capture_arm_failed.errorCode = 15` | 没有非空目标规则 | 先自动分组或选择目标；新母群占满唯一规则时该空规则会移除 |
| `capture_blocked.reasonCode = 1` | 草稿未保存 | 保存后再等待 |
| `capture_blocked.reasonCode = 2` | 没有启用文字，当前不支持纯图片采集 | 启用文字后重试 |
| 等待中，但 `receive_callback` 和 `outgoing_callback` 都为 0 | 本次尚未观察到两个候选入口 | 核对前台状态、复现动作及该版本 hook；不能断定是 wxid 错误 |
| `receive_wrong_session` / `receive_wrong_direction` | 部分回调没通过会话/方向检查 | 对照具体版本核对接口语义；可能只是其他群的正常消息，不直接放宽过滤 |
| `receiveCandidate.sessionRejections` | 在会话门禁前按固定原因累计拒绝：`*_non_string`、`*_empty_string`、`*_other_string`；不保留会话 ID | 区分参数形态与其他会话；仍不能仅凭计数放宽来源群校验 |
| `receive_invalid_sender` | 部分回调没有符合约束的发送者 | 核对 getter 和群消息字段，不改成按昵称猜测 |
| `receive_no_server_id` / `own_timeout` | 消息尚无可用服务器 ID或本人候选超时 | 核对发送后 ID 更新/精确回读；不改用临时本地 ID 冒充 |
| `sourceCapture.lastReasonCode = 22` | 规范化候选被所选 wxid 列表拒绝 | 核对选择的来源成员，不能按昵称替代 |
| `sourceCapture.lastReasonCode = 23` | 规范化候选类型不在选中类型中 | 核对类型开关 |
| `sourceCapture.lastReasonCode = 25` / `capture_rejected.reasonCode = 25` | 证据自证为另一接收轮次，与已绑定轮次冲突 | 重新开始一次等待并重新绑定轮次；不放宽轮次比较 |
| `inactive` 出现在等待开始之后 | 应用曾失活，等待按设计停止 | 保持前台并手动重新等待 |
| `sourceTimeProbe.inactivePending=true` | 只读采样进入短暂前台 inactive 宽限，尚未到 2 秒 | 立即回到微信前台；成对快照不应把该状态当作稳定页面切换通过 |
| `sourceTimeProbe.state=inactive` | 系统级 inactive 超过宽限或真正进入后台，采样已停止且 receiver 已释放 | 回前台不会自动重开，需明确重新开始并换 round |
| `sourceTimeProbe.resumedAfterInactive=true` | 本轮至少一次短暂前台 inactive 在 2 秒内恢复，且采样仍 active | 只证明前台恢复，不证明页面切换完成、系统后台行为或完整生命周期通过 |
| `capture_accepted` / `state = preview` | 冻结了一条匹配源消息 | 用户核对预览，不代表任何目标收到转发 |

### 单群手动发送观察

如果报告包含 `manualSendObservation`，离线解析器会单独输出以下固定证据：

| 代码 | 含义 | 不能据此做什么 |
| --- | --- | --- |
| `manual_outgoing_observed` | 原链之后观察到匹配本人 outgoing 回调 | 不能当作插件已发送或成功数 |
| `manual_local_readback` | 按首条精确 local ID 做了有限回读 | 不能扫描历史或换消息关联 |
| `manual_server_id_transition` | 样本从无服务器 ID 变为有服务器 ID | 不能解释为服务器已送达 |
| `manual_status_changed` | 宿主状态数字发生变化 | 不猜数字含义，不映射成功/失败 |
| `manual_delivery_not_determined` | 观察器按设计不判定送达 | 后续主动发送未知结果必须显示“待核对” |
| `manual_lookup_miss` / `manual_identity_conflict` / `manual_samples_dropped` | 回读未匹配、身份冲突或样本超限 | 不补发、不放宽 wxid/群校验 |

观察报告若出现 `manual_no_outgoing_observed`，只表示本窗口没有匹配回调；它不是发送失败证明。`observerOnly` 必须为 `true` 且 `sendingEnabled` 必须为 `false`，否则解析器会报 `manual_observation_not_read_only`，该报告不能用于适配放行。

### 单群文字实验候选

`singleTextSendCandidate`（子格式 `schema = 1`）记录 `MMContext → CMessageMgr → CMessageWrap` 候选能力和上次实验状态。0.2.10 面板接入显式、一次、单目标文字操作；开关不持久化，关闭面板或重新打开后默认关闭。`build.defaultSendingEnabled = false`、`batchSendingEnabled = false` 与当前 `singleTextSendExperimentEnabled` 分开，不再用一个永远为假的标记掩盖显式单群调用。候选读到服务器 ID 仍只表示主机关联，不是送达。

- `submissionAttempted` / `hostReturned` 区分已尝试调用与主机正常返回；`observing` 表示精确 ID 有限观察尚未结束，`deliveryOutcome` 只能是 `not_submitted` / `uncertain`。
- `singleTextExperimentHistory.claimed` 表示该账号有持久实验占位，调用前就写入，不能证明真的发送；`automaticRetry = false`。同源重复占位在重启后仍阻断。
- `singleTextSendCountdown` / `singleTextExperimentIdleTimerHeld` 分别表示等待中及插件尚持有禁止自动锁屏请求；观察结束才恢复原值。
- 解析器输出固定的 `text_abi_blocked`、`text_environment_changed`、`text_attempt_already_used`、`text_identity_conflict`、`text_delivery_uncertain` 等代码，不回显任意错误文本或私人字段。最新设备步骤见 `DEVICE-CHECK-0.2.10.md`。
- 0.2.11 新增 `initializerArgumentType`（验证到的类型）/ `initializerCallType`（实际构造采用的类型），值限定为 `i/I/q/Q` 或固定的未检查/未调用/不支持状态，不导出任意宿主值。构造所用的 getter 也加入签名列表。旧 0.2.9/0.2.10 报告若明确出现 `q/Q` 编码与构造器拒绝，解析器输出 `text_initializer_width_mismatch`，指向匹配 ABI 的修正版而不是关闭校验；未知签名不推测原因。新步骤见 `DEVICE-CHECK-0.2.11.md`。
- 0.2.12 新增 `serviceEvidenceSchema = 1`、`validationStage` 和最多两个 `serviceChecks` 快照（preflight/pre_submit）。其中上下文/服务分类 0 无对象、1 精确实例、2 子类实例、3 不相关实例、4 类对象；使用真实 runtime 继承关系而非实例反射。快照包含只读解析失败标志及实际 AddMsg/GetMsg 的固定类型 token、参数数目、与基础类是否同一方法和具体失败项；不输出任意类名、地址或对象描述。检查在倒计时、持久占位之前执行，构造后仍复验，不能因预检查通过而跳过最终门禁。完整字段和设备步骤见 `DEVICE-CHECK-0.2.12.md`。
- 旧报告若基础类 ABI 已通过、未调用、却报 `message_manager_abi_incompatible`，解析器输出 `text_concrete_manager_details_required`；不能凭基础类签名推断实际服务的差异。新证据对应固定代码 `text_service_identity_blocked`、`text_service_resolution_failed`、`text_concrete_add_abi_blocked`、`text_concrete_lookup_abi_blocked`、`text_named_concrete_abi_differ`，未知/私人字段不回显。
- 0.2.13 的 `serviceEvidenceSchema=2` 增加 `route`（direct_instance/forwarding_proxy/rejected）与固定 `forwarding` 契约结果。分类 3 若完整转发契约通过，不再当成必然错误实例；顶层 missing_method 仅表示没有直接声明，不能代替转发签名判断。转发字段、整数 ABI 匹配和真机步骤见 `DEVICE-CHECK-0.2.13.md`。解析器兼容格式 1/2，输出固定的 wrapper_details_required、forwarding_unverified、forwarding_validated 等 text_service 代码；验证通过不是调用或送达证明。
- `singleTextExperimentHistory` 是账号汇总，不是本轮源消息的逐条状态；旧 claimed 不能证明最近一次阻断消耗了新占位。保留旧占位，不因这次未调用而删除历史。

捕获前置码另有：11 账号不可读、12 草稿无效、13 未选母群、2 已有等待或预览。捕获拒绝码：10 未在等待、20 账号不匹配、21 母群不匹配、22 发送者未选、23 类型未选、24 消息结构/来源标记/载荷不符合约束、25 证据轮次与已绑定轮次冲突。错误码必须结合事件与模块看，不跨模块猜含义。

## 方向证据子格式 1 / 2

`receiveCandidate.sessionRejections` 是每次 arm 重置的有界脱敏计数，键只来自 `receive_*` 与 `outgoing_*` 两条固定路径及三种固定原因。它在读取任何消息 wrap 字段前记录，用于区分“参数不是字符串”“空字符串”和“其他字符串”；不会导出实际会话值、长度或类名，也不改变原有 `receive_wrong_session` / `outgoing_wrong_session` 拒绝行为。

`receiveCandidate.directionSamples` 最多 12 条，只采本次等待中会话参数等于母群的回调，记录 `path`（固定 receive/outgoing）、宿主原方法返回后的时间、`before` 与 `after`。限额同时限制额外字段读取，超限累计 `directionSamplesDropped`；原方法抛异常时没有 after 样本，已预留名额仍会消耗。每次重新等待清空，停止后可导出最后快照，不跨启动持久化；其余固定事件仍按原规则持久化。

每个 before/after 只有白名单数字/布尔字段：

- `wrapClassCode`：0 无对象，1 精确 CMessageWrap，2 子类，3 其他对象；不输出任意运行时类名。
- `fromState`、`toState`、`senderState`：0 无对象，1 无 getter，2 签名不兼容，3 读取失败或异常，4 nil，5 非字符串，6 空字符串，7 非空字符串。签名不兼容时不调用 getter。
- `fromIsAccount` / `toIsAccount` / `senderIsAccount`，`fromIsSource` / `toIsSource` / `senderIsSource`：与已核对账号或已选母群的精确相等结果。
- `fromIsGroup` / `toIsGroup` / `senderIsGroup`：是否带群 ID 后缀，仅为形态证据，不作为身份核验或放行条件。
- `fromEqualsTo`、`senderEqualsFrom`、`senderEqualsTo`：两个非空字符串的相等关系。
- `typeReadable`、`messageType`：类型 getter 的读取结果，读不到时数字为 0，不把该 0 当作已读消息类型。

子格式 1 的字符串读取状态基于对象提供的实例反射签名。0.2.5 实机样本中 from/to/sender 全为 2，不能把其余 false 标志当作真实 ID 不相等。

子格式 2 的 `stringReadStrategy = declared_runtime`：以上 from/to/senderState 改为基于实际类的真实方法编码校验与标准消息派发读取，门禁仍严格。新增 `fromInstanceSignatureState`、`toInstanceSignatureState`、`senderInstanceSignatureState` 只作为旧反射路径的诊断：0 无对象、1 响应查询不可用、2 无签名或对象返回/参数不兼容、3 异常、7 反射签名兼容。实例签名为 2 而读取状态为 7，说明声明读取成功，不代表来源/wxid/服务器 ID 的其他条件自动满足。

before/after 不同只证明这些分类/关系在原方法前后不同；相同不证明原始字符串相同。样本不读正文、消息 ID 或 getter 异常文本，不参与捕获放行，不采用调用前数据来绕过调用后检查。诊断自身失败不能阻断宿主原方法或原有观察分支。旧/未知方向子格式只提示补充证据，不能根据缺字段推测身份。

## 离线分析与后续维护

```powershell
python tools/diagnose_report.py "诊断文件.json"
```

脚本只解析已知格式的 JSON，输出证据和下一步建议；不执行报告内容、不联网，不回显未知的私人字段。未知格式直接提示不支持，不假装自动修复。消息没有被抓到仍需新报告才能定位，不能预先宣称已经修好。单群手动观察中的样本只转换为固定代码，不回显正文、账号、群 ID 或消息 ID。

维护约定：

1. 每个测试包写入插件版本、确切提交和 CI run，并保留 artifact 哈希、来源清单与真机清单；不复用旧包名称冒充新修复。
2. 新微信版本先核对签名和只读证据，再做用户明确发起的单条采集测试。未知签名停止，不通过“放宽群/wxid 过滤”来掩盖适配失败。
3. 固定事件名和原因码进入回归测试；改变报告字段语义时升级 schema，并同步离线解析器和文档。
4. 持续覆盖母群变更、来源重选、本人/他人、群及账号隔离、ID 为零/更新/冲突、取消重开、持久日志上限/脱敏、设置入口与导出失败。
5. 更新只改草稿和诊断，不改写已有计划/执行历史；真实发送仍需另外设计可靠回执和本人回环过滤。

成对来源时间报告（`--pair` / `--stop-pair`）还会校验两份脱敏报告的证据连续性：构建版本、完整提交和 CI run 必须一致；两份运行日志必须各自包含同一当前进程会话的有序序列（历史 `previousLaunch` 行不作为会话证明）；`generatedAt` 必须是有限且小于 `2^53` 的数值，且后一份严格晚于前一份。缺失或不可信元数据输出固定的 `*_build_unverified`、`*_session_unverified` 或 `*_export_time_invalid`；不同构建/进程、倒序日志或倒序导出分别输出 `*_build_changed`、`*_session_changed`、`*_log_rewound` 或 `*_export_order_invalid`。这些门禁用于防止把不同启动或不同包的相同 `round` 拼成一轮，不回显会话值，也不改变单份报告的分析结果。

两份报告的顶层/探针 schema 必须为整数 1，不能用布尔值或浮点数代替；探针必须显式只读、关闭发送，且来源语义/图片就绪能力仍标为未验证，否则输出固定的 `*_invalid` 或 `*_scope_invalid`。`samples`/`hookSamples` 各最多 16 个固定格式对象，必须按连续 ordinal 排列，样本 round 与所属探针一致、generation 与停止前活动 receiver 一致，且两份报告中的全部样本共享同一 listening boundary。非对象、超限、字段非法或身份/边界冲突统一输出 `*_samples_invalid`，不能通过忽略坏行得到“一致”结论。手动停止会推进 receiver generation，但保留样本仍归原 generation，不要求篡改样本去匹配停止后的值。

单份和成对分析共用样本字段校验；超大整数、NaN/Infinity、容器型枚举和未知类型只产生固定诊断码，不回显原始值或因类型转换异常退出。空数组至多支持无样本快照之间的局部一致性，不证明发生了页面切换，更不证明时间 ABI/单位/语义或图片资源就绪。`102428` 的空采样结论仍是证据不足，不要求重新导出。

当前尚需真机验证分享面板、文件保护、日志跨重启、微信实际回调与原生设置视觉。模拟测试和编译通过不能替代这些验收。

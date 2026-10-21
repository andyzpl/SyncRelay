# 运行诊断与维护流程

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

| 证据 | 可确定的情况 | 后续动作 |
| --- | --- | --- |
| `capture_arm_failed.errorCode = 14` | 缺少来源成员 | 更换母群后重新勾选本人或指定成员并保存 |
| `capture_arm_failed.errorCode = 15` | 没有非空目标规则 | 先自动分组或选择目标；新母群占满唯一规则时该空规则会移除 |
| `capture_blocked.reasonCode = 1` | 草稿未保存 | 保存后再等待 |
| `capture_blocked.reasonCode = 2` | 没有启用文字，当前不支持纯图片采集 | 启用文字后重试 |
| 等待中，但 `receive_callback` 和 `outgoing_callback` 都为 0 | 本次尚未观察到两个候选入口 | 核对前台状态、复现动作及该版本 hook；不能断定是 wxid 错误 |
| `receive_wrong_session` / `receive_wrong_direction` | 部分回调没通过会话/方向检查 | 对照具体版本核对接口语义；可能只是其他群的正常消息，不直接放宽过滤 |
| `receive_invalid_sender` | 部分回调没有符合约束的发送者 | 核对 getter 和群消息字段，不改成按昵称猜测 |
| `receive_no_server_id` / `own_timeout` | 消息尚无可用服务器 ID或本人候选超时 | 核对发送后 ID 更新/精确回读；不改用临时本地 ID 冒充 |
| `sourceCapture.lastReasonCode = 22` | 规范化候选被所选 wxid 列表拒绝 | 核对选择的来源成员，不能按昵称替代 |
| `sourceCapture.lastReasonCode = 23` | 规范化候选类型不在选中类型中 | 核对类型开关 |
| `inactive` 出现在等待开始之后 | 应用曾失活，等待按设计停止 | 保持前台并手动重新等待 |
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

`singleTextSendCandidate` 记录下一轮设备核对用的 `MMContext → CMessageMgr → CMessageWrap` 候选能力。生产初始化不自动注入发送操作；面板里的实验开关也不持久化，关闭面板或重新打开后默认关闭。候选即使读到非零服务器 ID，也只表示主机关联，不能直接解释为目标群已送达。`singleTextSendExperimentEnabled` 仅表示当前面板会话是否明确开启该开关。

捕获前置码另有：11 账号不可读、12 草稿无效、13 未选母群、2 已有等待或预览。捕获拒绝码：10 未在等待、20 账号不匹配、21 母群不匹配、22 发送者未选、23 类型未选、24 消息结构/来源标记/载荷不符合约束。错误码必须结合事件与模块看，不跨模块猜含义。

## 方向证据子格式 1 / 2

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

当前尚需真机验证分享面板、文件保护、日志跨重启、微信实际回调与原生设置视觉。模拟测试和编译通过不能替代这些验收。

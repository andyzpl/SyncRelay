# 阶段 A 下一次设备核验：`.5` 当前源码检查点

日期：2026-10-24。当前节点：**`0.2.30+aprobe.5` 已绑定精确提交 `b0e567c` / 树 `acf7317`，[run 39990147883](https://github.com/andyzpl/SyncRelay/actions/runs/39990147883) 成功，普通 DEB SHA-256 `e9c774d1903cd926c37700f5c88d70c3c4217b07b9999737204fe2cd71f637c6`；尚未安装、迁移或取得真机证据。** `.4` 绑定提交 `03abb9b` / 树 `b99c855`，run `39986009254` 成功，DEB SHA-256 `9a45171f...ba29af`，但没有 `resumedAfterInactive` 字段，不能用它完成切页恢复判定。设备已确认的证据仍为 `.2` 的八轮只读采样；本机无 USB/SSH，微信临时目录最新报告仍是 2026-10-23 20:54 的 `.2` `10231`。`.4`/`.5` 是否已安装、是否发生 schema 迁移均未验证；完整来源时间语义和图片就绪仍未验收。** `.3` 身份见 `BUILD-0.2.28-aprobe.3.md`，`.4` 身份见 `BUILD-0.2.29-aprobe.4.md`，`.5` 身份见 `BUILD-0.2.30-aprobe.5.md`。与旧文字专项包步骤冲突时，以本文为准；产品范围仍服从总计划第 12–14 节。

### 新增设备报告（1023007–1023010，2026-10-23）

用户随后提供的八份报告均确认同一候选身份：iOS 16.0.3、微信 8.0.79.35、插件 `0.2.27+aprobe.2`、commit `51803d43fe068d16c462cea0729264a26cf5f2f5`、CI `39920510733`，`storageReady=1`，发送开关为 0，图片读取为 0。它们是设备证据，不是附带文档中的操作指令。

- `1023007`：第 1 轮导出时仍为 `state=sampling`、`active=true`，样本为 0，`sourceCapture=idle`。这证明该时刻采样没有因关闭设置入口而结束；但没有成对的“切页前/切页后”快照，不能单独把它写成完整页面切换通过。
- `1023008`：第 2 轮本人文字。3 个 `receive` hook 与 3 个交付样本均为 `selfSource=true`、`serverIDPresent=1`、`correlationScope=server`、`actualGetterEncoding=I`；`createdAt` 分别为 `1792755238/5252/5255`，均晚于 `listeningSince=1792755224.550`，`relationship=after_boundary`、`strictPolicyWouldAccept=1`。停止后样本保留，`state=stopped`、`active=false`。记为“本人实时文字 + 实际 getter 的有限通过”，不等于本人来源时间语义认证。
- `1023009`：第 3 轮他人文字。3 个 `receive` hook 与 3 个交付样本均为 `selfSource=false`、有 server ID、`correlationScope=server`、getter `I`；`createdAt` 为 `1792755309/5312/5316`，均晚于 `listeningSince=1792755283.131`，同样为 `after_boundary`/严格策略接受。停止后保留完整样本，记为“他人实时文字 + 实际 getter 的有限通过”。
- `1023010`：第 4 轮切后台/失去前台后导出，`state=inactive`、`active=false`、样本为空、`sourceCapture=idle`。符合后台停止边界；没有晚到样本，不能额外证明所有延迟回调情形。

### 离线旧消息报告（1023011，2026-10-23）

第 5 轮提供了目前最关键的离线边界证据：报告仍处于 `state=sampling`、`active=true`，但同一轮同时收到了旧消息和恢复网络后的新消息。两条都是他人文字、`messageType=1`、`serverIDPresent=1`、`correlationScope=server`、实际 getter `I`。

- 旧消息：`createdAt=1792758538`，`listeningSince=1792758550.518990`，`receivedAt=1792758562.363700`，关系为 `older_than_boundary`，`strictPolicyWouldAccept=0`。
- 新消息：`createdAt=1792758571`，`listeningSince=1792758550.518990`，`receivedAt=1792758572.807129`，关系为 `after_boundary`，`strictPolicyWouldAccept=1`。

这证明在本轮实际宿主回调中，旧消息的创建时间早于采样边界，严格策略没有把它误当成新消息；新消息则被接受。该报告本身仍是 `sampling` 中间快照，不能证明第 5 轮停止后的保留。后续 `1023012` 是**新的第 6 轮**：`round=6`、`receiverGeneration=18`、`state=stopped`、`active=false`，其自身的两条样本和 hook 均保留；但它的 `listeningSince` 与样本时间均不同于第 5 轮，不能充当第 5 轮的最终快照。因此离线旧/新边界已有两轮有限观察，**同一轮“停止后保留”仍未取得成对证据**。这不等于完整来源时间语义认证，也不覆盖离线图片或本人延迟补 ID。

八份报告均保持 `sourceTimeSemanticsVerified=false`、`imageReadinessObserved=false`。1023008/1023009 的分析器同时报告历史运行日志中的 `receive_wrong_session` 和字符串反射恢复提示；这些没有阻止当前轮的 hook 样本产生，但方向/身份 ABI 仍不应标为认证。报告中的持久发送 reservation 属于历史状态，不是本轮发送，不能重试或据此判断送达。

### 图片早期元数据报告（1023013，2026-10-23）

第 7 轮在保存“文字 + 图片”来源条件后观察到 1 条图片 hook：`messageType=3`、`selfSource=true`、`path=receive`、`serverIDPresent=1`、`correlationScope=server`、`actualGetterEncoding=I`。`createdAt=1792759538` 晚于 `listeningSince=1792759522.872659`，`receivedAt=1792759538.460884`。停止后报告为 `state=stopped`、`active=false`，hook 样本保留。

本轮 `imageSource.reads=0`、`imageReads=0`、`sourceCapture=idle`、发送关闭，说明只观察到了图片早期回调元数据，没有主动调用图片 getter、下载、快照或发送。该项记为**图片早期 hook/实际 getter 有限通过**；`imageReadinessObserved=false` 继续保持，不能据此宣称图片已准备、可预览或可派发。

### 本人文字后续报告（10231，2026-10-23）

第 8 轮最终状态为 `state=stopped`、`active=false`，保留 1 条本人文字样本和 1 条 hook。样本为 `selfSource=true`、`path=receive`、`messageType=1`、`serverIDPresent=1`、`correlationScope=server`、getter `I`；`createdAt=1792759996` 晚于 `listeningSince=1792759986.069733`，严格策略接受。

这轮确认了本人文字的正常 server-ID 回调路径，但没有出现 `serverIDPresent=0` 的早期 hook，也没有可验证的同一消息“无 ID → 有 ID”转换。因此**本人延迟补 ID 仍是证据不足**，不能把这轮写成延迟语义通过。发送仍关闭，`manualSendObservation.armed=false`、`observedOutgoing=0`，图片读取为 0。

## 1. 接手核对与阶段门槛

### 首份设备诊断（2026-10-23）

此前 `.1` 安装阶段导出的历史基线确认 iOS 16.0.3、微信 8.0.79.35、插件 `0.2.27+aprobe.1`，源码 `45c468418e0874bdece0dd39d2c52205d7521de6`、CI `39815504152`，`storageReady=1`、账号可读，设置入口为 `row_present` 且无警告。保存的来源配置包含文字和两名来源成员；这只证明当时包已加载、入口可用，不证明来源时间语义。当前设备身份以新增的 `.2` 报告为准。

本次报告是安装后的**未采样基线**：`sourceTimeProbe.state=off`、`round=0`、`samples=[]`、`hookSamples=[]`，`actualWrapABIObserved=false`、`prefilteredCallbacksObserved=false`。因此没有文字/图片回调、创建时间单位或离线边界证据；`sourceTimeSemanticsVerified=false`、`imageReadinessObserved=false` 保持正确。当前报告中的发送实验均未启动，图片读取为 0。

诊断分析还显示账号级文字/图片实验历史存在持久 reservation；这不是本轮采样结果，必须保留且不得重试或据此判断送达。运行日志的当前启动窗口只有 boot/inactive，其他事件属于有界历史日志，不能归因于本轮。下一步不需要重新安装：直接按第 3 节先完成一轮“他人实时文字与实际 ABI”，停止后立即导出；若没有样本记为证据不足，不把空报告判为兼容失败。

### 第二份设备诊断：首轮实际文字样本（2026-10-23）

新报告确认第 3 轮采样已经收到真实文字回调，但**导出时仍处于采样中**，所以它是中间证据，不是最终停止快照：`round=3`、`state=sampling`、`active=true`、`receiverCandidate.armed=true`。

- 他人文字：1 条 `type=1`、`path=receive`、`selfSource=false`，有 server ID，`correlationScope=server`；`actualGetterEncoding=I`。`createdAt=09:42:05`，`receivedAt=09:42:06.813`，监听从 `09:41:53.245` 开始，关系为 `after_boundary`，`strictPolicyWouldAccept=1`。这对“实时他人文字 + 当前对象 getter 声明/读取”是**初步通过**，时间单位/顺序在该样本上自洽。
- 本人文字：同一轮同时看到了 `receive`（local ID、无 server ID）和 `outgoing`（无 ID、`correlationScope=none`），两者 `actualGetterEncoding=I`，创建时间均为 `09:42:32`。这证明早期回调和无 server ID 情况可被观察，但尚未证明随后会补齐 server ID，不能把两条回调合并为同一条服务器消息。
- 分析器另外标记了 `declared_string_read_recovered`：方向证据中的实例反射元数据不兼容，但运行时已验证的字符串 getter 仍成功读取。它不否定上述数字创建时间样本，却说明方向/身份 ABI 仍不能认证；`missing_server_id` 对应本人回调的预期边界，不是他人实时样本缺陷。
- 安全边界：发送开关为 0，发送实验未启动，`sourceCapture=idle`，`imageReads=0`、`imageSource.reads=0`，没有图片/资源准备或库任务证据。日志中较早的捕获事件属于同一微信启动期间的历史操作，不归因于本轮采样。

**下一步只做一件事：**不要再发送消息，直接在设置页停止来源时间采样，然后立即重新导出诊断。停止后的报告若保留上述样本，即可把“他人实时文字/实际 getter”记为本轮通过；若停止后样本被清空或状态异常，记为入口/生命周期失败并停止后续测试。本人延迟关联、离线旧消息、图片和后台项暂不重复，等停止快照核对后再决定。

### 停止快照结果（102304，2026-10-23）

停止后的报告保留了第 3 轮的 3 个 hook 样本和 2 个交付文字样本，`state=stopped`、`active=false`，receiver `armed=false`；没有新发送或图片读取。由此关闭本轮入口生命周期门槛，并将“他人实时文字 + 实际 getter 观察”记为**有限通过**：外部文字样本有 server ID，`actualGetterEncoding=I`，创建时间在监听边界之后且 `strictPolicyWouldAccept=1`。这不是全部来源时间语义认证；`sourceTimeSemanticsVerified=false` 继续保持。

本人消息只取得同轮 `receive`（local ID）与 `outgoing`（无 ID）早期回调，尚无 server ID 延迟补齐证据；本人延迟关联、离线旧消息、自然重复、后台/到限和图片资源就绪仍未覆盖。停止后没有再发消息，因此“停止后无晚到回调”也尚未单独验证。

### 后续报告 1023004：不是来源时间采样（证据不足）

该报告保留了上一轮已停止的 `sourceTimeProbe`（`round=3`、`active=false`），没有新增 hook 或文字样本。报告生成时却显示 `sourceCapture.state=waiting`、`receiveCandidate.armed=true`、`ownTextState=waiting`，并出现新的 `receiverGeneration=27`；当前启动日志只有 `capture_attempt → receiver_arm → capture_started`，没有 receive/outgoing 回调。

因此这不是离线旧文字的来源时间证据，也不是 ABI 失败；诊断器的 `no_callback_observed` 仅说明手动捕获已 arm 但尚未收到候选。发送仍关闭，图片读取仍为 0。**请先在“源消息与计划”里点“取消等待”，再导出一份诊断确认 `sourceCapture.state=idle`、`receiveCandidate.armed=false`。** 在此之前不要继续发送、不要开始下一轮采样，也不要把该报告用于离线判定。

### 清理确认 1023005（2026-10-23）

后续报告确认手动等待已取消：`sourceCapture.state=idle`、`receiveCandidate.armed=false`，日志只出现一次新的 arm/stop，期间没有 receive/outgoing 回调。来源时间采样仍是已停止的第 3 轮，未新增任何样本；发送与图片读取继续为 0。安全状态已恢复，可以在不混用手动捕获入口的前提下进行下一项离线测试。

### 页面切换缺陷与本地修复（2026-10-23）

用户反馈安装包在切换微信页面后停止采样。源码核对确认原因：`UIApplicationWillResignActiveNotification` 本身已不直接停止只读采样，但 `tick` 期间的 `environmentAllowed` 仍依赖设置面板对象和页面 idle 状态；页面切换的短暂 inactive/面板替换会返回 `environment_blocked`，从而停止采样。当前本地工作区已修复为：采样 active 后不再读取设置面板状态，允许 foreground inactive 过渡，只在真正后台、账号/配置失效或互斥业务状态停止；发送/执行的既有 inactive 安全路径不开放采样期间的派发。已补充 Python 源码契约守卫，验证 active 分支不依赖面板和后台通知仍为停止边界。

该修复已在 `0.2.27+aprobe.2` 候选中完成 CI 原生/生产双架构构建、普通 DEB 核验并安装到设备；八份报告显示采样可持续、可停止，后台仍会停止。页面切换没有成对前后导出，故只记为有限支持证据，不标完整通过。schema、数据库迁移、receiver hook 和采样字段没有改变。

`.2` 安装后报告暴露的生命周期边界仍成立：`WillResignActive` 不能直接等于后台停止，否则微信内切页或短暂系统过渡会错误结束采样；真正后台必须立即停止。当前本地实现采用 2 秒单调时钟宽限，`DidBecomeActive` 也会在清除 pending 前重新核对是否超时，避免“计时器被挂起后回前台又继续采样”的漏洞。该逻辑目前只有 Python 源码契约和 Objective-C 测试源码，没有本机原生执行证据。

- 接手时 HEAD 为 `f652d5e97180a15f43437fd1e449f3b3063e87fc`，真实暂存区为空。34 文件白名单按 Git 过滤后的 blob 与 `90ed08af6b2687056358642aef1c66aa1a02c162` 全部一致，树为 `ba9b583c91fead76f8294916b010007cf4dfc636`。没有重跑相同快照的 CI，也没有重新审计已关闭的底座缺陷。
- 已有证据：A-1/A-2/A-3 的隔离快照编译、链接、71 次程序模拟执行及迁移/事务测试，详见原生验收文档。不是整个当前工作区、微信宿主或真机的验收。
- 已有入口待真机：可交付的离线旧文字、自然同秒、配置失效、本人延迟补 ID、图片离线旧图及页面切换/到限生命周期。实时本人/他人文字、实际 getter、图片早期元数据、停止保存和后台停止已有本轮有限结果；图片资源就绪没有安全被动入口。
- 本次补足入口：同一 hook 的选定来源文字/图片早期元数据、无服务器 ID 的回调、实际对象创建时间 getter 声明。`.2` 精确提交 `51803d43fe068d16c462cea0729264a26cf5f2f5` 已在 macOS CI 编译/链接并完成生产双架构构建；不是实际宿主对象/语义或触控验收。
- 仍缺入口：图片实际资源就绪及其与首次消息身份的可靠关联。`getMsgHdOrMiddleImg:` 是现有手动捕获的主动 getter；声明兼容和 `nativeDownloadEnabled=false` 不能证明调用没有宿主副作用。2026-10-23 再次只读检索本地研究材料，仍只确认该主动 getter；`m_uiImgStatus`、`m_uiDownloadStatus`、`readyTransmitMediaIDs`、`downLoadImg:WithBlock:` 等名称没有可靠的实际对象 ABI、调用语义或被动通知证据。没有把调用、轮询、下载或制作快照塞入只读采样，也不猜 selector。需要可靠的被动就绪通知/只读状态 ABI 证据，否则保持 `imageReadinessObserved=false` 并继续阻塞完整 A。
- A 的剩余阻塞是当前支持微信版本的完整时间单位/语义、本人延迟补 ID、实际对象 ABI 的完整覆盖以及图片资源就绪。离线旧/新文字边界已有两轮有限观察，但同一轮停止保留仍未证明，不等于全部离线同步语义认证。新增观察代码的独立编译/模拟门槛已通过；来源认证继续为 false。C 的目标级群来源账本、排除、新群和备份实现不属于 A 已完成项；A 已固定其事务契约。B/C 不因准备文档或一次采样而开放。

## 2. 本地新增观察能力的精确边界

复用 `SRSourceTimeProbe`、唯一 receiver、原 receive/outgoing hook、SREntry timer 和原诊断导出。不安装第二个 hook/listener，不创建新的探针服务。

- 保留 `samples`：原有最终交付文字，最多 16 条；保留首次时间至本人服务器 ID 等待结束。仍然需要有 ID 和可用文字才交付。普通手动捕获路径不被替换。
- 新增 `hookSamples`：在调用原宿主方法前读取固定元数据，原方法正常返回后才排队交付；仅限已保存母群、选定成员、正确方向的 type 1/3。位于服务器 ID、正文和图片准备过滤之前。类型 49 的原结构探针在本采样期间不运行，其他类型不是本轮内容。
- 每次 arm 最多预留 16 个 hook 样本，**排队前限额**，不是只限制最终数组。它与 16 个文字交付样本是两个有界数组；hook 达限后不再补样，文字达到 16 条或单调时间达到 120 秒结束整轮。只发图时到 120 秒停止，或手动提前停止。拒绝的来源不消耗该配额。
- hook 额外读取方向、类型、server/local ID 是否存在及实际对象的 getter 声明；不读取正文/XML、媒体路径或媒体 getter。原文字规范化链仍可能在内存读取文字，不能把整条 receiver 写成“绝不读取正文”。
- 原 ID 只用于本轮内存关联，不导出；没有 ID 则 `messageOrdinal=null`。local 与 server 不猜测合并，同轮重复服务器 ID 才可关联；`samples` 与 `hookSamples` 的匿名序号各自独立，不能按相同序号跨数组拼接。本人 local-ID 仅在精确 `GetMsg:LocalID:` 回读且账号/群/类型/正文与时间证据复核通过后，才映射到早期 hook 的匿名 ordinal；无该完整条件时 `hookMessageOrdinal=null`。原方法抛异常则不交付该 hook 样本，不吞掉宿主异常。
- 明确开始后才装入补充观察回调，停止前清除。receiver 代次、轮次和账号/配置重新核对拒绝晚到数据，包括账号 getter 同步重开且墙钟边界相同的情况。停止/后台保留脱敏报告待导出；账号/配置失效清空两个数组，不能跨账号展示。
- 不创建持久内容、计划、run、delivery 或 claim，不发送，不自动开启捕获，不主动下载/准备图片。插件初始化、配置保存、既有运行恢复及诊断导出仍可能写数据库/日志，不能称整个插件“完全只读”。

### 导出字段

每轮都保存一次完整的本地诊断用于工程核对；对外只分享脱敏字段，不上传私有诊断到公开仓库。

公共字段集 P：`iOS`、`wechatVersion`、`wechatBuild`、`build.plugin/commit/ciRun`、`storageReady`、`schemaVersion`；`sourceTimeProbe` 下 `state/round/active/sampleLimit/durationLimit/hookSampleLimit/hookScope/inactivePending/inactiveGraceLimit/resumedAfterInactive`、配置类 `getterDeclaredReturnEncoding/getterDeclarationScope`、三个未认证能力位及两个实际观测位。附本轮操作顺序、手动输入时间与已知间隔，不附正文、wxid 或群名。`schemaVersion` 是 `SRStore` 构造及迁移事务完成、外键复核后读回的当前版本；存储不可用或初始化失败时为 `null`，不是迁移前版本、旧行保留或迁移原子性证明。已核对的 `.2` 报告均不含该字段；`.4` 含 `schemaVersion` 和 inactive 宽限字段但不含 `resumedAfterInactive`；`.5` 才含切页恢复字段，不能用旧报告代替 `.5` 基线。

文字字段集 T：`samples[].ordinal/messageOrdinal/hookMessageOrdinal/round/receiverGeneration/selfSource/createdAt/receivedAt/listeningSince/deliveredAt/deliveryClockRollback/relationship/strictPolicyWouldAccept`。`hookMessageOrdinal` 只在本次进程内 exact local ID 已与早期 hook 关联时出现，否则为 null；它不包含原始 local/server ID。

hook 字段集 H：`hookSamples[].ordinal/messageOrdinal/round/receiverGeneration/messageType/selfSource/path/serverIDPresent/correlationScope/actualGetterEncoding/createdAt/receivedAt/listeningSince`。`actualGetterEncoding` 为实际对象声明的整数编码，或 `missing/incompatible`；不导出实际类名。创建时间仍是整数原值，不替宿主换算单位。

安全字段集 S：`receiveCandidate.armed/receiverGeneration/imageReads/imagePending/imageState`、`imageSource.reads`、`sourceCapture.state`、发送实验/倒计时/观察布尔与 `smallGroupExecution` 的执行状态。本轮前后各导出一次，对照是否出现新活动；单凭这些字段不等于对数据库逐行无写入作出证明。

`actualWrapABIObserved` 和 `prefilteredCallbacksObserved` 仅在至少有一个 H 样本时为 true，表示观察发生，**不表示 ABI 全部兼容或语义通过**。`hookScope` 明确只覆盖选定来源的文字/图片，不是所有原始事件流。`sourceTimeSemanticsVerified`、`imageReadinessObserved`、`sendingEnabled` 始终为 false。`textOnly=false` 指包含图片元数据，`deliveredTextOnly=true` 指文字交付数组。`resumedAfterInactive` 只在本轮至少一次前台 inactive 宽限内恢复后为 true，表示观察到短暂 inactive 后仍在前台；它不是系统后台证据，也不证明宿主页面切换完成或完整生命周期通过。没有该字段的 `.2`/`.4` 报告不能据此判切页恢复。

## 3. 下一次设备测试清单

已确认的设备报告来自 `.2`，共八份且包身份匹配。`.3` 的已核验包绑定构建提交 `6bd977d`，但没有安装。`.4` 在精确提交 `03abb9b` 上通过 CI、双架构生产构建和普通 DEB 静态核验，但没有可核验的安装证据；`.5` 在精确提交 `b0e567c` 上通过同样门槛，但尚未安装。不能用 `.2`/`.3` 的结果冒充 `.4`/`.5`，也不能把 CI 结果或口头安装陈述冒充真机。用户报告“已经安装”后，临时目录未出现 2026-10-24 之后的诊断，最新仍是 `.2` 的 `10231`，因此下一步先从微信内导出当前实际加载版本的首份基线；若为 `.5`，按 3.1 门禁判。尚未取得数据库迁移过程证据，不能把 `storageReady=1` 写成迁移验收。不要安装旧 timeprobe 包或为采样取消旧任务；后续覆盖安装、RootHide 转换或再次迁移仍需单独授权。新候选首次导出必须确认 `storageReady=1` 且 `schemaVersion=14`；存储不可用时 `schemaVersion` 应为 `null`，但报告仍只表示未验证；存储可用而字段缺失、为 `null`、非整数或不是 14 时，停止该项并保留脱敏报告，不据此改库或降级。

统一准备：没有活动捕获/预览、发送或在途动作时，保存授权母群、本人及一位测试成员、文字类型；关闭发送实验和手动发送观察。图片元数据在二次确认中明确授权，不要求开启原“等待源消息”。先导出基线 P+S。入口为“更多设置 → 来源时间只读采样（文字/图片元数据）”。每行单独开始、停止、导出，**先导出再开下一轮**；一轮少于 16 个 hook，避免配额耗尽造成假阴性。

### 3.1 首份 `.5` 基线门禁（先只做这一份）

入口：我 → 设置 → SyncRelay 转发 → 更多设置 → **导出运行诊断**。不要在导出前开始采样、手动等待、预览或发送。

| 检查 | 通过标准 | 不通过时 |
| --- | --- | --- |
| 包身份 | `build.plugin=0.2.30+aprobe.5`、`build.commit=b0e567c2f6c9c43e1356f0c14f339f5d673b4d34`、`build.ciRun=39990147883` | 说明当前加载的不是 `.5` 或不是该次构建；停止，不继续按 `.5` 判据测试 |
| 存储 | `storageReady=1`、`schemaVersion=14` | 缺字段/`null`/非整数/非 14：停止并保全报告，不改库、不降级；存储不可用时只记录 `schemaVersion=null`，不能当作迁移通过 |
| 发送安全 | `sendingEnabled=false`、`batchSendingEnabled=false`、`build.defaultSendingEnabled=false`、`build.batchSendingEnabled=false` | 任一项不是 false：停止后续采样，先排查是否有活动实验或发送 |
| 捕获/采样 | `sourceCapture.state=idle`、`receiveCandidate.armed=false`、`sourceTimeProbe.state=off`、`sourceTimeProbe.active=false` | 先按对应入口取消/停止，再重新导出；不能把未停止状态当基线 |
| 媒体边界 | `imageSource.reads=0`、`receiveCandidate.imageReads=0`、`sourceTimeProbe.imageReadinessObserved=false` | 读取变化或能力位被写成 true：判安全失败，停止后续批次并保全报告 |
| 身份/字段 | `iOS`、`wechatVersion`、`wechatBuild` 可读；`sourceTimeProbe.schema=1`；`inactivePending=false`、`inactiveGraceLimit=2` 可见（off 状态也应导出） | 字段缺失或类型错误：只记证据不足，不推测兼容；先保留报告 |

通过后才进入下面各批次。每一批都要先导出原始脱敏 JSON，再执行对应分析命令；未通过的门槛不得用后续样本补齐。基线失败时不要开始任何采样。

批次与取证规则（`.5` 获得安装授权并安装后执行；不要与旧 `.2`/`.3`/`.4` 报告混算）：

- 先做“基线门禁”批次：确认包身份、`storageReady=1`、`schemaVersion=14`、账号可读、发送关闭、图片读取 0、手动捕获 idle。失败立即停止，不进入采样。
- 再做“页面切换”批次：**导出本身会打开系统分享面板，属于系统级 inactive；不要在切页前导出 A。** 开始采样后先在微信内完成页面切换，并在 2 秒内返回稳定前台，再只导出一份 B。该轮必须满足 `active=true/state=sampling`、`inactivePending=false`、`resumedAfterInactive=true`、receiver 仍 armed，且 `runtimeLog` 中没有本轮新增的 `receiver_stopped` 或 `environment_blocked`。该字段只证明本轮前台恢复且采样未停，不证明宿主页面切换完成；当前分析器没有切页前内存快照，`--pair` 只能用于外部已有合法 A/B 的回归，不能把单份 B 冒充完整成对证据。本批次结论记为“切页后短暂 inactive 恢复且未停采样”的有限通过。
- 再做“离线/停止”批次：同一轮 active A、明确手动停止 B，使用 `py -3 tools/diagnose_report.py --stop-pair A B`；离线旧/新消息必须都在同一轮，不能用不同 round 拼接。A 的导出会打开系统分享面板；A 若在导出后已经变为 `inactive`，不能用 `--stop-pair` 冒充“手动停止后保留”，该轮只记生命周期中断。分享面板关闭后**不要**靠快速重开采样补 A/B；B 必须来自同一 round 的真实手动停止。
- 再做“本人 local-ID”批次：单独一轮，只测试本人合成文字；保留 `hookMessageOrdinal`、`messageOrdinal`、round、generation、时间关系及安全字段。没有 early local hook 时记“不足”，不制造第二条消息或轮询。
- 图片只做“早期元数据”批次：不点图、不请求原图、不启动手动捕获、不准备/下载媒体；`imageReads` 变化或 `imageReadinessObserved=true` 即停止并判安全失败。资源就绪仍未覆盖，不能用缩略图人工可见替代。
- 每个批次导出后先保留原始脱敏 JSON，再用对应分析命令；输出通过码与失败码一起保存。任何 `database_schema_invalid`、样本丢失/变化、receiver 未按预期 arm/disarm、图片读取变化或发送开启都停止后续批次。
- 所有样本上限、120 秒时长、16 个 hook 预留和停止/重开清空规则不变；不要为了凑样本延长一轮或把不同 round 的数组拼在一起。
- 诊断导出会包含插件运行状态与脱敏采样字段；对外只提供 P/T/H/S 所需字段和操作记录，不粘贴正文、wxid、群名、原始 local/server ID 或完整日志。若报告出现这些私有值，停止并保留本地原件，不把它上传公开仓库。

| 项目 | 操作顺序 | 导出字段 | 通过/失败/不足标准 |
| --- | --- | --- | --- |
| 1 他人实时文字与实际 ABI | 开始 → 关面板 → 等至少 2 秒 → 选定成员手动发 2–3 条合成文字，记录例如 3 秒/5 秒间隔 → 停止导出 | P+T+H+S | 实际 getter 编码兼容，创建值增量与已知间隔/单位一致，`receivedAt` 保留原方法前时间；假设秒单位时创建时间晚于边界、不晚于首次回调。缺字段/样本不足为不足；时间指向错误、单位矛盾为失败。不单凭位数认定 epoch 秒。同一来源组内只算一次有限通过，不把 8.0.76/8.0.79 或不同账号的样本混算 |
| 2 本人早期与后续回调 | 新轮 → 等 2 秒 → 本人手动发合成文字 → 停止导出；观察自然出现 early hook，不额外制造或轮询 | P+T+H+S，重点 `path/serverIDPresent/correlationScope/hookMessageOrdinal` | 若出现无 server ID 的 H，应保留早期原值；最终 T 不得用 ID 就绪时刻代替首次观察。通过需同一 round/generation、本人 type 1、早期 H 为 `correlationScope=local` 且 getter 可读、T 为 `after_boundary` 且严格策略接受，并且 T 的 `hookMessageOrdinal` 与该 H 的 `messageOrdinal` 相同；分析器应给出 `source_time_self_local_id_readback_correlated`，不得同时给出 `source_time_self_local_id_correlation_incomplete`。当前设备上的 `.2` 不导出 `hookMessageOrdinal`；`.4`/`.5` 已包含该字段但尚未安装。旧报告只能记“证据不足/关联入口不足” |
| 3 他人离线旧文字 | 路由器/另一设备断测试机网络，微信保持前台 → 他人在断网期间发合成文字，记时 → 等至少 2 秒后开始采样 → 外部恢复网络 → 等待旧/新回调 → **不要先在采样中导出 A**，直接在设置页手动停止并导出 B。仅当 A 来自外部已有合法同轮快照时才用 `--stop-pair A B`；当前设备流程不把导出分享面板当作 A | P+T+H+S、断网/发消息/开始/恢复/手动停止的顺序 | 旧消息 `older_than_boundary` 且严格策略拒绝，新消息 `after_boundary` 且严格策略接受，且 B 的 `state=stopped/active=false` 保留同轮样本。没有合法 A 时只记“离线边界 + 停止后保留”，不冒充完整 A/B；`--stop-pair` 的 A 必须 active/armed 且不在 inactive 宽限，B 必须同 round、disarmed、generation 前移、样本前缀保留。`1023011`（第 5 轮）与 `1023012`（第 6 轮）不能配对。 |
| 4 图片首次时间与离线旧图 | 他人与本人各一轮；实时图为开始后等 2 秒再发；旧图按第 3 项在开始前发送，再恢复网络；不点图、不请求原图、不启动捕获 | P+H+S，重点 type 3、原时间、实际 ABI、`imageReads` | **实时图片早期 hook 已有限通过（1023013，`.2`）**：type 3、实际 getter、server ID 与边界可观察，且无图片读取。离线旧图、资源就绪/可预览/可派发仍未覆盖；`.4`/`.5` 尚未取得同项证据，不能用旧结果冒充。 |
| 5 自然重复与历史重现 | 若微信在自然历史同步中重复回调，同一轮保留两次；不靠插件发送或制造伪消息 | P+T+H+S | 同轮同 server 关联可比创建值；晚到不应刷新创建时间。无重复、只有 local/server 两种不同 scope、配额已满都记不足；不是持久去重验收 |
| 6 停止/后台/到限 | 新轮 → 手动停止 → 再发输入；另开一轮 → 在微信前台于设置、聊天列表、来源群之间切换页面，在 2 秒内返回稳定前台，再导出 B（切页前不导出）；再另开一轮打开控制中心或 App Switcher 并停留超过 2 秒，返回后导出；另开空闲轮等待 120 秒 | P+T+H+S，停止前后轮次及数组长度；手动停止用 `--stop-pair A B` | 手动停止后无新样本且 receiver 已停；**仅微信内切页/短暂 inactive 后应仍 `active=true/state=sampling`、`inactivePending=false`、`resumedAfterInactive=true`、receiver armed，且本轮没有新增 receiver stop/environment_blocked**。单份 B 只能证明短暂 inactive 后恢复且未停止，不能代替切页前后成对快照；当前分析器没有切页前内存快照入口，不得用 `--pair` 把单份报告冒充 A/B。系统 inactive 超过 2 秒或真正后台后 `active=false/state=inactive`、`resumedAfterInactive=false`、receiver `armed=false`，回前台不重开；空闲到 `time_limit`。再次明确开始才换轮。旧事件不得重标新轮；无晚事件则晚回调项不足。`.2`/`.4` 没有该字段，不能冒充 `.5`。 |
| 7 配置失效 | 先导出需要保留的样本 → 保存不同测试来源配置 → 导出；账号测试仅在确有安全条件时另做 | P+S、两个数组长度 | 停止且旧报告清空，不展示旧账号样本；保存新配置不发起发送。不得为完成此项强迫切实际账号或丢失重要任务 |
| 8 图片资源就绪 | 本轮不执行主动 getter/轮询/下载/快照；若宿主自然显示缩略图，只记录人工观察，不当成插件素材就绪证据 | 保持 `imageReadinessObserved=false` | **未覆盖，仍阻塞完整 A 验收**。有被动 ABI 证据前不能将该项填通过 |

任何一项出现探针引起的新预览、内容、计划或发送、资源读取增加、敏感字段泄露，立即停止并保留脱敏报告，判安全门槛失败。时钟回拨、异常未来时间等不改手机系统时间去制造，继续引用模拟测试，不填写真机通过。8.0.76 与 8.0.79 按实测版本分别记账。

证据结果最小格式（每行一个场景）：设备 iOS/微信/构建；场景号；round；输入与操作顺序及时间；T/H 序号与 correlationScope；时间关系；安全字段前后差异；`通过/失败/证据不足/未覆盖`；原因。没有采到就写不足，不把“没有出错”当通过。

## 4. 源码、现有包与 schema 兼容边界

- 当前 `SRStore` 支持并迁移至 schema 14，拒绝更高版本；主工作区 `Core/SRVersion.h`/`control` 仍是 `0.2.21`，而 `.5` 隔离候选为 `0.2.30+aprobe.5`。插件版本号与数据库 schema 不是同一编号体系。`.5` 探针没有改 schema、迁移 SQL、素材账本或发送核心。
- `.2` 报告的 `storageReady=1` 只表示 `SRStore` 构造成功；`.2` 不导出 `schemaVersion`，也没有迁移前版本。`.4` 新增的是构造及迁移事务完成、外键复核后读回的当前 `schemaVersion`，仍不导出迁移前版本。启动流程还会调用 `recoverInterruptedRuns`，它会把遗留的 `submitting` 收尾为 `uncertain`、把 `running/paused` 转为 `awaiting_resume`，因此不能把“安装后能打开诊断”写成“数据库只读、未发生状态写入”。`.4` 首次报告只能证明当前版本与恢复路径，不能证明迁移前的库版本、迁移原子性、旧行逐项保留或回滚行为。
- 本地旧 `0.2.21+timeprobe.1` 的 DEB SHA-256 重新只读核对为 `34dfdb48d37e29af85da75c015e5dac3a0145f3431826be6a4387aacbbf7416c`，与旧记录一致；它的源码 schema 为 11，不能打开当前 schema 14 库。它不是这次候选包。
- 本地 0.2.24/25/26 构建请求所指提交分别为 `75dd2ec716f15b58a30421ebabf6429d0d834f57`、`ca2b6d20b8c69e507467d63c1b4656b6642130ba`、`05fc85743ea4eb3bd315cd65fd69bd5962748534`；用本地 Git 对象只读核对，其迁移目标均为 11。没有据此宣称手机安装的就是这些精确包，也没有宣称功能集合相同或已验证升级。
- 新候选若打开 schema 11 设备库，会执行现有 11→14 增量迁移和触发器刷新。该动作属于**另需明确授权的数据迁移**；本轮未对任何设备库运行。schema 14 开发库也会运行现有初始化/约束刷新事务；不称零写入。未知或 >14 的设备库不安装、不降 user_version、不清数据。
- 本地已实现只暴露 `SRStore` 构造、迁移事务及外键复核完成后读回的只读 `schemaVersion`；构造失败时对象不发布，诊断为 `null`。该字段明确是“当前版本”，不是迁移前版本、迁移成功证明或旧行保留证明。`.3` 已编译、打包并完成普通 DEB 静态核验，但尚未真机验证，不能复用 `.2` 的报告冒充；`.4` 在 `.3` 之上修改只读采样生命周期和测试；`.5` 再增加只读 `resumedAfterInactive`。两者 schema 仍为 14。安装与设备库迁移仍需另行授权。
- 迁移后不能通过安装旧 schema 11 包回退。先有不上传的本地数据库/自有素材保全方案，重要暂停任务和原 claims 必须保留。备份不等于授权恢复旧库；回滚不得遗失备份之后新增的发送记录。RootHide 需要转换时另列动作，不自动转换或安装普通 DEB。

`.3` 候选范围已按精确提交 `6bd977de878af89d19bb09885721ed10c20751be`、树 `d24b83f285e3c27e2394487780f3aecd5160e4fc` 构建和核验；普通 DEB 证据见 `BUILD-0.2.28-aprobe.3.md`。`tests/store_test.m` 已包含在该提交中。该结果只证明 CI 编译/链接/模拟执行和 DEB 静态核验，不是真机、宿主 ABI 或迁移证据。

`.4` 的范围以 `a6d48dbb94ebb8d44ada62a70a57906046c50efa` 为基线，只覆盖生命周期、诊断、测试、版本和文档；没有新增迁移 SQL，没有修改消息库派发、视频、receiver 发送 ABI 或 B/C UI。前三次 CI 都在编译/执行来源时间程序时失败：第一次是新增 lifecycle 测试的错误期望，第二次是更早的既有异步等待超时，第三次是等待 block 返回 `int` 与声明的 `BOOL` 不兼容，程序尚未执行。测试等待已改为最多 5 秒的有界条件轮询并显式返回 `BOOL`；第四次精确提交 `03abb9b` 的 CI 已通过 181 项 Python、全部 Objective-C 编译/链接/三轮模拟执行和双架构生产构建，DEB 下载静态核验通过。仍无安装、设备库迁移或真机结果。安装 `.4` 若面对 schema 11 设备库，会执行既有 11→14 迁移；没有备份/回滚方案和单独授权不得安装。

`.5` 的范围以 `03abb9b` 为基线，只覆盖只读 `resumedAfterInactive`、诊断/分析器、测试、版本和文档。精确提交 `b0e567c` / 树 `acf7317` 的 [run 39990147883](https://github.com/andyzpl/SyncRelay/actions/runs/39990147883) 已通过 181 项 Python、全部 Objective-C 编译/链接/三轮模拟执行、双架构生产构建和普通 DEB 静态核验。DEB SHA-256 为 `e9c774d1903cd926c37700f5c88d70c3c4217b07b9999737204fe2cd71f637c6`。仍无安装、设备库迁移或真机结果；安装 `.5` 面对 schema 11 设备库仍会执行既有 11→14 迁移。

## 5. 外部动作范围

2026-10-23 执行更新：本节记录 `.2` 的历史授权范围；`.3` 已完成隔离提交、单次 CI、DEB 下载核验，实际结果见 `BUILD-0.2.28-aprobe.3.md`。`.4` 已按原计划执行一次非 `main` 分支 CI/DEB 核验；`.5` 也已按批准范围完成隔离提交、单次 CI 和 DEB 静态核验。上述授权均不包括安装、RootHide 转换或设备数据迁移。以下 `.2` 清单仅保留历史，不要求重复 CI。

已完成候选：`0.2.27+aprobe.2`（高于本地已知 0.2.26，**不是该包全部功能的超集承诺**）。精确提交、run、包摘要见 `BUILD-0.2.27-aprobe.2.md`；`.3` 精确证据见 `BUILD-0.2.28-aprobe.3.md`。本节仅保留 `.2` 历史，不要求重复构建。

精确源码组合：以 `f652d5e...` 为基线，覆盖 A-3 已核对的 34 文件白名单，再覆盖以下 8 文件当前工作区字节，共 **42 个工程文件**：

```text
Adapter/SRWeChatReceiver.h
Adapter/SRWeChatReceiver.m
UI/SRPanel.m
tests/receive_test.m
tests/app_message_probe_cases.h
tests/app_message_contract_test.py
tests/source_time_probe_contract_test.py
tools/diagnose_report.py
```

34 文件来源为 `.build-cache/operations-native-tests/a3-native/whitelist.txt`；本轮实际修改了其中 probe 的 h/m 与其原生测试，不能再把它们称为与成功快照相同。其余 31 个仍应一致。包含现有 appmsg 结构探针及测试是为了真实验证当前 receiver 的组合，不增加消息类型功能。

文档另含本文件、总计划、状态设计、v2 契约、来源时间设备步骤和旧 timeprobe 构建记录，共 6 个当前文档；隔离候选再按行调整 `Core/SRVersion.h`、`control` 与已有工作流产物 notice。排除 `.workbuddy`、私人诊断、第三方包、整个 `.build-cache` 和 `dist`。本地只读 manifest 在 `.build-cache/takeover-20261023/candidate-manifest.json` 固定路径、原始摘要和 Git 过滤后 blob；授权执行时先核对，不包含授权后的未知变更。

本次已执行的授权范围：

1. 隔离候选提交并推送 `codex/operations-a-device-probe-20261023-aprobe2`，未改主 HEAD/真实 index。
2. 对新增组合执行一次 CI；工作流完成 160 项 Python、原生测试/模拟及 arm64/arm64e 普通 DEB 构建。
3. 下载后核对提交/run、两架构、control/载荷/过滤、SHA-256 与无安装脚本；结果见 `BUILD-0.2.27-aprobe.2.md`。授权**不包括安装、RootHide 转换、设备库迁移或清理数据**。

上述提交、推送、单次 CI 与条件构建、下载核验均已执行。Windows 本机没有可用 clang/libclang 与现有 syntax 脚本所需 SDK cache；实际 ObjC 编译/链接/模拟执行由本次 macOS CI 完成，生产双架构编译/链接由固定 Theos/SDK 完成，没有把 Python 或文本守卫当编译证据。

## 6. 本轮自审与执行证据

本地改动：receiver 额外只读 hook seam、原采样器有界报告/代次保护、原设置入口准确说明、原测试补充以及本次计划/兼容文档。没有修改已通过的库模型、配额或发送核心；没有开展 B、视频或其他类型。

Python 160 项通过，含新增的只读 seam 源码守卫；SQLite/其他 Python 模拟执行与源码文本断言仍按原测试性质解释。新增 Objective-C 用例覆盖实际类不同于配置类、缺失/不兼容 getter 不调用、图片及无 ID/空正文元数据、原方法前冻结、16 次排队预留、停止重开、账号 getter 重入及隐私；**这些用例已在 CI 的 probe 程序中实际编译、链接并三轮模拟执行通过**。`.2` 单次 CI/打包和下载核验通过；设备已取得本人/他人文字与后台停止的有限真机证据，但未证明数据库迁移、完整来源时间语义或图片就绪。

后续顺序：核对手机当前身份与保全方案，另获安装/迁移授权，再按本清单取得设备证据；图片被动就绪仍是单列技术缺口，不绕过 A 门槛进入 B。无需把这些结果搬回旧窗口审核，由当前负责人继续核对证据和维护计划。

2026-10-23 后续自审补充：本地 probe 配置已恢复为 receiver 文字-only。此前试验性写入 `@[@"text", @"image"]` 会让图片类型进入原有交付分支并可能调用 `prepareImage`，违反“不为了观察图片而下载或准备媒体”的边界；type 3 早期 hook 位于类型过滤之前，因此文字-only 仍能观察图片元数据。源码守卫已同步要求精确 `@[@"text"]`。

诊断器新增 `--stop-pair ACTIVE STOPPED`，与页面切换 `--pair BEFORE AFTER` 分开：前者要求前快照 active/sampling 且 receiver 明确 `armed=true`、后快照同一合法 round 且 `state=stopped`、receiver 明确 `armed=false`、generation 为合法整数并已前移，同时核对两个样本数组逐项保留及 capture/图片读取/发送安全字段；后台、环境阻塞、receiver 停止、到限、样本上限、配置/账号失效、时钟或上下文异常均单独判 `source_time_stop_pair_after_not_manual_stop`，不能冒充手动停止保留。后者要求两个快照都 active/sampling、round 和 receiver generation 均为合法整数且保持不变、两边 receiver 都明确 `armed=true`，并核对样本逐项保留、capture idle、图片读取不变、发送关闭。缺少或类型错误的 round/armed/generation、generation 变化（`--pair`）或未前移（`--stop-pair`）均判失败。用现有 `1023007`/`1023011` 实跑会拒绝为不同 round 和 generation，`1023011`/`1023012` 会拒绝为不同 round；`102303`/`102304` 旧同轮对可识别为停止后保留，仅用于分析器回归，不能冒充本轮 `.2` 的新离线证据。

2026-10-23 后续本地补充：在既有 receiver 的精确 `GetMsg:LocalID:` 回读成功且原消息账号/群/类型/正文仍匹配、时间证据复核通过后，才把 exact local ID 放入本轮进程内关联表；probe 用它把早期匿名 hook ordinal 写入交付文字样本的 `hookMessageOrdinal`。原始 ID 不进入诊断，停止/重开即清空。没有早期 hook、ID 不匹配、跨群/账号/类型/正文变化或 hook 已移除时不得关联。分析器只在同一 round/generation、本人 type 1、早期 hook 为 local scope 且 getter 可读、交付为 after-boundary/严格接受时判关联；带 ordinal 但不完整则明确报 `source_time_self_local_id_correlation_incomplete`。同轮 pair 比较现覆盖交付时间、严格策略、hook ordinal 等全部已导出样本字段。相关 Objective-C 用例已补但尚未实际编译/运行。

本轮本地回归：在本人 local-ID 关联检查点之后补充只读 `schemaVersion`，随后加入 foreground-inactive 2 秒宽限与 `--stop-pair` pending 门禁，并补上 BOOL 返回类型守卫。2026-10-24 主工作区执行 `py -3 -m unittest discover -s tests -p '*_test.py'` 为 **181 项 OK**；`py -3 -m unittest tests.source_time_probe_contract_test -v` 为 **11 项 OK**；`tests.diagnose_report_test` 为 **44 项 OK**；指定 5 个 Python 文件 `py_compile` 通过；`git diff --check` 通过，仅有既有 CRLF/LF 提示。新增源码守卫要求 native `main()` 在边界与能力用例之间调用 `checkInactiveGrace()`，并要求 4 个有界等待 block 显式返回 `BOOL`。两份来源时间测试的 Git blob 与 `.4` 提交 `03abb9b` 一致：`tests/source_time_probe_test.m` 为 `4be1cda5e117ad2b3b39a385b28b92073bf74649`，`tests/source_time_probe_contract_test.py` 为 `3db9283f122417386ff8aa36996c0bb9fb15a102`。用真实历史报告复核：`1023011` 单独分析正常；`1023011`/`1023012` 被 `--pair` 拒绝为不同 round/generation；旧同轮 `102303`/`102304` 仍可识别停止保留，仅作分析器回归，不是 `.2` 新证据。`.3` 单次 CI `39971512703` 已在该精确提交上完成 179 项 Python、Objective-C 编译/链接/模拟执行及双架构普通 DEB 构建；下载核验通过，未安装、未迁移、未 RootHide 转换。但 `.3` 的 native `main()` 未调用 lifecycle 用例，因此该用例的编译只能证明源码可编译，不能证明已执行。当前 181 项和 lifecycle 增量不是 `.3` 包证据；`.4` 的 181 项、原生模拟和 DEB 证据绑定 `03abb9b`。`.5` 在 `.4` 上增加 `resumedAfterInactive` 后，精确提交 `b0e567c` 的 [run 39990147883](https://github.com/andyzpl/SyncRelay/actions/runs/39990147883) 已重新完成 181 项 Python、Objective-C 编译/链接/三轮模拟执行、双架构生产构建和普通 DEB 静态核验；仍无安装、迁移或真机证据。本轮没有修改生产数据库 schema、发送核心、消息库派发、视频或 UI 功能。

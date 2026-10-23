# 阶段 A 下一次设备核验：当前源码检查点

日期：2026-10-23。当前节点：**`0.2.27+aprobe.1` 精确候选已通过单次 CI 的 160 项 Python、71 次原生模拟执行及双架构普通 DEB 构建，下载后核验通过；用户已安装并导出未采样基线，未证明设备库迁移，尚无真机来源时间结果。** 身份及摘要见 `BUILD-0.2.27-aprobe.1.md`。与旧文字专项包步骤冲突时，以本文为准；产品范围仍服从总计划第 12–14 节。

## 1. 接手核对与阶段门槛

### 首份设备诊断（2026-10-23）

用户已安装并导出一份当前设备诊断。报告确认 iOS 16.0.3、微信 8.0.79.35、插件 `0.2.27+aprobe.1`，源码 `45c468418e0874bdece0dd39d2c52205d7521de6`、CI `39815504152`，`storageReady=1`、账号可读，设置入口为 `row_present` 且无警告。保存的来源配置包含文字和两名来源成员；这只证明当前包已加载、入口可用，不证明来源时间语义。

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

该修复**尚未编译、打包或重新安装到设备**。现有 `0.2.27+aprobe.1` 仍不能用于页面切换后的采样验收；需要单独的 `0.2.27+aprobe.2` 候选通过原生 CI 后再测。schema、数据库迁移、receiver hook 和采样字段没有改变。

- 接手时 HEAD 为 `f652d5e97180a15f43437fd1e449f3b3063e87fc`，真实暂存区为空。34 文件白名单按 Git 过滤后的 blob 与 `90ed08af6b2687056358642aef1c66aa1a02c162` 全部一致，树为 `ba9b583c91fead76f8294916b010007cf4dfc636`。没有重跑相同快照的 CI，也没有重新审计已关闭的底座缺陷。
- 已有证据：A-1/A-2/A-3 的隔离快照编译、链接、71 次程序模拟执行及迁移/事务测试，详见原生验收文档。不是整个当前工作区、微信宿主或真机的验收。
- 已有入口待真机：文字交付时间、实时本人/他人、可交付的离线旧文字、自然同秒、停止/后台/配置失效。它们此前全部没有本轮真机结果。
- 本次补足入口：同一 hook 的选定来源文字/图片早期元数据、无服务器 ID 的回调、实际对象创建时间 getter 声明。精确提交 `45c468418e0874bdece0dd39d2c52205d7521de6` 已在 macOS 编译/链接并三轮模拟执行通过，包含新用例；生产含 UI 已双架构构建。不是实际宿主对象/语义或触控验收。
- 仍缺入口：图片实际资源就绪及其与首次消息身份的可靠关联。`getMsgHdOrMiddleImg:` 是现有手动捕获的主动 getter；声明兼容和 `nativeDownloadEnabled=false` 不能证明调用没有宿主副作用。没有把调用它、轮询它或制作快照塞入只读采样。需要可靠的被动就绪通知/只读状态 ABI 证据，否则先报告边界，不能猜通知名、下载、准备或写素材。
- A 的剩余阻塞是当前支持微信版本的真实时间单位/语义、离线补同步、实际对象 ABI 以及图片/本人延迟证据。新增观察代码的独立编译/模拟门槛已通过；来源认证继续为 false。C 的目标级群来源账本、排除、新群和备份实现不属于 A 已完成项；A 已固定其事务契约。B/C 不因准备文档或一次采样而开放。

## 2. 本地新增观察能力的精确边界

复用 `SRSourceTimeProbe`、唯一 receiver、原 receive/outgoing hook、SREntry timer 和原诊断导出。不安装第二个 hook/listener，不创建新的探针服务。

- 保留 `samples`：原有最终交付文字，最多 16 条；保留首次时间至本人服务器 ID 等待结束。仍然需要有 ID 和可用文字才交付。普通手动捕获路径不被替换。
- 新增 `hookSamples`：在调用原宿主方法前读取固定元数据，原方法正常返回后才排队交付；仅限已保存母群、选定成员、正确方向的 type 1/3。位于服务器 ID、正文和图片准备过滤之前。类型 49 的原结构探针在本采样期间不运行，其他类型不是本轮内容。
- 每次 arm 最多预留 16 个 hook 样本，**排队前限额**，不是只限制最终数组。它与 16 个文字交付样本是两个有界数组；hook 达限后不再补样，文字达到 16 条或单调时间达到 120 秒结束整轮。只发图时到 120 秒停止，或手动提前停止。拒绝的来源不消耗该配额。
- hook 额外读取方向、类型、server/local ID 是否存在及实际对象的 getter 声明；不读取正文/XML、媒体路径或媒体 getter。原文字规范化链仍可能在内存读取文字，不能把整条 receiver 写成“绝不读取正文”。
- 原 ID 只用于本轮内存关联，不导出；没有 ID 则 `messageOrdinal=null`。local 与 server 不猜测合并，同轮重复服务器 ID 才可关联；`samples` 与 `hookSamples` 的匿名序号各自独立，不能按相同序号跨数组拼接。原方法抛异常则不交付该 hook 样本，不吞掉宿主异常。
- 明确开始后才装入补充观察回调，停止前清除。receiver 代次、轮次和账号/配置重新核对拒绝晚到数据，包括账号 getter 同步重开且墙钟边界相同的情况。停止/后台保留脱敏报告待导出；账号/配置失效清空两个数组，不能跨账号展示。
- 不创建持久内容、计划、run、delivery 或 claim，不发送，不自动开启捕获，不主动下载/准备图片。插件初始化、配置保存、既有运行恢复及诊断导出仍可能写数据库/日志，不能称整个插件“完全只读”。

### 导出字段

每轮都保存一次完整的本地诊断用于工程核对；对外只分享脱敏字段，不上传私有诊断到公开仓库。

公共字段集 P：`iOS`、`wechatVersion`、`wechatBuild`、`build.plugin/commit/ciRun`、`storageReady`；`sourceTimeProbe` 下 `state/round/active/sampleLimit/durationLimit/hookSampleLimit/hookScope`、配置类 `getterDeclaredReturnEncoding/getterDeclarationScope`、三个未认证能力位及两个实际观测位。附本轮操作顺序、手动输入时间与已知间隔，不附正文、wxid 或群名。

文字字段集 T：`samples[].ordinal/messageOrdinal/round/receiverGeneration/selfSource/createdAt/receivedAt/listeningSince/deliveredAt/deliveryClockRollback/relationship/strictPolicyWouldAccept`。

hook 字段集 H：`hookSamples[].ordinal/messageOrdinal/round/receiverGeneration/messageType/selfSource/path/serverIDPresent/correlationScope/actualGetterEncoding/createdAt/receivedAt/listeningSince`。`actualGetterEncoding` 为实际对象声明的整数编码，或 `missing/incompatible`；不导出实际类名。创建时间仍是整数原值，不替宿主换算单位。

安全字段集 S：`receiveCandidate.armed/receiverGeneration/imageReads/imagePending/imageState`、`imageSource.reads`、`sourceCapture.state`、发送实验/倒计时/观察布尔与 `smallGroupExecution` 的执行状态。本轮前后各导出一次，对照是否出现新活动；单凭这些字段不等于对数据库逐行无写入作出证明。

`actualWrapABIObserved` 和 `prefilteredCallbacksObserved` 仅在至少有一个 H 样本时为 true，表示观察发生，**不表示 ABI 全部兼容或语义通过**。`hookScope` 明确只覆盖选定来源的文字/图片，不是所有原始事件流。`sourceTimeSemanticsVerified`、`imageReadinessObserved`、`sendingEnabled` 始终为 false。`textOnly=false` 指包含图片元数据，`deliveredTextOnly=true` 指文字交付数组。

## 3. 下一次设备测试清单

当前普通 DEB 已核验，且用户已安装并导出首份基线；本轮没有执行或证明数据迁移。以下后续覆盖安装、RootHide 转换或 schema 11→14 迁移仍需另获明确授权。首份报告已核对手机插件版本/构建、实际微信版本、入口和 `storageReady=true`；继续测试前确认没有需要保全的暂停任务，不要安装旧 timeprobe 包或为采样取消旧任务。若后续重新安装，必须核对新包 `0.2.27+aprobe.1`、提交 `45c468418e08...`、run `39815504152` 三者匹配；不符则停止。

统一准备：没有活动捕获/预览、发送或在途动作时，保存授权母群、本人及一位测试成员、文字类型；关闭发送实验和手动发送观察。图片元数据在二次确认中明确授权，不要求开启原“等待源消息”。先导出基线 P+S。入口为“更多设置 → 来源时间只读采样（文字/图片元数据）”。每行单独开始、停止、导出，**先导出再开下一轮**；一轮少于 16 个 hook，避免配额耗尽造成假阴性。

| 项目 | 操作顺序 | 导出字段 | 通过/失败/不足标准 |
| --- | --- | --- | --- |
| 1 他人实时文字与实际 ABI | 开始 → 关面板 → 等至少 2 秒 → 选定成员手动发 2–3 条合成文字，记录例如 3 秒/5 秒间隔 → 停止导出 | P+T+H+S | 实际 getter 编码兼容，创建值增量与已知间隔/单位一致，`receivedAt` 保留原方法前时间；假设秒单位时创建时间晚于边界、不晚于首次回调。缺字段/样本不足为不足；时间指向错误、单位矛盾为失败。不单凭位数认定 epoch 秒 |
| 2 本人早期与后续回调 | 新轮 → 等 2 秒 → 本人手动发合成文字 → 等自然后续回调 → 停止导出 | P+T+H+S，重点 `path/serverIDPresent/correlationScope` | 若出现无 server ID 的 H，应保留早期原值；最终 T 不得用 ID 就绪时刻代替首次观察。local/server 不可直接关联，缺可靠对应则延迟项不足；不得把多个不相关回调拼成通过 |
| 3 他人离线旧文字 | 路由器/另一设备断测试机网络，微信保持前台 → 他人在断网期间发合成文字，记时 → 等至少 2 秒后开始采样 → 外部恢复网络 → 停止导出 | P+T+H+S、断网/发消息/开始/恢复的顺序 | 旧消息创建值早于监听边界，回调可晚到；T 的严格策略应拒绝。若值被改成同步时间、误接受旧消息则失败。无回调/账号不可读/采样停止均不足，不是通过 |
| 4 图片首次时间与离线旧图 | 他人与本人各一轮；实时图为开始后等 2 秒再发；旧图按第 3 项在开始前发送，再恢复网络；不点图、不请求原图、不启动捕获 | P+H+S，重点 type 3、原时间、实际 ABI、`imageReads` | 有 H 可核对图片首次时间和旧图边界；`imageReads/imageSource.reads` 不应因本探针增加，不出现预览/计划/发送。缺 H 为不足。**这不是资源就绪/可预览/可派发验收** |
| 5 自然重复与历史重现 | 若微信在自然历史同步中重复回调，同一轮保留两次；不靠插件发送或制造伪消息 | P+T+H+S | 同轮同 server 关联可比创建值；晚到不应刷新创建时间。无重复、只有 local/server 两种不同 scope、配额已满都记不足；不是持久去重验收 |
| 6 停止/后台/到限 | 新轮 → 手动停止 → 再发输入；另开一轮 → 在微信前台于设置、聊天列表、来源群之间切换页面并返回；再另开一轮切后台后回来；另开空闲轮等待 120 秒 | P+T+H+S，停止前后轮次及数组长度；页面切换前后各记一次 `active/state` | 手动停止后无新样本；**仅微信内切页/短暂 inactive 不得停采样，`active` 保持 true 且无 `environment_blocked`**；真正后台后 `active=false`，回前台不重开；空闲到 `time_limit`。再次明确开始才换轮。旧事件不得重标新轮；无晚事件则晚回调项不足。此项必须使用修复后的 `0.2.27+aprobe.2`，当前已装 `.1` 只能记录已知缺陷，不能判修复通过。 |
| 7 配置失效 | 先导出需要保留的样本 → 保存不同测试来源配置 → 导出；账号测试仅在确有安全条件时另做 | P+S、两个数组长度 | 停止且旧报告清空，不展示旧账号样本；保存新配置不发起发送。不得为完成此项强迫切实际账号或丢失重要任务 |
| 8 图片资源就绪 | 本轮不执行主动 getter/轮询/下载/快照；若宿主自然显示缩略图，只记录人工观察，不当成插件素材就绪证据 | 保持 `imageReadinessObserved=false` | **未覆盖，仍阻塞完整 A 验收**。有被动 ABI 证据前不能将该项填通过 |

任何一项出现探针引起的新预览、内容、计划或发送、资源读取增加、敏感字段泄露，立即停止并保留脱敏报告，判安全门槛失败。时钟回拨、异常未来时间等不改手机系统时间去制造，继续引用模拟测试，不填写真机通过。8.0.76 与 8.0.79 按实测版本分别记账。

证据结果最小格式（每行一个场景）：设备 iOS/微信/构建；场景号；round；输入与操作顺序及时间；T/H 序号与 correlationScope；时间关系；安全字段前后差异；`通过/失败/证据不足/未覆盖`；原因。没有采到就写不足，不把“没有出错”当通过。

## 4. 源码、现有包与 schema 兼容边界

- 当前 `SRStore` 支持并迁移至 schema 14，拒绝更高版本；插件版本文件仍是 `0.2.21`，二者不是同一版本。新探针没有改 schema、迁移 SQL、素材账本或发送核心。
- 本地旧 `0.2.21+timeprobe.1` 的 DEB SHA-256 重新只读核对为 `34dfdb48d37e29af85da75c015e5dac3a0145f3431826be6a4387aacbbf7416c`，与旧记录一致；它的源码 schema 为 11，不能打开当前 schema 14 库。它不是这次候选包。
- 本地 0.2.24/25/26 构建请求所指提交分别为 `75dd2ec716f15b58a30421ebabf6429d0d834f57`、`ca2b6d20b8c69e507467d63c1b4656b6642130ba`、`05fc85743ea4eb3bd315cd65fd69bd5962748534`；用本地 Git 对象只读核对，其迁移目标均为 11。没有据此宣称手机安装的就是这些精确包，也没有宣称功能集合相同或已验证升级。
- 新候选若打开 schema 11 设备库，会执行现有 11→14 增量迁移和触发器刷新。该动作属于**另需明确授权的数据迁移**；本轮未对任何设备库运行。schema 14 开发库也会运行现有初始化/约束刷新事务；不称零写入。未知或 >14 的设备库不安装、不降 user_version、不清数据。
- 迁移后不能通过安装旧 schema 11 包回退。先有不上传的本地数据库/自有素材保全方案，重要暂停任务和原 claims 必须保留。备份不等于授权恢复旧库；回滚不得遗失备份之后新增的发送记录。RootHide 需要转换时另列动作，不自动转换或安装普通 DEB。

## 5. 待批准的外部动作范围

2026-10-23 执行更新：本节是当时的申请范围，用户“继续开工”后已按此执行完成，实际结果见构建记录；没有把该授权扩展为安装、RootHide 转换或设备数据迁移。以下清单用于复算已构建快照，不再表示尚待构建，也不要求重复 CI。

建议版本：`0.2.27+aprobe.1`（高于本地已知 0.2.26，**不是该包全部功能的超集承诺**）。只命名于隔离候选，不改主工作区版本；提交/tree/run/包摘要在实际生成后填写，不提前编造。

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

建议集中授权顺序：

1. 在隔离快照提交上述范围，保持主 HEAD/真实 index/现有文件不动；推到明确的公开分支 `codex/operations-a-device-probe-20261023`。公开上传的是源码/测试/上述文档，不是用户诊断、素材或设备数据。
2. 对**新增且未原生验证的组合**执行现有 Python、原生编译/链接和三轮模拟测试；可用现有语法检查时检查双架构。不得沿用 A-3 成功结果冒充 receiver/UI 已编译。若批准同一轮 `build_deb=true`，工作流必须先测试成功才构建一次 arm64/arm64e 普通 DEB并上传产物，避免完全相同源码先测试 CI 再打包 CI 重复跑。失败只修实质缺陷，范围外变化重新报告。
3. 下载后核对提交/tree、两架构内嵌版本/commit/run、control/载荷/过滤、SHA-256 与无安装脚本，交付本次候选身份。此授权**不包括安装、RootHide 转换、设备库迁移或清理数据**。

上述提交、推送、单次 CI 与条件构建、下载核验均已执行。Windows 本机没有可用 clang/libclang 与现有 syntax 脚本所需 SDK cache；实际 ObjC 编译/链接/模拟执行由本次 macOS CI 完成，生产双架构编译/链接由固定 Theos/SDK 完成，没有把 Python 或文本守卫当编译证据。

## 6. 本轮自审与执行证据

本地改动：receiver 额外只读 hook seam、原采样器有界报告/代次保护、原设置入口准确说明、原测试补充以及本次计划/兼容文档。没有修改已通过的库模型、配额或发送核心；没有开展 B、视频或其他类型。

Python 160 项通过，含新增的只读 seam 源码守卫；SQLite/其他 Python 模拟执行与源码文本断言仍按原测试性质解释。新增 Objective-C 用例覆盖实际类不同于配置类、缺失/不兼容 getter 不调用、图片及无 ID/空正文元数据、原方法前冻结、16 次排队预留、停止重开、账号 getter 重入及隐私；**这些用例已在 CI 的 probe 程序中实际编译、链接并三轮模拟执行通过**。单次 CI/打包和下载核验通过；当前包已安装但尚无采样结果，未证明设备库迁移，也未取得真机来源时间或图片就绪结果。

后续顺序：核对手机当前身份与保全方案，另获安装/迁移授权，再按本清单取得设备证据；图片被动就绪仍是单列技术缺口，不绕过 A 门槛进入 B。无需把这些结果搬回旧窗口审核，由当前负责人继续核对证据和维护计划。

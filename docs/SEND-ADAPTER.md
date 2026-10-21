# 单群文字发送适配器门禁

日期：2026-10-21。0.2.10 开放默认关闭的“单群、单条文字”实验；只有用户开启本次开关、选择一个规则内目标并二次确认，至少等待 10 秒后才允许一次主机调用。批量规则、图片和自动重试仍未接入。设备检查见 `DEVICE-CHECK-0.2.10.md`。

0.2.11 修正 888 设备报告证实的构造器宽度不匹配：微信 `initWithMsgType:` 为 `@24@0:8q16`，旧版仅允许 `i/I`，在发送前拒绝；该次没有调用或持久占位。现在严格按 runtime 中的 `i/I/q/Q` 选择各自的类型化 init 调用，保留 ARC 所有权，不以“放开所有整数”替代 ABI 匹配。浮点/对象/缺失签名仍阻断，新增匹配的四种构造模拟测试和不支持类型拒绝测试；最新步骤见 `DEVICE-CHECK-0.2.11.md`。当前仅证明修复了已识别的前置检查问题，不证明后续实际发送成功。

## 为什么先做门禁

`SRRunner` 已经负责单账号互斥、节拍、暂停/继续、重启后的未决状态和逐条规则顺序，但它不能替代微信私有发送适配。适配器必须先把账号、目标群、冻结源消息和宿主 ABI 锁定，再允许一次提交；没有可靠回执时只能写入 `uncertain`，不能自动补发。

## 当前契约

- 仅允许微信 `8.0.76` / `8.0.79`，并校验 `MMContext` 服务、`CMessageMgr AddMsg:MsgWrap:` / `GetMsg:LocalID:`、`CMessageWrap initWithMsgType:`、文字/整数 setter 及 getter 编码；未知类或签名直接阻断。运行时 ABI 一致不代表构造字段语义或真机兼容已经通过。
- `prepareForAccount:targetGroup:sourceSnapshot:confirmed:error:` 必须在主线程调用，`confirmed` 必须为真，源快照必须来自当前账号、母群且类型为 `text`；目标群必须是一个不同于母群的稳定 `@chatroom` ID。
- 源快照通过 JSON 冻结，提交时再次逐字比对；目标、状态或快照改变会进入 `uncertain`，不改用其他消息或群。
- 一个适配器实例只允许一次提交；重复提交明确返回 `uncertain`，不会自动重试。
- 每次准备/重置都会推进内部代次；旧提交的迟到回调会被丢弃，不能污染下一次测试的状态。
- 面板注入 `SRWeChatTextSendHost` 操作，但 `environmentAllowed` 仍要求本次显式实验开关和前台状态；开关不持久化，关闭面板、失活或结果返回后关闭。启动不发送，不创建 runner。
- 主机实例由入口持有，整个微信进程最多调用一次 `AddMsg`，重新打开面板不重置资格。SQLite schema v4 在调用前持久化 `(account, source_group, source_message_id)` 实验占位；崩溃、重启或未知结果均不允许同源再次实验。占位不等于已调用或送达。
- 0.2.12 将实际上下文/消息服务解析、真实实例归属和 AddMsg/GetMsg ABI 核对纳入 `readyForAccount:`，故 UI 在倒计时与持久占位之前即可阻断已知不兼容。提交时仍重新解析、构造后仍复验实际对象，不用基础类签名替代实际服务签名；使用验证得到的签名正常消息派发。服务在占位后变化仍保留占位、不自动重试。双阶段脱敏证据和测试见 `DEVICE-CHECK-0.2.12.md`。
- 0.2.13 对 MMContext 返回的非直接实例增加完整转发契约校验：真实 NSObject/NSProxy 继承、签名/转发实现重写、元数据 ABI、身份与响应，以及 AddMsg/GetMsg 转发签名逐参数匹配基础类。只有全部成立才按原代理派发，不解包服务或直调 IMP。每次回读也重新校验，使用验证得到的精确签名；任意变化停止观察且不重试。细节和字段见 `DEVICE-CHECK-0.2.13.md`，不能以声称身份或基础类 ABI 单独放行。
- 目标只能来自捕获时冻结的规则，排除母群及明确排除项；提交前重新核对当前群列表、账号、前台、源快照和当前设置。设置与旧预览不一致时要求重新捕获。
- 从 10 秒等待开始到最多 30 秒精确 ID 观察结束请求禁止自动锁屏；取消、面板关闭、账号改变、失活、门禁失败和观察结束均恢复此前值。不能阻止手动锁屏或系统挂起，回前台不自动续发。
- 模拟 operation 的回调只接受 `confirmed`（必须带消息 ID）或 `failed`；其他结果统一转为 `uncertain`。`confirmed` 只是 transport 提供的关联结果，仍需后续验证其真实含义。

## 文件与测试

- `Adapter/SRWeChatTextSendAdapter.h/.m`：单目标文本 transport 门禁与脱敏状态。
- `Adapter/SRWeChatTextSendHost.h/.m`：仅用于下一轮设备核对的 `MMContext → CMessageMgr → CMessageWrap` 文字构造候选；要求 `currentContext`、`getService:`、`initWithMsgType:`、文字 setter、`AddMsg:MsgWrap:` 和 `GetMsg:LocalID:` 的运行时编码一致。构造后只回读本地/服务器 ID；非零服务器 ID 仍只记为“主机关联”，不直接判定目标群送达。
- `tests/single_text_send_adapter_test.m`：二次确认、版本/ABI、源快照冻结、默认关闭、一次性提交和禁止重试。
- `tests/text_send_host_test.m`：模拟构造/字段写入、版本/账号/环境门禁、单次调用、延迟服务器 ID、有限回读、停止/失活/身份冲突/异常和仅一次完成回调；不调用真实微信。
- `tests/store_test.m`：验证调用前实验占位、重开后同源阻断、规则目标限制和活动批次互斥。
- `Core/SRRunner.m`：仍未接入该适配器，避免在手机验证前打开主动发送路径。

主机候选始终回调 `uncertain`，不会把 local/server ID 或状态数字转成真实送达成功。完成回调在有限观察结束后触发，不在刚调用 `AddMsg` 时提前结束常亮生命周期。构造字段、调用线程和目标群实际表现仍需一个授权测试群核对，不执行 100/200 群规则。

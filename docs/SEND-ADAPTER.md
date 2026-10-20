# 单群文字发送适配器门禁

日期：2026-10-21。当前实现只完成“单群、单条文字、明确二次确认”的适配器门禁和模拟测试；生产初始化不注入发送操作，因此仍不会主动发送消息。

## 为什么先做门禁

`SRRunner` 已经负责单账号互斥、节拍、暂停/继续、重启后的未决状态和逐条规则顺序，但它不能替代微信私有发送适配。适配器必须先把账号、目标群、冻结源消息和宿主 ABI 锁定，再允许一次提交；没有可靠回执时只能写入 `uncertain`，不能自动补发。

## 当前契约

- 仅允许微信 `8.0.76` / `8.0.79`，并校验 `CMessageMgr AddMsg:MsgWrap:` 为 `void(object, object)` 且 `CMessageWrap` 类存在；未知类或签名直接阻断。尚未假定任何未由设备证据确认的构造器或 setter ABI。
- `prepareForAccount:targetGroup:sourceSnapshot:confirmed:error:` 必须在主线程调用，`confirmed` 必须为真，源快照必须来自当前账号、母群且类型为 `text`；目标群必须是一个不同于母群的稳定 `@chatroom` ID。
- 源快照通过 JSON 冻结，提交时再次逐字比对；目标、状态或快照改变会进入 `uncertain`，不改用其他消息或群。
- 一个适配器实例只允许一次提交；重复提交明确返回 `uncertain`，不会自动重试。
- 生产初始化的 `operation` 为 `nil`，即使 ABI 通过，`canSendForAccount:` 仍返回假。测试只注入一个内存模拟 operation，不调用微信私有接口。
- 模拟 operation 的回调只接受 `confirmed`（必须带消息 ID）或 `failed`；其他结果统一转为 `uncertain`。`confirmed` 只是 transport 提供的关联结果，仍需后续验证其真实含义。

## 文件与测试

- `Adapter/SRWeChatTextSendAdapter.h/.m`：单目标文本 transport 门禁与脱敏状态。
- `tests/single_text_send_adapter_test.m`：二次确认、版本/ABI、源快照冻结、默认关闭、一次性提交和禁止重试。
- `Core/SRRunner.m`：仍未接入该适配器，避免在手机验证前打开主动发送路径。

CI 会把该模拟测试与现有核心测试一起运行。下一步需要在明确授权的一个测试群中单独验证构造字段、调用线程和可靠回执；在这三项没有证据前，不打 0.2.8 包，也不执行 100/200 群规则。

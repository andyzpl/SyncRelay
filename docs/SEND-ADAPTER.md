# 单群文字发送适配器门禁

日期：2026-10-21。当前实现已补充“单群、单条文字”的微信主机调用候选和 ABI 门禁，但生产初始化仍不注入发送操作，因此仍不会主动发送消息。

## 为什么先做门禁

`SRRunner` 已经负责单账号互斥、节拍、暂停/继续、重启后的未决状态和逐条规则顺序，但它不能替代微信私有发送适配。适配器必须先把账号、目标群、冻结源消息和宿主 ABI 锁定，再允许一次提交；没有可靠回执时只能写入 `uncertain`，不能自动补发。

## 当前契约

- 仅允许微信 `8.0.76` / `8.0.79`，并校验 `CMessageMgr AddMsg:MsgWrap:` 为 `void(object, object)`，以及 `CMessageWrap` 的已观察字符串/整数 getter 编码；未知类或签名直接阻断。尚未假定任何未由设备证据确认的构造器或 setter ABI。
- `prepareForAccount:targetGroup:sourceSnapshot:confirmed:error:` 必须在主线程调用，`confirmed` 必须为真，源快照必须来自当前账号、母群且类型为 `text`；目标群必须是一个不同于母群的稳定 `@chatroom` ID。
- 源快照通过 JSON 冻结，提交时再次逐字比对；目标、状态或快照改变会进入 `uncertain`，不改用其他消息或群。
- 一个适配器实例只允许一次提交；重复提交明确返回 `uncertain`，不会自动重试。
- 每次准备/重置都会推进内部代次；旧提交的迟到回调会被丢弃，不能污染下一次测试的状态。
- 生产初始化的 `operation` 为 `nil`，即使 ABI 通过，`canSendForAccount:` 仍返回假。测试只注入一个内存模拟 operation，不调用微信私有接口。
- 模拟 operation 的回调只接受 `confirmed`（必须带消息 ID）或 `failed`；其他结果统一转为 `uncertain`。`confirmed` 只是 transport 提供的关联结果，仍需后续验证其真实含义。

## 文件与测试

- `Adapter/SRWeChatTextSendAdapter.h/.m`：单目标文本 transport 门禁与脱敏状态。
- `Adapter/SRWeChatTextSendHost.h/.m`：仅用于下一轮设备核对的 `MMContext → CMessageMgr → CMessageWrap` 文字构造候选；要求 `currentContext`、`getService:`、`initWithMsgType:`、文字 setter、`AddMsg:MsgWrap:` 和 `GetMsg:LocalID:` 的运行时编码一致。构造后只回读本地/服务器 ID；非零服务器 ID 仍只记为“主机关联”，不直接判定目标群送达。
- `tests/single_text_send_adapter_test.m`：二次确认、版本/ABI、源快照冻结、默认关闭、一次性提交和禁止重试。
- `tests/text_send_host_test.m`：模拟 `CMessageWrap` 构造、字段写入、`AddMsg` 调用、精确本地 ID 读回和“关联不等于送达”的回调门禁。
- `Core/SRRunner.m`：仍未接入该适配器，避免在手机验证前打开主动发送路径。

CI 会把两个模拟测试与现有核心测试一起运行；当前 Windows 固定 SDK/libclang 检查已覆盖新增源码，arm64/arm64e 语法检查继续作为构建前门禁。主机候选尚未接入 `SRRunner` 或设置按钮；构造字段、调用线程和可靠回执仍需一个明确授权测试群单独核对，不执行 100/200 群规则。

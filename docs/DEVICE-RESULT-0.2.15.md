# 0.2.15 图片接口检查真机结果

日期：2026-10-21。依据：用户提供的 1103 诊断。仅保留脱敏事实，不将原始 JSON、账号/群/消息标识、聊天内容或图片加入仓库。

## 环境与构建

- iOS 16.0.3，微信 8.0.79，构建号 8.0.79.35。
- 插件 0.2.15，源码 `b76ac5f051072f8e78116aadcf9e9a9a92b4f222`，CI run `39550309486`；与本轮已核验交付包一致。
- 范围：未发送 type-3 消息的构造器、初始身份、图片扩展 getter 和 setter ABI 检查。不是图片装载或发送测试。

## 已证明

- `imageSendPreparation.state=contract_compatible_not_sent`，`constructorInvoked=true`、`extensionGetterInvoked=true`、`wrapFieldsCompatible=true`。按该版本检查器实现，构造完成后类型为 3、本地及服务器消息 ID 为零；不导出原始 ID。
- `initWithMsgType:` 返回对象、参数为 `q`，即 64 位有符号整数；不是旧的 32 位假设。
- `m_extendInfoWithMsgType` 是实际存在的零显式参数对象 getter，且本次读取取得可检查的扩展对象；无需 KVC/ivar 兜底。报告没有导出扩展具体类名，不猜测其名称。
- 扩展的 `setImage:withData:isOriginImage:` 存在，返回 `v`、三个显式参数为 `@`、`@`、`B`，ABI 兼容。
- `setImage:withData:isLongOriginImage:` 不存在，`longSelectorCompatible=false`；origin 分支通过，`selectedSelector=origin`。缺少 long 不表示整条图片链路不兼容，也不能反过来删除未来其他环境的兼容分支。
- `imageSetterInvoked=false`、`serviceResolved=false`、`submissionAttempted=false`、`sendingEnabled=false`、`deliveryOutcome=not_submitted`。本轮检查没有调用图片 setter、解析消息服务或提交发送。

## 不能据此判定的事项

- setter 尚未调用，没有图片数据装载、宿主资源写入或清理结果的实际证据。两个对象参数的业务约束、压缩策略和所有格式/尺寸不能仅凭 ABI 认定。
- 本轮 `sourceCapture=idle`、`offered=0`；图片读取 `reads=0`，接收未 armed、计数及方向样本为空。本轮没有重测图片来源、本人预览或其他发送者过滤；之前本人预览的用户确认仍单独保留。
- 历史日志中的图片事件带 `previousLaunch=true`，不能拼接成此次构建的新捕获证据。离线诊断工具的 `direction_details_missing` 在本次未等待、未发生接收的上下文中，不是新的接收失败，也无需为接口检查补发一张图。
- 文字候选 idle、`submissionAttempted=false`；历史 `claimed=true / uncertain / automaticRetry=false` 是保留的持久占位，不是本次又发送失败，不清除或重试。
- 导出时文字实验、倒计时和常亮占用均关闭；不从这次检查推导发送期间的完整常亮生命周期已验收。
- 未证明图片目标群送达、批量可靠性、跨重启图片发送恢复、其他设备或微信 8.0.76 兼容。

## 后续实现边界

下一阶段可按本机已验证的 origin ABI 实现独立单目标图片链路，并验证快照读取、UIImage/数据一致性、图片扩展装载及身份复验；实际调用 setter 前明确其可能的宿主本地写入副作用与资源生命周期。不能把本次“不调用 setter”的边界直接套在后续装载实现上。

真实发送仍需显式开启/确认、单个授权目标、至少 10 秒前台等待、单账号互斥、持久防重复、调用后有限精确身份观察和未知结果不自动重试。保留原文字 host/adapter 及持久占位，不放开批量或下一规则自动执行；先用小范围真机结果确认，再讨论扩大规则。

本次仅分析并记录报告，不修改发送代码、不升级版本、不重新打包。无需重复同一个接口检查。

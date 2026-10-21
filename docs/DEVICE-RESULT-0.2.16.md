# 0.2.16 单群静态图片首测记录

日期：2026-10-21。依据：用户提供的 1104 诊断，以及同次反馈“已测试 成功”。只记录脱敏事实，不将原始 JSON、账号/群/消息标识、图片、聊天内容或本地文件路径加入公开仓库。

## 环境与构建

- iOS 16.0.3，微信 8.0.79，构建号 8.0.79.35。
- 插件 0.2.16，源码 `43412c491f80434262681a3e26d51d4b33b2f5cc`，CI run `39553772820`；与本轮已核验交付包一致。
- 范围：本人在母群发一张图片，插件捕获、准备已校验快照，并经显式单目标实验装载及提交。配置虽含 3 个目标、1 条规则，但本次不是向这 3 个群执行规则，更不是批量验收。

## 报告可证明的事实

### 来源与素材

- `sourceCapture.state=preview`、`offered=1`、`rejected=0`，接收已停止，冻结一条来源。
- 当前进程日志包含 `outgoing_callback`、`own_pending`、`own_readback`、`image_pending`、`image_ready`、`capture_accepted`；方向样本为 type 3、from 为当前账号、to 为母群。这次确有新的本人图片捕获，不是上一进程的历史事件拼接。
- 首个回调出现一次 `receive_no_server_id`，随后本人精确回读取得可用来源并完成快照；不能把这个中间等待记成最终捕获失败。
- `imageSource.reads=1`、`state=ready`，getter ABI 兼容；`receiveCandidate.imageState=snapshot_ready`。没有开启原生图片下载。
- `singleImageSendCandidate.materialValidated=true`、`materialEncoding=jpeg_95_snapshot`。发送素材为已校验静态快照生成的 JPEG，质量参数 0.95；不据此承诺保留原文件、动画、透明通道或原图质量。

### 装载、服务与提交

- 构造器验证和实际调用类型均为 `q`。`imageSetterInvoked=true`，`selectedSelector=origin`；本次实际走 `setImage:withData:isOriginImage:`，返回 `v`、显式参数为 `@`、`@`、`B`。long setter 缺失不影响已通过的 origin 分支。
- preflight / pre_submit 的 route 均为 `forwarding_proxy`，`forwarding.rootCode=2`、`accepted=true`；服务元数据 ABI、身份/响应、完整转发签名及基础类匹配检查通过。仍向原代理正常派发，不解包或绕开代理。
- 当前进程恰有一条 `image_test_countdown`、一条 `image_test_claimed` 和一条 `image_test_submitted`，没有 `image_test_blocked`。倒计时开始至持久占位约 18.85 秒，符合最低 10 秒约束；没有从这一样本推断全部随机设置均已验收。
- `attemptConsumed=true`、`submissionAttempted=true`、`hostReturned=true`、`problem` 为空。图片装载与发送入口已经实际调用，不再只是 0.2.15 的未发送接口检查。
- 两次精确本地 ID 回读，`lookupMisses=0`、`identityConflicts=0`、`observationServiceCheckFailed=false`。本地/服务器 ID 最终均存在，原始 status 从 1 到 2；这些只说明身份关联观测推进，不定义为送达回执或图片内容校验。

### 结束状态与防重复

- 导出时 `observing=false`，图片实验开关、倒计时及 `singleImageExperimentIdleTimerHeld` 均关闭；插件已结束观察并释放常亮占用。不据此宣称手动锁屏、切后台或其他异常路径均已真机验收。
- 图片持久记录 `claimed=true / deliveryOutcome=uncertain / automaticRetry=false`，来源占位保留，不因观察结束或重启退款。
- 文字 host 本轮为 idle，`submissionAttempted=false`；旧文字持久占位仍在，不是本次又发送文字或发送失败。
- `batchSendingEnabled=false`，没有自动接力或批量 runner 发送。

## 用户反馈与结论

结合同次“已测试 成功”反馈，记录为：**该设备/构建上的单群静态图片主动发送首测成功（用户反馈）**。

用户没有另行逐项说明图片方向、压缩效果、重复条数或提供独立目标群截图，不将“成功”扩展成这些细项已独立验收。一次 setter/提交记录也不能单独证明目标群没有重复消息。

报告中的 `state=uncertain`、`deliveryOutcome=uncertain`、`imageContentVerified=false` 和 `deviceVerified=false` 保持原样。当前程序没有可靠自动送达或内容回执，用户的单次确认不改成“status=2 或有服务器 ID 即成功”，也不构成跨设备、跨版本兼容承诺。

## 下一阶段与未验收范围

- 本人图片单群发送基线已取得；其他指定成员图片、不同尺寸/方向、资源生命周期、另一设备或微信 8.0.76 仍需单独验收。
- 下一阶段先设计并验证少量授权测试群的串行执行、暂停/手动继续、异常停止和进程重启后未决状态保留，再逐步扩大规则；不能从本次首测直接开放 100/200 群实发。
- 已提交但没有可靠回执的目标保留未知状态，不作为“未完成”自动重发；图片装载后未提交也保留其副作用与防重复记录，不猜测删除宿主路径。
- 群池不写死 3000，100/200 群自动分规则、统一来源条件、母群/排除群过滤和逐条手动开始的产品规划不变；本轮没有验证完整群池或批量可靠性。
- 本次仅分析和记录结果，不修改发送实现、不升版、不重新打包、不清除任何占位。原包与构建身份不变，无需重复同一张来源图片的首测。

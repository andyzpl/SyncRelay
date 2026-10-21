# 0.2.13 单群文字首测记录

日期：2026-10-21。依据：用户提供的 1102 诊断报告，以及同次用户反馈“成功”。本记录只保留脱敏结论，不将原始报告、账号/群/消息 ID 或正文加入仓库。

## 环境与构建

- iOS 16.0.3，微信 8.0.79，构建号 8.0.79.35。
- 插件 0.2.13，编译源码 5284a78b12479641bbf6d3e29d71fb0ac5a0cd15，CI run 39543316236；与本轮交付包一致。
- 范围：显式开启的一次、单目标、普通文字实验。不是批量规则或图片验收。

## 报告可证明的事实

- 来源进入 preview，offered=1、rejected=0。
- preflight / pre_submit 的 route 均为 forwarding_proxy，managerClassCode=3、contextClassCode=1；forwarding.rootCode=2，证实该次服务实际属于 NSProxy 继承体系，不是直接 CMessageMgr 实例。报告仍未导出具体代理类名，不能猜测具体类名或所有版本的服务实现。
- 完整代理契约 accepted=true；元数据 ABI、身份/响应查询、转发签名与基础类匹配均通过。AddMsg 为 void + 两个对象参数，GetMsg 返回对象、显式参数为对象与 unsigned int。没有靠删除检查放行。
- 构造器验证和实际调用类型均为 q。
- 本轮倒计时至持久占位约 10.46 秒；随后 submissionAttempted=true、hostReturned=true，主机调用已正常返回。
- 两次精确本地 ID 回读，lookupMisses=0、identityConflicts=0、observationServiceCheckFailed=false；本地 ID 与服务器 ID 最终均存在。statusCode 从 0 到 2 仅作原始观测，不定义为送达回执。
- 导出时 observing=false、singleTextSendCountdown=false、singleTextExperimentIdleTimerHeld=false、singleTextSendExperimentEnabled=false；观察已结束、实验开关已关闭，插件常亮占用已释放。

## 用户反馈与结论

用户在同次测试后反馈“成功”，据此记为：**该设备/构建上的单群普通文字主动发送首测成功（用户反馈）**。用户未另行提供正文逐字核对、重复条数或目标群截图，不扩展为这些细项已独立验收。

报告本身仍为 state=uncertain / deliveryOutcome=uncertain，problem 为空。这是当前实验没有可靠自动送达回执的设计，不是本轮又被门禁阻断。deviceVerified=false 也不会因一个样本而自动改成跨设备、跨版本的兼容承诺。单次用户确认不应被写入通用的“status=2 就成功”判断。

## 尚未验收与下一阶段

- 微信 8.0.76、其他设备/注入环境、图片发送均未通过本轮验收。
- 100/200 群规则、批量暂停/继续、进程重启恢复、批量防重复与完整群池覆盖均未在本轮验证；batchSendingEnabled=false，runner 仍未接入真实发送。
- 下一阶段先设计并验证少量授权目标的顺序执行、暂停/继续、异常停止和跨重启保留未决状态，再逐步扩大测试范围；不能把这次单群成功直接推广成 200 群可靠可用。
- 保留现有持久占位及原发送链；不为继续测试清库、不自动重试已用来源。本轮只记录结果，不修改代码、不升版本、不重新打包。

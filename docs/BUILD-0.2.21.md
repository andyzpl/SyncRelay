# 0.2.21 消息类型探针交付记录

日期：2026-10-22。此包专门用于一次真机消息类型采样，版本号从 0.2.20 提升为 0.2.21，避免与上一轮小群包混淆。

## 构建身份

- 提交：`f652d5e97180a15f43437fd1e449f3b3063e87fc`
- CI：`39698033364`（[Actions](https://github.com/andyzpl/SyncRelay/actions/runs/39698033364)）
- Artifact：`12391831837`
- 普通 DEB：`dist/0.2.21-test-39698033364/andyz.syncrelay_0.2.21_iphoneos-arm.deb`
- DEB SHA-256：`9dd2738c7e07d2b1908d94995759a474d65e59a4f54323b8986e809979acdc51`
- 大小：`305426` bytes
- Artifact ZIP SHA-256：`b8df555c3a57ab4d72d59d37c6ef19528b4c0d99320366384c1caa45bb46d0af`

CI 通过 80 项 Python 测试、52 条原生 PASS、arm64/arm64e DEB 构建和载荷校验。包内 `control` 与 dylib 均为 `0.2.21`，不含旧的 `0.2.20` 版本字符串。

## 本包到底做什么

接收候选在通过来源群、来源成员、账号和方向检查后，将合法回调的 `m_uiMessageType` 以数字形式写入有界的 `receiveCandidate.messageTypeProbe`。未知类型仍只记诊断并走 `receive_type_filtered`，不会读取未知 payload、不会生成预览、不会创建计划，也不会发送。

Mikoto 静态路由证据写入报告的 `observedRoute` 字段：

| 微信类型 | 设备采样标签 | 静态路由证据 |
| ---: | --- | --- |
| 1 | 文字/自带表情 | 现有文字路径 |
| 34 | 语音 | `receiveMessageWrapWithType34` |
| 42 | 名片 | `receiveMessageWrapWithType42` |
| 43 | 视频 | 无 `receiveMessageWrapWithType43` 注册证据 |
| 47 | 自定义表情 | `receiveMessageWrapWithType47` |
| 49 | 文件或链接（同一微信类型） | `receiveMessageWrapWithType49` |

34、42、43、47、49 的资源 getter、appmsg/XML 结构和发送构造器尚未验证，因此不能把这次探针报告当作已经支持转发。


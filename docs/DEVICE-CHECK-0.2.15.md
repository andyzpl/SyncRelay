# 0.2.15 图片发送接口检查（不发送）

本人图片捕获和实际预览正确已获用户确认，记录见 `DEVICE-RESULT-0.2.14.md`。本轮只补充手机原生图片消息构造器与图片扩展的方法签名证据，不以离线模拟代替实际 ABI，也不把接口可用当作图片发出。

后续 1103 真机报告已确认：本轮构建在 iOS 16.0.3 / 微信 8.0.79.35 上检查通过，使用 origin 分支，未调用 setter 或发送。详见 `DEVICE-RESULT-0.2.15.md`；原测试设备无需重复本页检查，以下保留为检查流程及其他环境的证据范围。

## 本轮包身份（已核验，待手机检查）

普通 DEB：`dist/0.2.15-test-39550309486/andyz.syncrelay_0.2.15_iphoneos-arm.deb`，215558 字节；SHA-256 `c0d7ceff8ced07223f6814dcb07f81feae1517d38628dbce719ee5618bc936e7`；[公开 Actions 39550309486](https://github.com/andyzpl/SyncRelay/actions/runs/39550309486)，编译源码 `b76ac5f051072f8e78116aadcf9e9a9a92b4f222`，artifact `12323397520`。

本地 43 项 Python 测试和 74 项 arm64/arm64e 语法检查通过；公开 macOS CI 的 43 项 Python 测试、43 条原生 PASS、普通 DEB 构建/载荷校验及上传通过。下载后独立核对 artifact digest、包校验和、两架构构建身份/接口检查标记/签名载荷、系统依赖与微信主进程过滤。以上不等于手机接口或图片发送通过；本轮图片接口检查不调用图片 setter、消息服务或发送；既有单群文字实验门禁不变，图片实发/批量/自动重试仍关闭。

## 历史构建阻断与公开重建

源码 `0139ee7c7e2d56ed5fb5341f0ed1d29969001070` 已推送私有库。手动打包 run `39549098574` / job `119053941936` 在分配 runner 前失败，`runner_id=0`、steps 为空。GitHub 注释为：

> The job was not started because recent account payments have failed or your spending limit needs to be increased. Please check the 'Billing & plans' section in your settings

同源码 push 测试 run `39549080751` 也失败。该次没有执行 CI 原生测试、编译或打包，无可交付包或哈希。此后用户明确要求改为公开项目，2026-10-21 已检查历史并切换为 public，此后公开标准 macOS runner 已完成新的测试、构建和下载后核验，确切身份见本页包记录。原失败记录不变；不是旧包改名，不代表手机接口已通过。

## 安装与检查

1. 覆盖升级本轮普通 DEB，不卸载、不清配置，重新启动微信。
2. 打开「我 → 设置 → SyncRelay 转发」，在“运行诊断”确认版本 `0.2.15`。不要开启“单群文字实验发送”。
3. 停止源消息等待、手动发送观察或文字倒计时，有未保存修改则先点“保存”。无需重新捕获图片，不需要选择目标群。
4. 在“源消息与计划”区域点击“图片发送接口检查”，确认“检查（不发送）”。
5. 无论弹窗显示“接口兼容，尚未发送”还是“接口检查未通过（未发送）”，记住提示并导出运行诊断 JSON 发给开发者。一次检查就够，不必重复点。

## 本轮严格边界

- 只创建一条未发送的 `CMessageWrap` type 3，并检查初始消息类型和零 local/server ID。
- 只读取实际声明的 `m_extendInfoWithMsgType` 对象 getter；实际扩展对象的方法 ABI 必须是 `void(object, object, BOOL)`（BOOL 为 `B` 或 `c`），不凭 `respondsToSelector:` 就调用。
- 不调用图片 setter，不写入原生图片数据、不指定发送者/收件群，不解析消息服务，不调用发送，不建立任何持久发送占位，也不创建计划。
- 不使用 KVC、ivar 或转发兜底。若当前版本只有 Mikoto 使用的 KVC 路径而没有可验证 getter，本包会报告 `extension_getter_unavailable`，先取得证据再决定后续，不强行调用。
- 检查方法仍会执行宿主构造器和 getter；不承诺宿主内部实现绝无分配或缓存副作用。对象在检查结束后释放，插件不保留未发送 wrap/扩展对象。
- 原文字实验保持原来的默认关闭、二次确认、10 秒等待、持久防重复和每次进程一次限制。本轮没有修改文字 host/adapter 或数据库。
- 图片实发、自动重试、批量和下一规则自动接力仍关闭；不测 100/200 群。

## 诊断

新增 `imageSendPreparation`：固定阶段、`constructorInvoked`、`extensionGetterInvoked`、`wrapFieldsCompatible`、两种 setter 的兼容性及规范化 ABI。没有原始 wxid、群 ID、消息 ID、路径、图片或对象描述。

`contract_compatible_not_sent` 仅表示构造器、初始身份和可读取的扩展 setter 签名通过，不表示 setter 已调用、图片资源已写入、目标群可发送或消息送达。`imageSetterInvoked`、`serviceResolved`、`submissionAttempted`、`sendingEnabled` 应始终为 false。诊断工具会把这种检查与本人图片捕获、手动发送观察、单群文字发送分开解释。

本地 43 项 Python 测试及 74 项 arm64/arm64e 语法检查已通过；原生模拟测试和 DEB 构建需以本轮 CI 和下载后核验记录为准。模拟测试和打包均不代表手机接口已通过。

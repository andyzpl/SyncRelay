# 0.2.12 实际消息服务前置检查与诊断

## 已知事实与边界

000 报告来自 0.2.11、编译源码 868492f、CI run 39532575813，iOS 16.0.3 / 微信 8.0.79.35。源消息已进入预览；构造器验证和调用类型均为 q。倒计时完成，先写入实验占位，随后实际消息服务检查报 `message_manager_abi_incompatible`；未调用 AddMsg、未进入回读，也没有微信返回的发送错误。

报告导出的基础类 AddMsg 编码为 `v32@0:8@16@24`，但没有当时的实际对象分类或签名，不能确定是运行时子类、类对象还是其他差异。不能据此删除签名检查、猜测另一个发送入口，或声称已修复真实发送。

0.2.12 的改动：

- 在倒计时之前、倒计时结束但持久占位之前，解析实际上下文与消息服务，检查实例身份和实际 AddMsg/GetMsg 签名；这些预检查不构造或发送消息。
- 提交中再次解析服务，构造后重新核对同一服务对象。只用验证过的签名创建 invocation，仍由正常消息派发经过已有原链；不直调保存的 IMP、不跳过其他插件链。
- 保存最多两个检查快照 preflight / pre_submit，只记录类型分类、失败项、返回类型和参数类型，不含账号、群 ID、正文、类名、对象描述或地址。
- 保留 q 构造器修正、至少 10 秒等待、常亮恢复、账号/目标检查、每进程一次和跨重启不重试规则；不迁移或重置数据库。

这只能前移已知失败并补齐定位证据；预检查通过不证明微信能实际发送或送达。服务在占位后才变化的情况仍会阻断，已写入占位仍保留。

## 安装与本轮测试

1. 完全退出微信，安装 0.2.12 普通 DEB，再按原注入流程重载；保留原配置和数据库，不卸载清数据。
2. 进入「我 → 设置 → SyncRelay 转发」，检查母群、来源 wxid、文字类型与一个授权测试目标，保存。先不运行 100/200 群规则。
3. 开始等待，在母群发送一条新的短文字，捕获为新预览。000 报告的旧消息已占位，不能拿它再次实验；不要删除记录绕过。
4. 开启单群文字实验，选择一个非母群、未排除且在冻结规则里的授权群，二次确认一次。如果立即出现门禁失败，不连续点击，直接导出诊断。
5. 如果出现倒计时，保持微信前台，至少等待 10 秒，然后最多观察 30 秒。无论提示如何，只测试这一个目标一次，人工核对是否收到、条数和正文；不要把 local/server ID 当成功。
6. 立即导出 JSON，告知“立即阻断 / 倒计时后阻断 / 调用后待核对”，以及目标群是否看到消息。无论结果是否确定，都不补发。

## 诊断检查点

- `build.plugin = 0.2.12`，同时核对本包确切 commit / ciRun，防止旧注入残留。
- `singleTextSendCandidate.serviceEvidenceSchema = 1`；`validationStage` 指出阶段，`serviceChecks.preflight` / `pre_submit` 保存最近一次检查。缺失 pre_submit 表示本轮尚未走到该阶段，不代表签名通过。
- `managerClassCode` / `contextClassCode`：0 无对象，1 精确实例，2 真实继承的子类实例，3 不相关实例，4 类对象。只接受 1/2；不依赖可被重写的 isKindOfClass 回答。
- `contextReadFailed` / `serviceReadFailed` 区分只读调用失败与返回 nil；不包含异常文本。
- `add` / `lookup`：`available`、`argumentCount`（包括 self 与 _cmd）、`returnType`、最多 8 个显式参数类型、`sameMethodAsNamedClass` 和固定 `issue`。类型只保留标量编码、对象/块或 other，不导出任意宿主字符串。
- `issue`：compatible、missing_method、argument_count、return_type、first_argument、second_argument。错误分别是 `service_identity_rejected`、`concrete_add_abi_incompatible`、`concrete_lookup_abi_incompatible`。
- `submissionAttempted=false` 才能说此主机未调用；`claimed=true` 仍只是调用前占位，不能证明发送或送达。历史 claimed 是账号汇总，不一定是本次新源的占位。

批量 runner、图片、自动接力、自动重试继续关闭。本包需要设备补充实际服务证据，不把模拟通过或编译成功写成真机修复完成。

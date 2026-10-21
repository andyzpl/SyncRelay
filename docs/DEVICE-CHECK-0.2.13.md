# 0.2.13 消息服务代理契约适配

## 1101 报告结论

设备实际加载 0.2.12，编译源码 50fca63，CI run 39536006730。母群文字已捕获，基础类 ABI 通过。实际 MMContext 分类为 1，getService 读取没有报错，但返回服务分类为 3，运行时没有直接声明 AddMsg/GetMsg，因此旧门禁报 service_identity_rejected。

本次 submissionAttempted=false，initializerCallType=not_called，没有进入新倒计时、构造、持久占位或发送。不是微信服务器拒绝，也不是构造器 q 的回归。报告的 claimed 是账号级历史汇总，来自之前的实验，不能归到本次新源。

这些事实与代理/包装服务一致，但旧报告没有真实代理类型和转发契约证据，不能宣称已确认某个具体代理类。

## 本轮变更

- 直接 CMessageMgr 实例/真实子类继续检查实际声明的 AddMsg/GetMsg ABI。
- 对 MMContext 返回的其他实例，只有同时满足以下条件才支持正常转发：真实继承 NSObject/NSProxy；实际重写 methodSignatureForSelector 和 forwardInvocation；元数据查询方法的实际 ABI 匹配；服务声称具备 CMessageMgr 身份且响应 AddMsg/GetMsg；两份转发签名结构正确，并逐参数类型匹配基础类（包括整数宽度与符号）；若代理也直接声明对应方法，其实际声明必须与转发签名兼容，不能拿反射掩盖冲突。
- 不只依赖 isKindOfClass，不拿基础类签名盲发；缺方法、签名不符、异常和没有完整转发契约的实例仍阻断。
- 发送和精确 ID 回读始终派发到原服务对象，经过原代理链。不解包私有 ivar，不调用底层对象，不直调保存的 IMP。倒计时前、占位前和构造后复验；观察每次回读也重新验证，并使用此次验证的签名。
- 诊断子格式 serviceEvidenceSchema=2，保留旧分类和直接方法检查；新增 route 与 forwarding 的固定数字/布尔/类型字段。无任意运行时类名、地址、对象描述、正文或账号/群 ID。
- 保留一次单群、至少 10 秒、前台与常亮恢复、持久防重复。批量、图片、接力和自动重试仍关闭；不重置已有占位。

本轮是有条件的代理契约适配，不是无条件取消门禁。模拟服务可以验证派发和失败分支；是否覆盖本机真实代理，以及目标群实际收到与否，仍须真机验证。

## 安装与测试

1. 完全退出微信，安装本轮 0.2.13 普通 DEB，按原注入流程重载；不清配置、不删数据库。确认诊断 build.plugin 为 0.2.13，并核对同目录来源清单中的 commit/ciRun。
2. 只用一个已授权、非母群且在规则内的测试目标。保持原分组设置，不运行 100/200 群。
3. 开始等待，在母群发一条新的短文字并抓到预览。不要重复已占位的旧来源。
4. 开启单群文字实验，选一个测试目标，二次确认一次。若立即阻断，直接导出诊断，不连续点击。
5. 若有倒计时，保持微信前台，等待至少 10 秒及最多 30 秒观察。结果是待核对也不要补发；到目标群人工核对是否收到、条数和正文。
6. 导出新的 JSON，并告知立即阻断/倒计时后阻断/调用后待核对，以及目标群是否收到。

## 关键诊断

- serviceChecks.preflight/pre_submit.route：direct_instance / forwarding_proxy / rejected。
- forwarding.rootCode：0 其他，1 NSObject 系，2 NSProxy 系。
- signatureOverride、invocationOverride、metadataABICompatible：实际元数据方法结构及实现差异；不执行实际业务方法。
- claimsManager、respondsAdd、respondsLookup、queryFailed：受限只读查询结果。单项为真不代表放行。
- forwarding.add/lookup：固定签名 token 和 issue；addMatchesNamedABI / lookupMatchesNamedABI 严格匹配基础类，declaredAddCompatible / declaredLookupCompatible 防止代理反射掩盖真实方法冲突；accepted 是所有条件合取。
- 代理的顶层 add/lookup 仍可能显示 missing_method，这是没有直接声明，不等于转发接口不存在。必须结合 route 和完整 forwarding 判断。
- service_forwarding_unverified 表示代理契约尚未全部成立，不猜测为平台风控。若 submissionAttempted=true，结果仍然是 uncertain，不能用 ID 当送达证明。
- observationServiceCheckFailed=true 表示后续只读回读因服务契约变化而停止；原有两个快照描述提交前，不是变化后的状态。仍保留调用后待核对和不重试。

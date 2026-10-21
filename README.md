# SyncRelay

微信母群消息手动分批转发插件，目标环境 iOS 16.0.3、微信 8.0.76 / 8.0.79。

## 当前状态：0.2.16 单群静态图片实验，准备真机验证

新增独立的单目标图片实验，默认关闭、二次确认、按保存的 10 秒以上间隔等待，先持久占位再装载及调用发送。图片/文字共用一次进程机会；占位跨重启保留，装载或发送失败均不自动重试。未接入批量 runner。

图片由校验过的来源快照生成 JPEG，走实际扩展对象的严格 ABI；本机已验证 origin 分支，其他兼容分支仍需实际检查。setter 可能产生宿主本地媒体写入，后续阻断不退款占位、不删除猜测宿主路径；ID/status 不标记送达成功。步骤及限制见 `docs/DEVICE-CHECK-0.2.16.md`。本轮普通包及原生测试结果在完成核验后单独记录，尚不能视作图片发送真机通过。

### 0.2.15 已取得的接口基线

用户已确认本人发图进入预览，且打开实际图片核对正确，见 `docs/DEVICE-RESULT-0.2.14.md`。该次预览反馈未附新诊断；其他人图片、重启预览、图片实发及另一微信版本尚未验收。

随后收到 1103 诊断：加载的确为本轮 0.2.15，在 iOS 16.0.3 / 微信 8.0.79.35 上，未发送图片消息的 q 构造器、扩展对象 getter 及 `setImage:withData:isOriginImage:` 的 `void(object, object, BOOL)` ABI 检查通过，选中 origin 分支；long 方法不存在并非阻断。没有调用图片 setter、消息服务或发送，不等于图片装载/送达通过。事实及下一步边界见 `docs/DEVICE-RESULT-0.2.15.md`，无需重复本次接口检查。

0.2.15 新增“图片发送接口检查（不发送）”：只分配一条未发送 type-3 消息，核对图片扩展 getter 与两种 setter 的真实 ABI。没有图片写入、消息服务或发送调用、不占文字实验次数；图片实发/批量/重试仍关闭。步骤见 `docs/DEVICE-CHECK-0.2.15.md`，离线接收者/参数证据见 `docs/MIKOTO-IMAGE-EVIDENCE.md`。本地 43 项 Python 与 74 项双架构语法通过；构建/包身份以本轮实际结果单独记录。

2026-10-21 经用户明确授权，仓库已从私有改为[公开项目](https://github.com/andyzpl/SyncRelay)，并验证匿名可访问。历史源码、Actions 日志和附件的公开前检查见 `docs/PUBLIC-BUILD.md`。公开标准 macOS runner 已实际完成 0.2.15 测试、打包和下载后核验；随后该设备的图片接口检查通过，范围见上述结果记录。

历史私有构建 run `39549098574`（源码 `0139ee7c7e2d56ed5fb5341f0ed1d29969001070`）因 GitHub 账号计费门禁失败，原生测试、编译和打包均未启动，不是编译报错。公开重建的成功结果单独记录，不改变该次私有构建失败事实。

### 0.2.15 公开构建交付

普通 DEB：`dist/0.2.15-test-39550309486/andyz.syncrelay_0.2.15_iphoneos-arm.deb`，215558 字节；SHA-256 `c0d7ceff8ced07223f6814dcb07f81feae1517d38628dbce719ee5618bc936e7`；[公开 Actions 39550309486](https://github.com/andyzpl/SyncRelay/actions/runs/39550309486)，编译源码 `b76ac5f051072f8e78116aadcf9e9a9a92b4f222`，artifact `12323397520`。

本地 43 项 Python 测试和 74 项 arm64/arm64e 语法检查通过；公开 macOS CI 的 43 项 Python 测试、43 条原生 PASS、普通 DEB 构建/载荷校验及上传通过。下载后独立核对 artifact digest、包校验和、两架构构建身份/接口检查标记/签名载荷、系统依赖与微信主进程过滤。以上不等于手机接口或图片发送通过；本轮图片接口检查不调用图片 setter、消息服务或发送；既有单群文字实验门禁不变，图片实发/批量/自动重试仍关闭。

### 0.2.14 图片捕获包交付记录

图片来源链路已接入：按已保存的母群/发送者 wxid/类型过滤，支持本人发图的服务器 ID 等待，读取微信原生已就绪图片，保存独立校验快照，展示实际图片。取消清理预览文件，确认计划后保留并支持重启查看；诊断不包含图片或路径。依据与边界见 `docs/MIKOTO-IMAGE-EVIDENCE.md`，测试步骤见 `docs/DEVICE-CHECK-0.2.14.md`。

该轮只验证图片捕获，不开放图片发送、批量或自动重试。没有资源时最多在 30 秒轮询窗口等待，不把媒体引用、XML 或猜测路径当作成功图片。已成功的文字 host 和单群实验门禁不改，旧持久占位不清。交付时尚待手机核对，后续用户反馈见当前状态及单独结果记录。

普通 DEB：`dist/0.2.14-test-39546922750/andyz.syncrelay_0.2.14_iphoneos-arm.deb`，209760 字节；SHA-256 `4885557bc449264f1856706cdf58350950c6f834598c9ee5ecf534e8e32e0ba4`；CI run `39546922750`，编译源码 `1db6b94e653cda2bc555c233523141c77fe54c43`。

本地 70 项 arm64/arm64e 语法、37 项 Python 测试、私有 CI 的 40 条原生 PASS、普通 DEB 构建及下载后核验通过。覆盖图片资源就绪/超时、提前过滤、本人图精确 ID、过期代次隔离、资源完整性/配额/路径限制、取消清理与计划重启保留，并回归既有文字流程；不代表手机图片捕获、实际预览或送达通过。

### 0.2.13 单群文字首测成功（用户反馈）

1102 诊断与用户“成功”反馈已核对：iOS 16.0.3 / 微信 8.0.79.35，加载确切交付的 0.2.13。实际服务为 NSProxy 体系，两阶段完整转发契约通过，发送调用正常返回；两次精确 ID 回读无遗漏或身份冲突，观察结束后常亮占用已释放。本轮记为这一设备/构建的单群文字首测成功，详细证据、用户反馈与未验收范围见 `docs/DEVICE-RESULT-0.2.13.md`。

结果中的 uncertain 仍表示缺少自动送达回执，不是门禁再次阻断；不把非零 ID 或 status=2 直接改成发送成功。该版批量、图片和自动重试仍关闭；8.0.76 与 100/200 群尚未通过本轮验证。成功反馈当时仅作记录；后续图片开发另见当前阶段。

### 0.2.13 适配与交付记录

1101 手机报告确认 0.2.12 取得了服务对象，但其真实类不继承 CMessageMgr，且没有直接声明 AddMsg/GetMsg。旧门禁在倒计时/新占位/调用前拒绝；不是微信服务器拦截。它可能是代理服务，旧诊断不足以确认具体代理类型。

0.2.13 增加有条件的代理契约支持：真实 Foundation 继承结构、元数据方法 ABI 和重写、身份/响应查询、转发签名与基础类逐参数匹配，缺一仍阻断。始终向原服务对象正常派发，不解包或跳过代理；最终提交和每次精确 ID 回读继续验证。诊断区分直接声明与转发签名，避免误把代理缺少直接方法当成 ABI 已被证明不符。单群/倒计时/持久防重复/批量关闭均保留。原测试步骤见 `docs/DEVICE-CHECK-0.2.13.md`；后续首测结果见当前状态及对应结果记录。

普通 DEB：`dist/0.2.13-test-39543316236/andyz.syncrelay_0.2.13_iphoneos-arm.deb`，190996 字节；SHA-256 `e8881ed15bd54a6854458cf97a51f8a813f86399fa0aafbc89de5e1a5b14a738`；CI run `39543316236`，编译源码 `5284a78b12479641bbf6d3e29d71fb0ac5a0cd15`。

交付时，本地 62 项 arm64/arm64e 语法、32 项 Python 测试、私有 CI 的 34 条原生 PASS、普通 DEB 构建及下载后核验通过。原生模拟覆盖直接实例与完整代理转发；当时尚待真实服务及目标群反馈，后续 1102 首测结果单独记录，不将构建成功本身当作真机通过。

### 0.2.12 历史定位包

000 手机报告确认 0.2.11 的 `q` 构造器已通过，来源预览和 10 秒等待正常，但实际服务对象的后置检查报 `message_manager_abi_incompatible`；`submissionAttempted=false`，尚未调用发送。该次已有持久占位，保留不清除。报告只有基础类方法签名，不能据此确定实际服务对象哪一项不符，更不是平台拦截的证据。

0.2.12 在倒计时和持久占位之前解析实际服务并核对 AddMsg/GetMsg；构造后仍重新核对同一个对象，使用已验证的签名正常派发，不绕过原链。新增只含分类、类型和失败项的双阶段快照，区分服务解析、类对象/错误实例、返回值、参数个数/类型。它是定位包，不声称未知的实际服务差异已经修好。最新步骤见 `docs/DEVICE-CHECK-0.2.12.md`；不清配置，不重试已占位的旧来源。

普通 DEB：`dist/0.2.12-test-39536006730/andyz.syncrelay_0.2.12_iphoneos-arm.deb`，184822 字节；SHA-256 `c96d00ec98252fcf2fa94d900670d6805eb0031734208940a1c2758b71bc8aa8`；CI run `39536006730`，编译源码 `50fca63ee8b5f7299b04c99ea4d5362105d4d44a`。

本地 62 项 arm64/arm64e 语法、28 项 Python 测试、私有 CI 的 34 条原生 PASS、普通 DEB 构建与下载后核验通过。未取得实际服务差异和目标群送达的新设备证据，不能把构建成功当作发送修复。

### 0.2.11 构造器修正及历史包

888 手机报告已定位 0.2.10 的“发送门禁未通过”：微信 8.0.79.35 的 `initWithMsgType:` 使用 64 位整数 `q`，而旧版只接受 32 位 `i/I`。该次 `submissionAttempted=false`、无持久占位，尚未调用发送接口。0.2.11 严格按实际 `i/I/q/Q` 类型构造，新增对应模拟测试；不绕过账号/目标/防重复检查，不宣称后续发送已真机通过。最新测试步骤见 `docs/DEVICE-CHECK-0.2.11.md`，请勿继续用旧 0.2.10 重复验证此问题。

普通 DEB：`dist/0.2.11-test-39532575813/andyz.syncrelay_0.2.11_iphoneos-arm.deb`，185466 字节；SHA-256 `eb48318201f19e275ae2b0fc99b87c51e43563f5f80c36f4d3c2d55748d0a84e`；CI run `39532575813`，编译源码 `868492ff4c47b6ca2a1d6e48b806b59ebfeb5650`。

本地 62 项双架构语法、23 项 Python 测试、私有 CI 的 34 条原生 PASS、普通 DEB 构建及下载后核验通过。修正包尚未取得实际目标群送达结果，不能用构建成功替代真机结论。

### 0.2.10 实验边界及历史包

本轮在 777 手机报告的手动发送关联证据上，开放默认关闭的一次、单目标文字实验。仅允许捕获时规则内的非母群、未排除目标；二次确认后至少等待 10 秒，调用前持久占位，同源跨重启不重复，整个微信进程最多调用一次。前台等待和有限观察期间请求禁止自动锁屏，所有退出/停止路径恢复此前值。没有可靠送达回执，结果只记待核对，不自动重试。

设置页仍在「我 → 设置 → SyncRelay 转发」，按钮“保存”，导航栏不透明；可选悬浮入口默认关闭。单群实验不等于批量规则可执行；100/200 群、图片、自动接力和批量恢复仍未开放。手机步骤见 `docs/DEVICE-CHECK-0.2.10.md`，契约见 `docs/SEND-ADAPTER.md`。旧 0.2.9 包不包含本轮跨重启占位和生命周期收尾，请勿作为本轮测试包使用。

本地 Python 与 arm64/arm64e 固定 SDK 语法检查、私有 CI 测试/打包结果和确切交付身份记录在开发进度及产物目录；模拟测试或构建成功都不等于手机送达成功。

普通 DEB：`dist/0.2.10-test-39527121454/andyz.syncrelay_0.2.10_iphoneos-arm.deb`，185364 字节；SHA-256 `57f907c5c85d194f3143732dc43b47bfbcbaa4381c4deb2b1ad874d07952903b`；CI run `39527121454`，编译源码 `ee18b735c77ca47cd363df5b0d3dd30ac14217fc`。

本轮通过本地 62 项双架构语法、21 项 Python 测试和私有 CI 的 34 条原生 PASS，构建与下载后核验通过；待真机检查，不宣称送达或两版兼容已通过。

### 历史包与修正

0.2.7 交付包当时通过本地 54 项 arm64/arm64e 语法检查、14 项 Python 测试（12 项诊断解析、2 项 UI 源码契约）；[私有 Actions 39469338784](https://github.com/andyzpl/SyncRelay/actions/runs/39469338784) 的 28 条核心 PASS、14 项 Python 测试、普通 DEB 构建/双架构检查/上传均通过。0.2.8 已通过 58 项 arm64/arm64e 语法检查、17 项 Python 测试以及本轮 CI 的 31 条核心 PASS，普通 DEB 已完成双架构、载荷、签名存在性、依赖和 SHA-256 核验；包仍不等于手机捕获或视觉通过。

上一轮安装包（0.2.7）：`dist/0.2.7-test-39469338784/andyz.syncrelay_0.2.7_iphoneos-arm.deb`，158344 字节；源码 `a9445759ba07a16e60c740438becd8260ac2caf2`，后续文档提交不改变包身份。SHA-256：`49ba337d125b7bba4725eef80a844687fc9912dc8d41d2a1c0d92747eea8b616`。0.2.8 包将单独记录源码提交、CI run 和 SHA-256，不覆盖这份历史产物。真实转发保持关闭。

本轮 0.2.8 安装包：`dist/0.2.8-test-39520101009/andyz.syncrelay_0.2.8_iphoneos-arm.deb`，165014 字节；源码 `b60fee9cefe39384dc25de69a68bfc71e22b3648`；[私有 Actions 39520101009](https://github.com/andyzpl/SyncRelay/actions/runs/39520101009)，artifact `12310912776`。SHA-256：`49d8c2ef68fc3c8c9622d66645365b31ead3a40ac6284c0f7250ae7f9719ed75`。`ci-provenance.json`、`SHA256SUMS` 和 `DEVELOPMENT-NOTICE.txt` 在同目录；`deviceVerified=false`，请按 `docs/DEVICE-CHECK-0.2.8.md` 做单群测试。

2026-10-21 收到该包的成功手机诊断：iOS 16.0.3、微信 8.0.79.35，构建提交/run 一致。本人文字方向 from/to 已可读（7），旧实例反射状态仍为 2；01:56:43.354 的本人发送回调最初无服务器 ID，经过待确认及一次精确本地 ID 回读尝试，01:56:44.402 被接受进入预览（offered 1、rejected 0、reason 0），随后自动停止等待，耗时约 1.048 秒。结合生产门禁可确认该次取得非零服务器 ID，不证明投递成功，也不能仅凭回读尝试事件断言最终 ID 来自回读对象。此报告不包含原始 ID/正文，仍须用户核对预览；他人成员、图片、母群切换、群池完整性、真实转发及顶部视觉不由此报告验收。详情见 `docs/DEVICE-CHECK-0.2.7.md`。

已完成一个明确授权测试群的“手动发送观察”（不代发）：微信 8.0.79.35 上观察到 1 次匹配 outgoing，随后通过精确 local ID 回读看到服务器 ID 从无到有，未出现 lookup miss、身份冲突或丢样本。该结果只证明消息关联路径可继续研究，不证明插件主动发送或服务器送达。`tools/diagnose_report.py` 现在会把 outgoing、local readback、ID 状态变化和“待核对”明确分开；不开展 100/200 群实发。

下一步是实现默认关闭、二次确认、单目标单条文字的主动发送适配器模拟与门禁测试；在适配器 ABI、账号/群核对和未知结果处理完成前，不会把按钮接入 `SRRunner`，也不会生成或执行批量规则。

0.2.5 手机报告已确认母群回调是 CMessageWrap、消息类型为文字，但 from/to/real sender 在原方法前后全部为 `state = 2`：实例反射签名路径拒绝，尚未读取字段值。不能把相等关系均为 false 解释为真实 wxid/群 ID 不同，也不能从这份报告断言微信改写了字符串。

0.2.6 为消息字符串添加独立的 runtime 声明读取器：只对实际存在的零参数对象 getter 校验实际类的方法编码后，用标准 Objective-C 消息派发读取，继续验证 NSString 并复制；不依赖对象自报的反射签名、不猜 ID、不使用 ivar/KVC 或转发兜底。接收、本人文字待确认和只读发送观察切换到该读取器，联系人/服务原读取路径保持不变。群/账号/wxid/类型/非零服务器 ID 校验均保留，方向子格式升级为 2 并保留旧实例签名状态供比对。此修正随 0.2.7 取得上述本人文字成功手机结果，不能泛化其他路径；0.2.6 历史预案见 `docs/DEVICE-CHECK-0.2.6.md`。

0.2.6 本地 54 项双架构语法检查及 12 项 Python 诊断测试通过，但[私有构建 39464466046](https://github.com/andyzpl/SyncRelay/actions/runs/39464466046)（源码 `2d27fdd34b227da4778e0572e31ff6686fe64ebe`）最终失败，job 被取消且没有执行任何步骤。GitHub 注释明确提示未能分配 hosted runner，并提示 macOS ARM 容量不足；产物数 0，不存在可交付的 0.2.6 包或哈希。0.2.7 改用标准 `macos-15-intel`，仍用固定 Theos/SDK 交叉编译 arm64/arm64e 普通包，不降低测试要求；标签依据 [GitHub runner label announcement](https://github.blog/changelog/2025-09-19-github-actions-macos-13-runner-image-is-closing-down/)。

### 0.2.5 历史诊断包

0.2.4 手机报告已确认 iOS 16.0.3、微信 8.0.79.35 上保存后可以开始等待，两个消息入口均被观察到，但所选母群会话的回调被 from/to 方向检查拒绝，未进入规范化候选。该报告不能确定具体字段值或哪个字段不匹配，也不能证明既有规则下的母群切换已验收。

0.2.5 为同一次等待中最多 12 次母群会话回调补充宿主原方法执行前/后的脱敏方向证据：字符串读取状态、账号/来源群的相等关系、消息类分类、消息类型。只记录布尔值/数字，不读正文、不导出原始 ID，不放宽原有捕获校验，也不自动采用调用前的数据。证据仅在内存，需失败当次导出；步骤见 `docs/DEVICE-CHECK-0.2.5.md`。普通包已构建核验，不宣称已修复抓取或手机兼容。

本轮普通 DEB：`dist/0.2.5-test-39461950419/andyz.syncrelay_0.2.5_iphoneos-arm.deb`，157802 字节；编译源码 `bcbc987f14af491156795325d5bdb95992dc124a`，后续文档提交不改变包身份。本地 54 项双架构语法与 9 项 Python 测试、[私有 Actions 39461950419](https://github.com/andyzpl/SyncRelay/actions/runs/39461950419) 的 28 条核心 PASS 及 9 项 Python 测试、普通包构建/上传通过。下载后核验哈希、包身份/载荷、两个 slice 的编译身份/方向诊断标记/签名载荷、系统依赖及微信主进程过滤。SHA-256：`e64d9d707acfb3c011a17b9b9e80da7695a118833134d3b5c8f1f607817b36ee`。同目录含来源清单与 `PHONE-TEST.md`；随后收到上述手机报告，仍未捕获到候选，真实转发关闭。

### 0.2.4 历史测试包与实现

用户反馈更换母群后不能开始等待，以及已等待但抓不到消息。0.2.4 更换母群不再清空全部目标规则，仅移除新母群及空规则；来源成员仍需重新选择并保存。缺账号/母群/来源成员/目标规则分别给出具体原因。

新增可查看、复制、手动导出的 JSON 运行报告、最多 300 条脱敏持久事件、回调分支计数和构建身份。默认不导出草稿本体、原始 wxid、群 ID或正文，也不自动上传。维护流程见 `docs/RUNTIME-DIAGNOSTICS.md`；手机步骤见 `docs/DEVICE-CHECK-0.2.4.md`。抓取失败仍需新报告定位，不能宣称已经修复。

本轮同时按用户指定的微信/Mikoto 原生列表方向收拢样式：紧凑导航、通栏 grouped 列表、左名称/右当前值、诊断下移，群/成员仍显示原始 ID。没有 iPhone/模拟器画面，未验证实际视觉；发送仍未启用。

本轮 0.2.4 普通 DEB：`dist/0.2.4-test-39458985577/andyz.syncrelay_0.2.4_iphoneos-arm.deb`，151916 字节，编译源码 `14e634fa32f39d0a3cad7698fedaf55b4dc1b70f`（后续文档提交不改变包内身份）。本地 arm64/arm64e 共 54 项语法检查、5 项 Python 诊断解析测试，以及[私有 Actions 39458985577](https://github.com/andyzpl/SyncRelay/actions/runs/39458985577) 的 28 条核心 PASS、5 项 Python 测试、普通 DEB 构建和下载后核验通过。SHA-256：`cdece7971eefd6e65666ee5c184a434a70234478287557147341babd4f5309f6`。两个 slice 均含确切提交/run，只有自身 dylib/plist、微信主进程过滤和系统依赖，签名载荷存在。手机步骤同目录 `PHONE-TEST.md`；尚未验证实际捕获、分享、原生样式或两版兼容，真实转发仍关闭。

0.2.3 提供明确的“我（当前登录账号）”来源选项，移除禁止本人作为唯一来源的限制；母群从手动排除列表隐藏并明确标为自动排除，生成/保存时的母群目标保护保持不变。本人文字通过原发送链之后的只读观察及可选精确 ID 回读取得服务器 ID；不扫描历史、不调用发送接口。尚未真机验证，步骤见 `docs/DEVICE-CHECK-0.2.3.md`。

历史 0.2.3 普通 DEB：`dist/0.2.3-test-39454590524/andyz.syncrelay_0.2.3_iphoneos-arm.deb`，140428 字节，源码 `0956862a59e5c6d299df6528a6134e4c80f0dc15`。本地 arm64/arm64e 共 50 项语法检查、[私有 Actions 39454590524](https://github.com/andyzpl/SyncRelay/actions/runs/39454590524) 的 25 条 PASS、普通 DEB 构建及下载后核验通过。SHA-256：`c445d3e8a757930be7b2a5a8aa10c3caf75c74a08a99538aee67a1aaa04323c2`。仅自身 dylib/plist、仅微信主进程过滤、双架构且只有系统依赖；未验证手机运行，不会自动转发。

不是可用的批量群转发成品，只有显式单群文字实验。新版主入口为「我 → 设置 → SyncRelay 转发」，不再强制显示悬浮按钮。面板内“开启悬浮入口”默认关闭，独立保存开关，打开后才显示“同步／预览／观察”（预览优先）；关闭立即移除，重启保持选择。
成员读取、手动文字接收和发送观察均为带签名检查的候选适配，尚未在两版微信上真机验证；接口不匹配会停止并提示诊断。
0.2.1 已收到手机反馈：「我 → 设置」找不到入口，不能再把其模拟测试通过当成宿主适配通过。离线核对 Mikoto 的宿主路径后，0.2.2 补充 `m_tableViewMgr` / `WCTableViewNormalCellManager`，保留旧版表路径；增加页面加载/出现及安装较晚时的刷新。原生私有表不匹配时，只在设置列表底部保留同名可点击入口，不强制悬浮、不接管微信的表代理。存储失败也可进入诊断，规则操作停用。实现/证据边界见 `docs/GROUPS-AND-SETTINGS.md`，重测步骤见 `docs/DEVICE-CHECK-0.2.2.md`。尚无手机通过结论。

历史 0.2.2 普通 DEB：`dist/0.2.2-test-39450276375/andyz.syncrelay_0.2.2_iphoneos-arm.deb`，132424 字节，源码 `bdc418c494ae1c76041fe0d3727afcbbddf0b4c1`。本地 arm64/arm64e 语法共 50 项、[私有 Actions 39450276375](https://github.com/andyzpl/SyncRelay/actions/runs/39450276375) 的 25 条 PASS、普通包构建与校验/上传通过。下载后再次核对清单、注入过滤、双架构及签名载荷、系统依赖和包哈希：`74723dc097ed2f8fab9d5f2ed59f78103366fd9fc239020559b65780ed35139b`。这不是设置入口真机通过或两版微信兼容的证明，也不包含 0.2.3 本人来源修正。

历史 0.2.1 包：`dist/0.2.1-test-39441160370/andyz.syncrelay_0.2.1_iphoneos-arm.deb`，源码 `d87cd4a`。48 项语法、[私有 Actions](https://github.com/andyzpl/SyncRelay/actions/runs/39441160370) 25 条 PASS 和包校验通过；126876 字节，SHA-256 `c9af1bb7698002508cb48e67ba3650a2a564e5dcd770d85028582833e62714fb`。该包入口在用户设备未出现，不能重新交付同一包作为修正版。

首轮 0.2.0 用户反馈只返回 4 个普通群；旧包不会自动具有本轮修正。0.2.1 在原联系人接口之外补充本地会话用户名，按群 ID 合并，并展示脱敏来源计数；真实覆盖范围仍需手机核对，不把本地候选当成全部已加入群。

已编写母群选择、成员原始 wxid 显示/多选、文字/图片开关、随机间隔编辑、排除群搜索与批量操作、100/200 群自动分规则、分组去重与按账号保存设置。
保存不会创建发送批次；手动捕获后的确认只建立内容计划，也不会发送。没有可用的批量开始/继续/重新执行按钮。设置（内部 draft）与已确认计划、运行记录分离，保留旧执行历史。

## 单条源消息与历史

1. 保存统一条件和规则后，手动点击“等待一条母群文字”；接收入口不会在启动时安装，只有这次操作通过签名及账号检查后才挂接候选。
2. 可关闭面板回母群，由已选择的成员（含本人）发一条文字。候选核对会话/来源群、当前账号、原始发送者、消息类型和非零服务器 ID；不按昵称或正文猜身份，不回退临时本地 ID。本人路径可以按刚观察到的精确 local ID 回读，不能扫描历史。
3. 第一条匹配后停止等待，在“单条源消息预览”核对完整正文、群 ID、wxid 和冻结配置；可放弃，确认则事务性建立全部规则，绝不开始发送。
4. 修改等待中的草稿、离开前台或账号变化会取消等待；回前台不自动重新等待。预览只是内存数据，进程退出后需重新捕获；确认后的计划可重开读取。
5. “已确认内容计划与历史”分页查看计划、规则状态、批次和异常群。完成时间读取原有结束时间，不用打开页面时间；只显示异常群细节，不逐条刷出成功记录。

当前候选处理其他成员与本人的文字，未开放图片/媒体或接收历史扫描。回调是否包含离线补同步、正文是否带群消息前缀、服务器 ID 字段及精确回读是否稳定，均需真机核对；不能把签名检查通过当作兼容性证明。真实转发接入前仍须补充本插件发送消息的回环过滤。
细节与证据边界见 `docs/RECEIVE-CANDIDATE.md`。

## 原包研究与手动发送观察

已继续分析用户提供的 MikotoHelper DEB：限定离线 ARM64 模型还原 `PJTransmitModel` 的 12 次及 `PJHelper` 元类的 224 次业务方法注册，核对一个普通文字路径的 `MMContext -> CMessageMgr -> AddMsg:MsgWrap:` 调用点。不是只搜选择器，也不是完整源码还原；输入哈希、原始地址和模型边界见 `docs/MIKOTO-SEND-EVIDENCE.md`。

新增“只读观察一次手动文字发送”：手动选择一个授权测试群，关闭面板后在 120 秒内由用户用微信正常发送一条普通文字。观察原链之后的元数据及精确本地 ID 读取，保留原始状态码；不读正文、不代发、不写投递成功。切后台、锁屏、账号变化或期限到达后停止，不自动重开。报告在“查看适配诊断”中复制，不含账号/群/消息 ID。最新报告已证明 outgoing 与精确回读的关联推进，但 `deliveryOutcome` 仍固定为 `not_determined`。

已找到的一个 `MessageReturn:MessageInfo:Event:` hook 的附加逻辑调用 `changeHeaderFinish`，不能把它误当成已验证的文字发送回执；发送观察不 hook 此入口，也不把服务器 ID 或状态数字直接解释为成功。细节见 `docs/SEND-PROBE.md`。

当前优先修正 0.2.1 手机缺失入口，群来源合并维持不变；入口恢复后再核对是否仍只返回 4 群。本轮不做 100/200 群实发测试。

旧 0.2.0 包记录：功能/测试源码 `201bbd4`，打包提交 `c9bec6e`。本地语法 42 项和[私有 Actions](https://github.com/andyzpl/SyncRelay/actions/runs/39434037504) 22 条 PASS；文件 117410 字节，SHA-256 为 `adf7853d7aa0b3141044e1236d21189faa698de5b6ec5cdd0f1c7ca284142461`。后续收到只返回 4 个普通群的反馈，不将旧测试结果视为群读取完整性证明。

## 自动分组

1. 统一设置一次母群、来源成员 wxid、文字/图片类型和间隔；所有草稿规则共用这些条件，不需重复设置。
2. 在“搜索并排除群聊”勾选不想转发的群；可按名称/原始 ID 搜索，并批量排除或恢复搜索结果。取消全部排除也可保存。
3. “自动分配规则”填写每条 100 群、200 群各生成几条。例如 10 + 10：最多新增 20 条规则、3000 群；先分 100 群规则，再分 200 群规则。
4. 预览实际可分配数、生成条数、缺口和剩余，再确认生成。群不足不报错中止：最后一条按实际数量，后续不建空规则。已有规则保留并自动去重。
5. 生成仅修改当前设置，需点“保存”才能持久化；不会捕获或发送。未来执行仍需逐条手动开始，绝不自动接力。

候选群池不写死为 3000；当前使用 12345 个模拟群测试读取、搜索和分配。实际能读取多少受微信接口、本地群记录、设备资源影响，尚未真机验证完整性。
手动选择是可选入口，全选目标也自动拆成每条不超过 200 群；100/200 是本轮分组规格，不是底层存储的全局上限。
更改排除项会先提示从已有草稿规则移除的目标及空规则，不自动补齐或重排其他规则；不会更改已创建的计划/执行历史。临时未被接口列出的排除 ID 仍保留在排除页。
随机节拍和小批次不构成平台限制规避或必达承诺。

旧版设备清单保留于 `docs/DEVICE-CHECK-0.2.0.md`。历次构建结果、产物与 SHA-256 见开发进度文档。

已编写的模块：

- `Core/SRStore.m`：计划、互斥分组、独立执行批次、持久化状态、暂停/恢复、重新执行、结果关联。
- `Core/SRPacing.c`：至少 10 秒的随机节拍计算，单调时钟输入，恢复时不补发错过节拍。
- `Core/SRConfiguration.m`、`Core/SRSelection.m`：草稿校验、完整列表批量选择、来源群与重复目标排除。
- `Core/SRGroupPlanner.m`：共享条件、按配额自动分组、不足额预览和持久化排除的候选草稿生成，不触发发送。
- `Core/SRSourceCapture.m`、`Core/SRSourceMessage.m`：规范化消息过滤、单条预览冻结和确认后原子创建计划；已连接手动文字接收候选，尚待真机验证。
- `Core/SRRunner.m`：串行派发、账号互斥、节拍和超时核对核心；仅使用测试发送器验证，启动时不会运行它。
- `Adapter/`：运行时签名检查、只读联系人/成员候选接口、脱敏诊断及显式单目标文字主机候选，未连接批量发送。
- `Adapter/SRWeChatReceiver.m`：手动文字接收候选，保留原接收链，只向内存捕获器提供核对后的规范化数据。
- `Adapter/SRWeChatSendProbe.m`：最长 120 秒的单群手动文字发送观察，保留原链、精确 ID 关联、有限脱敏样本，不读正文或推断送达。
- `Adapter/SRWeChatTextSendAdapter.m`：默认关闭的单群单条文字发送门禁；执行版本/ABI、账号、目标群、源快照和二次确认校验，仅显式实验注入主机操作，详见 `docs/SEND-ADAPTER.md`。
- `Adapter/SRWeChatSettingsEntry.m`、`Core/SREntryPreferences.m`、`UI/SRSettingsFallback.m`：新旧微信设置表、生命周期/晚安装刷新、设置页内恢复入口和默认关闭的悬浮开关；不替换微信表格代理，不强制悬浮兜底。
- `UI/SRPanel.m`、`UI/SRPlanScreens.m`：原生设置、搜索多选、手动等待、单条确认、计划/规则/历史/异常只读页面及适配诊断。
- `Tweak/SRBootstrap.m`：仅在微信主进程初始化存储和设置入口，不注入扩展进程。
- `tests/`：直接调用生产核心的测试。模拟确认不是微信真实回执。

尚未完成：其他来源/8.0.76 接收核对、单群主动发送真机核对、可靠结果判据、图片/媒体、批量执行按钮与生命周期、失败补发 UI/策略及长时设备验收。
规范化过滤和调度核心说明见 `docs/RELAY-CORE.md`；它们不等于已经接入微信。
群枚举保留原包实际使用的 `getContactList:contactType:` `(1,0)`，补充 `MMNewSessionMgr.GetUserNamesOnSessionList`（数组或集合），会话独有群还需精确联系人 ID 核对；读取前后复核账号，合并去重。某个来源不可用时明确提示降级，均不可用时停止；不遍历猜参数或请求服务器通讯录。原包来源证据见 `docs/GROUPS-AND-SETTINGS.md`，不能保证覆盖全部已加入群；成员来自本地群成员字段，也不保证实时完整。
`SRStore` 的 claim 是存储层操作；接入发送器时必须先经过节拍、单账号身份和适配可用性检查。
传入 confirmed 只说明调用方声称已验证结果；未来适配器必须提供实际确认依据，消息 ID 本身不证明服务器已接收。

## 编译

使用公开 GitHub Actions 的标准 `macos-15-intel` runner，保留相邻 OwnHide 项目采用的固定版本 Theos/SDK。
工作流：`.github/workflows/build.yml`。日常代码 push 运行 Python、C 和 Objective-C 核心测试，不安装 Theos、不生成 DEB；纯 Markdown 更新不触发。
只有需要手机验证时，手动触发并明确勾选 `build_deb`，才会在测试通过后构建普通 DEB，检查 arm64/arm64e slice 并上传 Actions artifact。该选项默认关闭，后续产物保留 7 天。源码、历史、工作流日志及构建附件不再保密；不要上传真实诊断或第三方二进制。

[GitHub 官方计费说明](https://docs.github.com/en/billing/concepts/product-billing/github-actions)：公开仓库标准托管 runner 的运行时间免费；大型 runner 仍收费，附件存储等另受额度与计费规则约束，不宣称所有 Actions 功能免费。公开不等于已经选定开源许可证，本次不新增许可证。

普通包载荷位于 `Library/MobileSubstrate/DynamicLibraries`。不附带安装脚本，不自动重启微信，不发布 GitHub Release。
包不包含第三方 MikotoHelper 二进制、反汇编输出或本地工具缓存。

macOS 本地核心测试：

```sh
clang -std=c11 -Wall -Wextra -Werror -I. Core/SRPacing.c tests/pacing_test.c -o /tmp/sr-pacing
/tmp/sr-pacing
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I. Core/SRStore.m Core/SRConfiguration.m Core/SRSourceMessage.m Core/SRPacing.c tests/store_test.m -framework Foundation -lsqlite3 -o /tmp/sr-store
/tmp/sr-store
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I. Adapter/SRRuntime.m Adapter/SRWeChatReader.m Core/SRSelection.m Core/SRConfiguration.m Core/SRPacing.c tests/adapter_test.m -framework Foundation -o /tmp/sr-adapter
/tmp/sr-adapter
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I. Core/SRGroupPlanner.m Core/SRSelection.m Core/SRConfiguration.m Core/SRSourceMessage.m Core/SRStore.m Core/SRPacing.c tests/group_planner_test.m -framework Foundation -lsqlite3 -o /tmp/sr-groups
/tmp/sr-groups
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I. Adapter/SRRuntime.m Adapter/SRWeChatReceiver.m Core/SRConfiguration.m Core/SRSourceMessage.m Core/SRSourceCapture.m Core/SRStore.m Core/SRPacing.c tests/receive_test.m -framework Foundation -lsqlite3 -o /tmp/sr-receive
/tmp/sr-receive
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I. Core/SRStore.m Core/SRConfiguration.m Core/SRSourceMessage.m Core/SRPacing.c tests/plan_queries_test.m -framework Foundation -lsqlite3 -o /tmp/sr-queries
/tmp/sr-queries
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I. Adapter/SRRuntime.m Adapter/SRWeChatSendProbe.m tests/send_probe_test.m -framework Foundation -o /tmp/sr-send-probe
/tmp/sr-send-probe
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I. Adapter/SRRuntime.m Adapter/SRWeChatSettingsEntry.m Core/SREntryPreferences.m tests/settings_entry_test.m -framework Foundation -o /tmp/sr-settings
/tmp/sr-settings
```

完整需求和真实进度见 `开发需求与进度.md`。8.0.79.35 已有一次本人捕获和手动发送观察证据，不代表主动发送或两版完整兼容。

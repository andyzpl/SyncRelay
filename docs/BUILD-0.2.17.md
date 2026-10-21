# 0.2.17 小群规则与前台进度交付记录

日期：2026-10-21。状态：普通 DEB 已构建并独立核验，手机多群及前台体验待测试。以前的单群成功反馈不扩展为本版本多群验收。

## 确切构建

- 源码：`e9c7fed09b345bbab6f856fa0cef14dc4ea6d10f`。
- [公开 macOS CI 39568329268](https://github.com/andyzpl/SyncRelay/actions/runs/39568329268)，job `119115993549`，artifact `12330613948`；2026-10-21 16:22:47（Asia/Shanghai）完成。
- 普通 DEB：`dist/0.2.17-test-39568329268/andyz.syncrelay_0.2.17_iphoneos-arm.deb`，275690 字节，版本 `0.2.17`，架构 `iphoneos-arm`。
- DEB SHA-256：`f1f787f03645b247358dcde3eb409f2f53cc56a26c73154c58e65ec7f6a605be`。
- artifact ZIP SHA-256：`141d132c1acf52bf1564087058c29c73fe6728a2bc394e874de37a6c68b1b2f5`，与 GitHub artifact digest 相符。
- 仅交付此最终包；本轮此前失败的 run `39566714820` 在原生测试阶段停止，DEB 构建/上传均跳过，没有交付中间包。

## 回归与包核验

本地 66 项 Python 测试、90 项 arm64/arm64e 语法检查通过；最终 CI 的实际日志核对 66 项 Python 和 52 条原生 PASS。52 条由一个 C 测试程序执行一次、17 个 Objective-C 程序各执行三次构成，不写成 52 个独立测试套件。三目标 session 是主线程模拟 host，不冒充手机实际送达。

此前新增测试直接在大 autorelease pool 内断言旧 session 立即释放，受到主线程临时引用生命周期影响。最终测试先排空该池再保留同样的弱引用释放断言；随后重启恢复、旧回调隔离、持久占位和图片链路等完整三轮原生回归通过，没有删除释放检查或放宽未知结果门禁。

下载后检查 Debian ar、control/data 载荷集合、ZIP 路径/文件类型、包 SHA 与附件 SHA；只有 `SyncRelay.dylib` 和对应 plist，没有安装脚本。plist 仅注入 `com.tencent.xin`。依赖仅 `firmware (>= 15.0)`，dylib 依赖仅系统框架和 `/usr/lib`，不依赖 Mikoto 或附带第三方二进制。

两 slice 分别为 arm64（640800 字节）和 arm64e（657424 字节），逐 slice 核对版本/commit/run、新 session/逐尝试占位/进度控件及旧文字图片安全契约标记，并检查代码签名载荷存在。签名载荷存在不等于已在用户注入工具或手机验签加载成功。

本地证据与清单：交付目录内 `ci-provenance.json`、`local-verification.json`、`SHA256SUMS`、`PHONE-TEST.md`；CI 原始日志留在忽略的 `.build-cache/job-119115993549.log`，本地语法日志为 `.build-cache/syntax-0.2.17.log`。没有将手机原始诊断、账号/群 ID、正文、图片或凭据上传公开仓库。

## 使用范围与维护

每条规则最多 3 个授权目标，一次只明确开始这一条；文字和静态 JPEG 快照复用已验证的原生单次 host。开始前逐 delivery/attempt 持久占位；有限精确回读只支持“已提交”证据，不是确认送达。下一间隔从结果处理后起算，观察会使实际间隔超过设置上限。

微信保持前台时，不依赖设置页可见；新增有界的进度胶囊只处理自身触摸，提供拖动及暂停/继续。与可选悬浮入口开关分开，不创建或抢占窗口。回复聊天、视频号/全屏、键盘和大字体表现尚未真机验证。切后台/锁屏/账号变化暂停，返回或重启不自动续跑；未知/失败不重发，继续只处理 pending。100/200 群、重新执行和自动下一条均未开放。

新小群路径的诊断以 `smallGroupExecutionImplemented` 和 `smallGroupExecution` 为准，后者含聚合 counts、busy/dispatchEnabled、问题码及最多三份脱敏 hostEvidence/currentHost。原有独立 host 的单次/批量开关字段不是新规则执行状态，不应仅凭旧单群 host 处于 idle 推断本次规则未调用。源码式维护分析器的旧单群结论也不能替代该新节的证据。

覆盖升级并重开微信；schema 7 不降级，保留配置、计划、媒体和防重复占位。新建一次源消息/内容计划，再用 1–3 个授权测试群验证。详见 `docs/DEVICE-CHECK-0.2.17.md`，本轮不要求逐群人工操作或复核后才能继续；出现异常再导出一份诊断即可。

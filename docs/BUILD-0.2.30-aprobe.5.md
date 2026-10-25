# 0.2.30+aprobe.5 阶段 A 生命周期候选

**2026-10-25 最新打包状态（不是 `.5` 新包；普通包随后已安装并回传 `102501`）：** 当前开发快照已在隔离分支 `codex/a-package-20261025`、提交 `02cf7fb963fb4e34bb2a83a35d68fd1415e2aa87` 上运行一次 `build_deb=true` CI `40179290423` / job `121126667336` 并成功；普通 `0.2.21` DEB 的 SHA-256 为 `bedb3a3a722dd10dbeed51ee857e4e9eaaf6fecd83666c6ee235df0a9e9692d5`，artifact ID `12592629882`。快照生成时未安装、未迁移或清理设备数据；随后用户安装普通包并回传 `102501`，其 `storageReady=1` 类型缺陷见本地收口记录；`.5` 的历史真机证据不被新包冒充，A 的真实宿主门槛仍未整体验收。

**2026-10-25 最新开发侧状态（不是 `.5` 新包）：** 隔离快照提交 `aa01abe451a5bd4254f6e3df829ac4fdb8032f29` 由 CI `40169810412` / job `121098186039` 以 `build_deb=false` 成功完成。Python 224 项、22 个 Objective-C 目标三轮、3 个 C 目标按既有配置执行 5 次通过；探针字段夹具和 inactive 时钟失败边界均已原生验证。5 个打包步骤全跳过、artifact=0；没有新包、安装、迁移或设备操作，`.5` 设备包身份和既有真机证据不变。全新 schema 14、A 的真实宿主门槛仍未整体验收、B/C 关闭；详见 [本地收口记录](OPERATIONS-A-LOCAL-CLOSEOUT.md)。

**2026-10-25 历史开发侧状态（不是 `.5` 新包，迁移路径移除前快照）：** 隔离快照提交 `c35fb7181bc211d2b1d19e1de6c92a9b8bee9609` 由 CI `40147383615` / job `121031524021` 以 `build_deb=false` 完成当时快照的 Python **214 项**、Objective-C 原生目标三轮执行及 C 目标编译/执行。没有生成 DEB、安装、迁移或设备操作；该证据不能覆盖当前工作区，`.5` 的设备身份和 `102427`/`102428` 证据边界不变，A 仍未整体验收。

**2026-10-25 范围纠正：** 当前产品是全新 schema 14 设计，不要求 schema 11→14 旧库迁移；`.5` 文档中的迁移段落只保留为历史背景，不再要求设备配合或重复导出迁移报告。

**2026-10-25 后续本地集中收口（不是新构建，当前工作区本地阶段）：** 工作区新增资源并发/阈值/提醒修复，完整 Python **211 项**、C 三程序各三轮执行、双架构 **106 单元**语法检查通过；当前精确代码/测试快照已在隔离 CI 完成 Objective-C 原生编译/链接/三轮执行，但没有生产链接/打包。上方 214 项隔离 CI 属于迁移路径移除前快照，不能覆盖当前源码。本页 `.5` 及后续 migdiag 的历史构建、产物与设备身份不变，也不要求重装或重复报告。统一证据边界见 [本地收口记录](OPERATIONS-A-LOCAL-CLOSEOUT.md)。

**后续报告边界（2026-10-24）：** `102427` 仅确认设备当前 schema 14 且本次未执行迁移，不能冒充 schema 11→14 真机迁移；`102428` 无采样回调，记证据不足。设备端只需停止采样，不再重复同类操作。


日期：2026-10-24。状态：**`.5` 已完成 CI/DEB 核验并取得真机有限证据；阶段 A 未整体验收。** 设备包绑定 commit `12e3a999d359a1020d1b01f6c00f82b8f6f80528`，CI `40064748000`；未在本轮重复构建、安装、迁移或清理设备数据。

## 精确范围

**后续 UI 修复包（独立于本 `.5` 包）：** 真机反馈悬浮入口拖动无明显效果后，隔离分支 `codex/aprobe5-ui-fix-20261024` 将入口和执行进度胶囊从“松手吸附左右边缘”改为保存二维自由位置，并继续使用短标题“来源时间采样”。普通 DEB `0.2.30+aprobe.5-ui.1` 由提交 `d4efa2b44724206a727a669d187251b6f4ad9eae` 在 CI `40097991572` 构建，产物与散列见 `docs/OPERATIONS-A-DEVICE-READINESS.md`。用户已安装并回传 `102426`，随后反馈本轮已测项通过；报告确认包身份和安全基线，UI 结果单列为用户人工反馈，不冒充 JSON 自动验证，不扩大到阶段 A 整体验收。靠边收纳增强先记录，待现有功能链路跑通后再完善。

- 基线：`03abb9bfaccd46f05d68877f37f7eefeb92bee6b`（`0.2.29+aprobe.4`）。
- 候选分支：`codex/operations-a-device-probe-20261024-aprobe5`。
- 拟用版本：`0.2.30+aprobe.5`；包 ID `andyz.syncrelay`；普通 `iphoneos-arm` DEB。
- schema：14；不新增迁移 SQL，不改发送核心、receiver 发送 ABI、消息库派发、视频或 B/C UI。
- 生产增量：`SRSourceTimeProbe` 只读 `resumedAfterInactive`；每轮开始/停止/超时清为 false，2 秒宽限内恢复且仍 active 时置 true。只表示“本轮观察到前台 inactive 后在宽限内恢复”，不证明宿主页面切换完成、系统后台或完整生命周期。
- 诊断/分析器：导出 `resumedAfterInactive`；分析器校验类型及“不得与 `inactivePending=true` 同时出现”。旧报告缺该字段仍可单独分析，但不得用作 `.5` 切页恢复证据。
- 测试/文档：补原生生命周期断言、源码契约守卫、分析器反例，以及设备步骤和导出说明。

## 本地证据

- 隔离树 `py -3 -m unittest discover -s tests -p '*_test.py'`：**181 项通过**。
- `tests.diagnose_report_test`：**44 项通过**。
- `tests.source_time_probe_contract_test`：**11 项通过**。
- 指定 Python 文件 `py_compile` 通过；`git diff --check` 通过，仅有既有 CRLF/LF 提示。
- 以上不是 Objective-C 编译/链接/模拟执行、DEB、安装、迁移或真机证据。

## 待批准外部动作

若要取得设备可用的 `.5`，需另行明确授权：

1. 提交并仅推送非 `main` 分支 `codex/operations-a-device-probe-20261024-aprobe5`；
2. 对该精确提交执行一次 `workflow_dispatch(build_deb=true)`；
3. 下载并核验普通 DEB 身份、双架构、control/载荷/过滤/签名和 SHA-256。

不包含安装、RootHide 转换、设备数据库迁移、清理数据、推送 `main` 或发布。若设备库可能是旧 schema，安装会触发既有迁移；没有备份/回滚方案与单独授权不得安装。迁移后不能安装 schema 11 旧包降级。

## 真机证据回填

- `102417` 通过系统级 inactive 停止边界：超过 2 秒后 `state=inactive`、receiver disarmed，回前台不自动重开。
- `102421A`/`102421B` 通过同轮停止保留：`round=11`，旧/新文字分别为 `older_than_boundary/strict=0` 与 `after_boundary/strict=1`，停止后样本和 hook 保留。
- `102422` 通过本人 local-ID 回读关联：`hookMessageOrdinal=1`，后续 server-ID 交付与 early local hook 同轮关联。
- `102423` 仅通过图片早期元数据观察：type 3、getter `I`、server ID 存在；`imageReads=0`、资源就绪仍未覆盖。
- `102424` 未观察到微信内切页对应的 inactive/active 通知；`resumedAfterInactive=false`，不再把同样页面操作重复记为失败或通过。

以上是脱敏真机证据回填，不改变“来源时间语义未认证、图片资源就绪未覆盖、阶段 A 未整体验收”的结论。

## 设备判据摘要

- 首份 `.5` 报告：`build.plugin=0.2.30+aprobe.5`、构建提交/run 与批准记录一致、`storageReady=1`、`schemaVersion=14`、发送关闭、图片读取 0、手动捕获 idle、采样 off。
- 切页：开始采样后在微信内切页并在 2 秒内返回，稳定前台后只导出 B。B 应为 `active=true/state=sampling`、`inactivePending=false`、`resumedAfterInactive=true`、receiver armed；不得用导出前的系统分享面板当作切页操作。
- 超时/后台：控制中心或 App Switcher 停留超过 2 秒、或真正后台，应 `active=false/state=inactive`、receiver `armed=false`、`resumedAfterInactive=false`，回前台不自动重开。
- 离线停止：同一轮 active A、手动停止 B，使用 `--stop-pair A B`；A 导出会打开分享面板，若返回时已 inactive，该轮不得冒充手动停止保留。
- 图片资源就绪仍没有安全被动入口，继续 `imageReadinessObserved=false`。

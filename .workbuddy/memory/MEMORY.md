# SyncRelay 项目长期记忆

## 隔离验证分支的修复已全部回填主工作区（2026-10-22 完成）

成功基准：隔离快照提交 `90ed08af6b2687056358642aef1c66aa1a02c162`（树 `ba9b583c…`，分支
`codex/operations-a3-native-2-20261022`），CI run 39807280389 全绿。

按行回填（**不从快照整文件覆盖**）后，34 个白名单文件用 `git hash-object` 逐个比对成功快照：
**34/34 blob 完全一致**。回填内容：

| 文件 | 回填内容 |
|---|---|
| `tests/media_budget_test.m` | 236 行补最外层中括号（第三轮就已同步） |
| `tests/automatic_progress_test.m` | 197 行 `== 13` → `== 14`；198 行夹具 `user_version=14` → `=15`（199 行"拒绝打开未来版本"断言保留） |
| `Core/SRMediaQuota.c` | `SRMediaLevelFor` 警告阈值改为 `used * policy.warn_denominator >= limit * policy.warn_numerator` |
| `tests/media_quota_contract_test.py` | 45 行源码文本断言同步为同一正确公式 |

回填后主工作区：Python 159 项 OK、`git diff --check` 干净、`main` HEAD 仍 `f652d5e`、暂存区 0、索引与基线一致。
本轮未提交/推送/合并/重派 CI/打包。

## 已通过 CI 验证的结论（2026-10-22）

- 原生清单完整跑通：71 次程序执行（22 ObjC × 3 + media-quota C × 3 + pacing/operations-state 各 1），
  三轮输出逐字一致；快照内 Python 143 项 OK；5 个 `build_deb` 打包步骤全 skipped；artifact 0。
- 期间修掉的真实缺陷：ARC block 捕获 autoreleasing 出参、素材失败/COMMIT 失败的错误传播与新建文件清理、
  `media_budget_test.m` 链式取下标缺中括号、`automatic_progress_test.m` 过时 schema 期望、
  配额 4/5 警告带分子分母写反（该带曾永不触发）。
- 注意：CI 成功 ≠ 真机通过；阶段 A 未整体验收。

## 阶段 A 本地审查基线（2026-10-26 核对，未改代码）

- 版本门禁顺序：`Core/SRStore.m` 先 `PRAGMA user_version` 再 `SRRequire(== 0 || == 14)`，之后才设
  journal/WAL/synchronous；schema 建表在 `BEGIN IMMEDIATE` 事务内，`SRRequire` 抛 NSException → ROLLBACK；
  `PRAGMA user_version=14` 仅 version==0 时写。1/13/15 空库用例是**负向门禁**，不是迁移能力。
- 测试接线全在 `.github/workflows/build.yml`（Makefile 无 test 目标）：22 个 ObjC 测试各跑 3 轮，
  pacing/operations-state 各 1 轮，media-quota 3 轮；`set -euo pipefail`，无 `continue-on-error`/`|| true`。
- 上述三项观察项已于 2026-10-26 修复：senderIDs 改为 fail closed、`observedMessageTypes` 只在当前
  generation + 身份门禁 + 中继类型门禁全通过后写入、`SRSourceCapture` 增加 generation 令牌并隔离轮次。
- 文档状态约定：任何"最新/当前"标签只能指向最新证据（当前为修复包 `102502`：commit `5d31177`、
  CI `40205959680`、DEB sha256 `e7afd73e…`）；旧包 `102501`/`02cf7fb`/`40179290423` 一律标历史并注明
  保留为缺陷证据。该修复只验证 `storageReady` 布尔字段，不代表阶段 A 整体验收。

## 接收路径门禁顺序（2026-10-26 修正，勿回退）

身份门禁（决定"这条回调是否属于当前轮"）与捕获门禁（决定"什么可以被捕获/预览/投递"）必须分离，
且身份门禁在前。两条回调路径（`observeSession:` / `observeOutgoingManager:`）的公共骨架为：

`sender 身份 → 时间证据 → 账号` → ① type-49 只读 XML 探针 → ② 中继类型门禁 → ③ 类型普查

**server ID 不是跨路径统一的身份门禁**，必须按路径区分（2026-10-26 更正，勿再写成"统一门禁"）：

- 收路径 `observeSession:`：server ID 是**硬门禁**，位于 sender 身份之后、时间证据之前
  （`receive_no_server_id`）。relay 与 census 都在其之后 → 收路径的 relay/census 路径要求 server ID。
- 出站路径 `observeOutgoingManager:`：**没有** server ID 身份门禁。server ID 只是**结算门禁**
  （`pollOutgoing:` 里 `GetMsg:LocalID:` 精确回读）。故出站 type 1 在账号+sender+generation+
  时间证据+已选 text 类型满足时即记入 census（不要求 server ID），但只有拿到 server ID 才可能
  成为 source candidate；出站 type 49 只读探针在无 server ID 时仍可观察，且不产生任何业务结果。
- `allowsSenderIdentity:` 是 fail-closed 身份门禁（`nil`/空 `senderIDs` 一律拒绝）；
  `allowsSender:` = 身份门禁 + 中继类型门禁（text/image；49 → `"unsupported"` 拒绝）。
- type 49 永不中继，但必须可观测（`docs/APP-MESSAGE-PROBE.md`：type 49 仍失败于中继类型门禁，
  但"已明确 arm 且选中发送者"必须能调度只读 XML 检查）。故探针调用必须在中继类型门禁**之前**，
  类型普查 `observeMessageType:generation:` 必须在其**之后**（否则 49 会污染普查）。
- 账号变化必须能 stop 捕获，即使该消息类型未被选中；否则旧账号的捕获会一直 armed。
- 低层 `armForAccount:sourceGroup:` 的 `selectedTypes` 实为 `{text}`、`senderIDs` 为 `nil`。
  把它换成 config arm 时若照抄 `draft()`（types = `{text,image}`）会静默改变语义：type-3 夹具会进入
  图片路径，`pendingImage` 守卫会阻断后续文本投递。改用 config arm 必须显式指定 `types`。


## 约定

- 隔离原生验证：快照只能由 `prepare_snapshot.sh --commit` 以 **main** 为父创建；
  要追加"子提交"必须直接在既有隔离工作树里改、提交，再非强制快进推送。
- 比对快照差异要用 `git hash-object` 的 blob 哈希；`git show` 的字节比对会因 CRLF 过滤误报。
- `git status` 条目相同不能证明文件相同（未跟踪文件内容变化仍显示 `??`），
  内容核对一律用 blob 哈希或具体 diff。
- 本机可用相邻 `E:\ios玩机\apps\OwnHide\.build-cache` 缓存的 libclang 18.1.1 + iPhoneOS 16.5 SDK 做
  双架构语法检查（`py -3 tools/syntax_check.py --cache …`）；ObjC/C 的编译链接与执行仍只能靠 GitHub Actions。
- 诊断 JSON 的布尔字段必须显式 `@YES`/`@NO` 装箱：`@(a != b)`、`@(a || b)` 在 ObjC 中是 `int`，
  会序列化成 `0/1`。`storageReady` 已按此修正（2026-10-25），其余布尔字段分析器仍用宽松 `flag()` 接受 0/1。
- 本机没有 `gh` CLI。触发 CI 的既有做法：`.build-cache/sr_private_http.py` + `git credential fill`
  取令牌调 GitHub API。两个坑：`workflow_dispatch` 的 `ref` **不接受裸 commit SHA**（返回 422），
  要用分支名再用 `head_sha` 断言产品来自精确提交；下载 job 日志/artifact 跟随 302 后**必须去掉
  Authorization**，否则 blob 存储回 401。
- 静态核验 DEB 不需要 dpkg-deb：先用 zipfile 解 artifact，再手写 ar 解析（`!<arch>` + 60 字节头）；
  control 通常是 `control.tar.gz`，theos 产物数据段可能是 `data.tar.lzma`；Mach-O 脂肪头
  cputype `0x100000c`、subtype 高位 `0x80000000` 即 arm64e。

# B-3 消息库与资源容量只读界面（2026-10-28）

本轮只增加两个**只读**页面和一个设置页入口，不扩大发送能力。它不导入、不编辑、不删除、
不清理、不建任务、不派发，也不建立第二套来源或容量状态。

## 1. 页面

| 页面 | 入口 | 数据源（Core 只读 API） |
| --- | --- | --- |
| 消息库列表 | 设置 → 源消息与计划 → 消息库 | `libraryItemsForAccount:limit:offset:error:` |
| 条目详情（含版本） | 列表内点条目 | `libraryItem:account:error:` |
| 资源容量 | 设置 → 源消息与计划 → 资源容量 | `mediaUsageForAccount:error:` + `mediaResourcesForAccount:limit:error:` |

三者都绑定打开时的账号，并在 `reload` 的第一步核对；账号变化时进入独立状态并隐藏旧数据，
不会切换到新账号。

## 2. 状态分离

| 状态 | 消息库 | 条目详情 | 资源容量 |
| --- | --- | --- | --- |
| 空数据 | 「消息库还没有条目」 | 「没有版本记录」 | 「本账号没有已登记的素材」 |
| 读取失败 | 「读取失败」+ 下拉重试 | 「读取失败」+ 下拉重试 | 「用量读取失败」/「资源列表读取失败」分开 |
| 素材不可用 | — | 「素材不可用：本地没有该版本的媒体引用」 | 「未知」（缺字段不显示 0） |
| 归属未验证 | — | — | 「资源归属未验证」+ 不显示明细 |
| 结果不完整 | — | — | 「结果不完整」+ 不宣称没有素材 |
| 账号变化 | 「账号无法核对或已经改变」 | 同左 | 同左 |
| 离开前台 | 「内容已隐藏」 | 同左 | 同左 |
| 重试 | 下拉刷新 / 点问题行 | 下拉刷新 | 下拉刷新 |

用量读不到时分两种：整份读不到 → 全部显示「未知」；**只读到一半**（有 `usedBytes` 但没有可用
`limitBytes`）→ 同样全部显示「未知」，不把 1 B 之类的具体值旁挂一个未知上限。只有
`usedBytes` 与 `limitBytes > 0` 同时可用时，页面才发布已用/上限/占比/剩余/可回收/文件数。

资源列表的三种"空"必须分清：`referencesVerified=NO` 时**不显示任何明细行**（无法证明文件属于
本账号），`rows=[] && truncated=YES` 时显示「结果不完整」而不是「没有素材」，只有完整读到空
才是正常空态。读取保持 `limit:200` 的有界上限。投影的 `listedCount` 在任何状态下都等于
已发布的 `rows` 数量，被拒绝展示的列表不会报出非零计数。

**两个失败互不影响**：用量失败只占容量 section（该 section 退化为一行问题 + 重试），资源
section 仍按已读到的结果展示；列表失败只在资源 section 显示问题行，容量数字照常显示。
section 数量、行数、表头表尾、cell 与重试分支都按这一条实现——失败不折叠整页，也不隐藏
另一段有效数据。

## 3. 内容展示的安全边界

- 文字版本：列表给 120 字有界摘要，点开复用既有只读文本页（`SRCreateReadOnlyText`，
  由 `SRPlanScreens` 提供，账号核对与退到后台隐藏的行为不变）。
- 图片版本：**只显示已存的像素与字节元数据**，并明确「素材不在此页渲染」。页面不读取
  素材字节、不准备媒体、不调用宿主图片 getter、不下载。
- 未知类型显示「未支持（kind）」，不降级成文字。
- 资源行只显示派生标识（`identifier`）、类型、字节与引用状态；不显示路径或 token。

## 4. 生命周期与账号

三页都监听 `UIApplicationWillResignActiveNotification` / `UIApplicationDidBecomeActive`：

- **离开前台**：`masked=YES`，清空本页已展示的数据，显示「内容已隐藏」。只改显示，**不**停
  receiver、不取消捕获、不建任务、不启动发送。
- **回到前台**：先重新核对打开本页时的账号；失败则 `accountInvalid=YES`、`masked=NO` 并清屏，
  显示的是**账号失效**提示而不是普通遮蔽提示；不静默切换到当前账号；成功才 `reload`
  （`reload` 会清掉 `masked`）。
- 屏蔽态与账号失效是两个不同显示：前者只发生在离开前台期间，后者发生在回前台核对失败之后；
  两者都清空旧数据，且点击不触发任何跳转。

## 5. 未接通的入口保持关闭

- 来源切换（`setSourceMode:`）、主动导入、库派发、删除与清理都没有入口，也没有伪装的
  可用状态；页面底部明确写出"不提供导入、编辑、删除、清理或派发"。
- 只读页的账号校验器只做 `verifyAccount`，**不复用**计划页那个会停 receiver、取消捕获的
  校验器——打开一个只读页面不得改变业务状态。

## 6. 重复点击与返回

- 两个入口共用一个守卫：账号有效、当前页是导航栈顶、没有 presented 页面、没有进行中的
  转场，否则不压栈。列表进详情同样先判栈顶。
- 返回沿用系统导航；页面不在生命周期回调里自动重启捕获或发送。

## 7. 版本与包身份

- `Core/SRVersion.h` 与 `control` 同步升到 **0.2.22**；`tests/version_consistency_test.py`
  锁定两者一致、语义化版本、包名与微信 bundle filter，并断言 CI 只生成
  `Core/SRBuildRevision.h`，不得改写产品版本。
- 这样新包与 `0.2.21` 在版本号上可区分；包身份仍以 SHA-256 与内嵌 commit/ciRun 为准。

## 8. 新增纯投影

`Core/SRMediaProjection.h/.m`：Foundation-only、无状态。

- `bytesText:`（B/KB/MB/GB，缺值「未知」）、`levelText:`、`resourceKindText:`、
  `libraryKindText:`、`stateTextForRow:`；
- `usageSummary:`：已用/上限/占比/剩余/文件数/可回收 + `available` / `problem` / `note`
  （扫描不完整、可回收不完整分别提示）；**只有整份读数可用才发布数字**；
- `resourceRow:`：派生标识、类型、字节、状态与三个布尔标记；
- `resourceSectionForPayload:`：`state` ∈ `rows / empty / truncated_empty / unverified /
  unavailable`，附 `notice`、`listedCount`、`otherAccountCount`、`truncated`、`verified`。
  归属未验证时明细行一律为空。

## 9. 明确未做

- 不提供导入、编辑、删除、清理、派发；不改 schema、执行上限（仍为 1–20）、发送路径、
  冻结计划或阶段 A 文档。
- 不渲染图片缩略图，也不读素材字节。
- 未接通的"来源切换"没有出现在 UI；`SRVersion` 之外没有第二个版本来源。

## 10. 验证层级

已实际执行（本机 Windows）：完整 Python 套件、`compileall`、`git diff --check`、双架构
语法检查（缓存 libclang，含新增 `Core/SRMediaProjection.m`、`UI/SRLibraryScreens.m`、
`tests/media_projection_test.m`）。

**未执行**：`tests/media_projection_test.m` 的编译/链接/执行（Windows 无 Foundation），
格式化的实际取值结论只能由 macOS CI 给出；UIKit 布局、真机与打包均未验证。源码契约与
语法检查不等于 UIKit 或真机通过。

原生用例覆盖（`tests/media_projection_test.m`，待 CI 执行）：半份用量不发布数字
（`usedBytes` 有值但上限缺失/为 0）、可读的零用量仍可用、归属未验证时隐藏已返回的行、
`truncated` 空列表与完整空列表区分、截断但非空的列表仍列出、失效载荷不可用。

Python 侧只做源码契约（`tests/phase_b3_media_contract_test.py`）：生命周期遮蔽与回前台
重核、账号失败清屏、三种空态措辞、投影函数被页面使用、注册位置。**Python 镜像不能代替
原生执行**，上述取值结论以 CI 的原生运行结果为准。

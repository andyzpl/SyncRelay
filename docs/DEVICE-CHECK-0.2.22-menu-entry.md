# 0.2.22 菜单入库入口：真机结论与遗留问题

日期：2026-11-01。环境：iOS 16.0.3，微信 8.0.79（构建号 8.0.79.35），插件 0.2.22。
分支 `codex/phase-b-ui-20261027`，提交 `a1e26ca`（构建 run 41318351552）。
本记录只保留脱敏结论：不含账号、群 ID、消息 ID、正文或路径。

## 1. 已验证可用（真机）

- 开关“菜单入库（长按文字）”打开后，长按普通文字消息会出现“存入同步库”；
- 点击后写入插件自己的消息库，导出报告 `libraryMenu.hook.lastIntent = 0`（Saved）；
- 图标使用系统符号，模板渲染，与宿主菜单图标同色；
- 点击时的身份校验链完整保留：账号、owner、菜单 generation、`activeItem`、
  receiver epoch（提交前再读一次）、以及 `GetMsg:LocalID:` 的第二来源回读。

## 2. 8.0.79 的关键事实（本机型实测）

- `MMMenuController` 不再暴露 `responder` 取值方法；观察报告里
  `responderSignature = <missing>`、`responder = <nil>`；
- 该对象仍有 `_responder @"UIResponder"` 这个实例变量，但点击阶段读到的值是 nil；
- 菜单数组在一次长按里会被多次重建（实测 3 次），每次重建都会调用 `setMenuItems:`；
- 因此点击阶段无法向宿主索取“当前是哪条消息”。

## 3. 现行取消息方式（已落地）

构建/显示时冻结：账号、owner、会话、localID、消息类型、创建时间、正文、epoch、generation。
点击时优先重新解析当前消息；解析不到则回退到**条目自身的冻结上下文**，并用
`GetMsg:LocalID:` 回读，逐项核对 localID、类型、创建时间、正文、方向/会话、账号，
再核对菜单 generation、开关、`activeItem` 与提交前 epoch。任一不符即拒绝。

已知取舍：菜单不重建时，点击旧项会保存该项冻结的那条消息，而不是“菜单此刻指向的消息”。
这是 8.0.79 不提供 responder 的必然结果；回读只能证明该消息仍存在且字段一致。

## 4. 遗留问题：Mikoto 的“小丑”出现两份

现象：长按菜单里 Mikoto 自己的条目（`action = pjItemView3:`，`target = MMMenuController`）
出现两次；我们自己的“存入同步库”始终只有一份。

证据（菜单观察日志，已脱敏）：一次长按内 `build` 3 次，`init` 4 次：
`MiYouJiaYi:` 1 次、`pjItemView3:` 2 次、`srMenuAction:` 1 次。

原因推断：Mikoto 挂在 `setMenuItems:` 上，每次调用无条件追加它自己的条目；
我们的条目在数组不可变时必须触发一次重建，于是它被多调用一次。
调用“安装时捕获的原始 IMP”也无法绕开，说明 Mikoto 比本插件更早安装
（`H -> M -> S`，我们捕获到的 `original` 其实是 M）。

已尝试：
1. 只在数组可变时原地修改 —— 宿主返回不可变副本时按钮消失，不可行；
2. 完全不再调用 setter —— 宿主用缓存数组时按钮消失，不可行；
3. 调用捕获的原始 IMP —— 仍会经过 Mikoto，重复依旧；
4. 重建前剔除 `pjItemView*` 条目、只调用一次下游 —— 已实现（提交 `5e37f29`），
   真机效果尚待确认。

## 5. 建议的后续修法（留给后续分析）

- 先修正幂等判断（记住最近发布的条目；同时接受 `target == hook && action == srMenuAction:`），
  避免把“数组副本里没有我们的条目”误判成需要重建；
- 当检测到 `pjItemView*` 条目且数组不可变、又无法证明捕获的 IMP 是宿主原实现时，
  不要主动调用任何 `setMenuItems:`，改为 fail-closed（保留设置页入口作为兜底），
  并在诊断里输出固定字段 `menuConflict=1`；
- 只有在能严格识别 Mikoto 条目（action、target 类、item 类三者同时匹配）并验证
  “最终 Mikoto 1 个 + 我们 1 个”之后，才启用“剔除后单次重建”的兼容路径；
- 不建议：依赖 tweak 加载顺序、用未知 ivar/KVC 改宿主缓存、hook 构造器吞并条目。

## 6. 复验步骤

1. 打开“菜单入库（长按文字）”；
2. 长按一条纯文字消息，点“存入同步库”；
3. 导出设置页 JSON，检查 `libraryMenu.hook.lastIntent` 是否为 0；
4. 到“消息库”确认条目存在、内容正确；
5. 再长按一次，确认“存入同步库”只出现一次、Mikoto 条目数量（记录即可）。

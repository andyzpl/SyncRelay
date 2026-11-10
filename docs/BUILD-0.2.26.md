# SyncRelay 0.2.26 UI 测试包

日期：2026-11-10。当前结论：本地回归、macOS 原生模拟、普通 DEB 构建与产物核验通过；未安装，未取得本版真机 UI 证据。

## 授权与范围

用户在四入口首页改动后同意「推送、测试，就文字图片」。本次仅提交/推送已讨论的首页、二级页、手动捕获选组/核对和主动收纳改动，保留已有文字/静态图片转发链路。没有安装、代替用户发送、迁移、清理设备数据，也没有开放持续监听、视频、自动接力或自动重发。

## 精确构建身份

- 分支：`codex/library-forward-dispatch-20261110`，没有合并到 main。
- 包源码提交：`ce4b0e9210cc9dc1ae049463a467f3dffee9022b`。
- 统一版本：`control` 和 `Core/SRVersion.h` 均为 `0.2.26`。
- [GitHub Actions 42833548877](https://github.com/andyzpl/SyncRelay/actions/runs/42833548877)，job `129889631701`，结论 `success`；显式 dispatch 一次，`build_deb=true`。
- [测试产物 13774060208](https://github.com/andyzpl/SyncRelay/actions/runs/42833548877/artifacts/13774060208)，名称 `SyncRelay-development-deb`，保留期 7 天。

后续本文件/证据回填提交不改变上述包源码身份；不能把最新文档提交称为 DEB 内编译的源码。

## 验证分层

1. 本地：完整 425 项 Python 契约通过；17 项 UI 聚焦契约连续三轮通过；4 个 C 回归程序通过；`arm64` / `arm64e` 各 65 个语法单元通过。
2. macOS：同一包源码的完整 425 项 Python 契约通过；原生清单编译 32 个目标，其中 28 个 Objective-C、4 个 C，按工作流配置执行 90 次；原生步骤成功，包含本轮新增分组池统计、确认后分组匹配和主动收纳阈值用例。Foundation/宿主模拟不是真实微信交互证据。
3. 生产构建/包：固定工具链构建普通 `iphoneos-arm` DEB，非 RootHide 转换包；CI 使用 `dpkg-deb` 检查 control、dylib/plist 路径，并用 `lipo` 核验 `arm64` / `arm64e`。
4. 下载后独立复核：ZIP 摘要与 GitHub artifact digest 相符；DEB 摘要与包内 `SHA256SUMS` 相符；解析 DEB control 和 fat Mach-O，两片架构均包含版本、源码完整 SHA、CI run ID、新首页四入口及捕获选组页标记。二进制标记只证明代码在包内，不证明视觉/交互正确。
5. 真机：尚未安装或验证本版。旧版 28 群图片成功只作为既有派发能力证据，不冒充本版 UI 已验收。

## 产物

- 本地目录：`dist/0.2.26-test-42833548877/`。
- DEB：`andyz.syncrelay_0.2.26_iphoneos-arm.deb`，559656 字节。
- DEB SHA-256：`4dad4bdab6ef71f46308afd44d96cba94c6b1310450b1f10a65eb9ade6be0594`。
- ZIP SHA-256：`2eb33a2ddcebb4eaf9d9d8f5a3f118e2d3b6f04a8db15030f94f178941f436b5`。
- 同目录保存 `ci-provenance.json`、`artifact-metadata.json`、`SHA256SUMS`、`DEVELOPMENT-NOTICE.txt` 和原始 ZIP。
- 本地日志：`.build-cache/ui-0.2.26-contract.log`、`.build-cache/ui-0.2.26-syntax.log`、`.build-cache/ui-0.2.26-ci-result.json`、`.build-cache/ui-0.2.26-ci-logs.zip`、`.build-cache/ui-0.2.26-native.log`、`.build-cache/ui-0.2.26-package.log`。

## 最小真机测试

先核对插件「设置 → 关于」显示 `0.2.26`；沿用已有安装方式，不需要卸载或清理数据库。

- 首页是四行纵向入口：群同步、消息库转发、群分组、设置；分别进入和返回，检查分组保存及未保存返回提示。来源未设也能进入消息库。
- 手动等待一条授权母群的新文字，再单独等待一张静态图片；悬浮提醒打开的是本条内容和冻结分组。选组/查看/取消不发送；最终明确点开始并确认后才发送。先使用小测试分组，不要求重复 28 群全量回归。
- 消息库如需回归，使用新存入的文字和静态图片，各走一遍现有手动转发；不要把原有相同版本/目标任务的幂等复用误认为创建了新任务。
- 胶囊普通停靠不缩小；向外推过阈值再松手，左右均能收纳为竖条，等待时显示「等待中」。点竖条只恢复小胶囊，不会开始、暂停或继续任务。
- 切后台后不自动继续发送；返回前台不自动开始捕获。出现异常时主动导出该版本脱敏诊断，并说明发生在哪一步；无需导出正文、群 ID 或图片路径。

本版并非整份 UI 规格验收：消息库三状态筛选/内容优先列表、无分组保存后回原消息/版本、单组名单就地编辑、结束摘要显式关闭等仍待后续；持续监听仍未接通。Windows 未做 iOS 渲染、独立视觉评审或触摸验证。

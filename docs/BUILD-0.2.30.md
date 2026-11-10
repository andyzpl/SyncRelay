# SyncRelay 0.2.30 消息详情视觉修正包

日期：2026-11-11。状态：源码已推送，macOS 原生回归、普通 DEB 构建及下载后独立核验通过；尚未安装，无本版 UIKit 实际运行证据。

## 范围

以用户最新指定的 1024 × 1536「消息详情」参考图为视觉基线：消息内容优先，两块白色分组，底部安全区上方固定蓝色「选择分组转发」按钮。编号、版本与历史移到更多菜单。目标行和按钮复用原选组与确认路径；没有改变发送、任务创建、coordinator、身份校验或新增图片读取。图片仍展示已有元信息，不伪装为已提供图片预览。

本版同时包含四张实机反馈图的修正：设置与群同步去掉常驻解释文字，保留当前值、捕获异常与未保存提示；关联三级页统一圆角分组；多行页脚自动高度，修正群分组底部提示挤入最后一行的问题。0.2.29 是补充参考到达前的中间构建，最终测试使用 0.2.30。

## 精确构建身份

- 分支：`codex/library-forward-dispatch-20261110`，没有合并 main。
- 包源码：`ec60e4b58046cf4c17566690283f68ec07611105`，版本 `0.2.30`。
- [Actions 42860698804](https://github.com/andyzpl/SyncRelay/actions/runs/42860698804)，job `129985716005`，success；显式 dispatch 一次。
- [产物 13786605116](https://github.com/andyzpl/SyncRelay/actions/runs/42860698804/artifacts/13786605116)，保留 7 天。

后续证据文档提交不改变上述二进制源码身份。

## 构建与下载核验

- 相同源码的 436 项 Python 与 macOS 原生回归通过；工作流配置 32 个原生编译目标（28 Objective-C、4 C），配置执行 90 次，不包含 UIKit 测试。
- 固定工具链普通 iphoneos-arm DEB 构建及 CI 内容检查通过；不是 RootHide 转换包。
- 下载 ZIP SHA-256 与 GitHub artifact digest 一致，DEB 摘要与包内 SHA256SUMS 一致。独立解析 control/plist 与双架构 Mach-O：两片均含精确版本、源码提交、run 和消息正文/目标行/底部按钮标识、当前版本/记录方法及既有导航/胶囊标记。二进制标记不是视觉或交互验收。
- 本地产物：`dist/0.2.30-test-42860698804/andyz.syncrelay_0.2.30_iphoneos-arm.deb`，575816 字节。
- DEB SHA-256：`dfdffc3b173beecfda3048c2bf02f32844c5593c12bd5586b47dca139322ee73`。
- ZIP SHA-256：`e75d353ac3ebb6e678d1631bdfcedcfbe4d2ce9b145205fd163e259f4844020b`。
- 同目录有 ZIP、SHA256SUMS、artifact-metadata.json、ci-provenance.json；CI 日志在 `.build-cache/ui-0.2.30-ci-result.json`、`ui-0.2.30-ci-logs.zip`、`ui-0.2.30-native.log`、`ui-0.2.30-package.log`。

## 本地验证与限制

- UI 聚焦 20 项、完整 436 项 Python 通过。
- arm64 / arm64e 各 68 个语法单元通过，包括 UIKit 原生测试源码。修正过已弃用的按钮内边距 API，采用 iOS 15 UIButtonConfiguration。
- 同一轮四个 C 回归通过；本次追加详情页只改 UI，未改 C 状态或几何代码。
- UIKit 夹具覆盖多行页脚布局、消息优先结构、底部按钮与滚动区不相交、失活隐藏、账号失败不读存储；不实现发送方法的存储/session 假对象保证开页测试不会派发。夹具未链接、未执行，不作为设备或模拟器验收。
- Windows 没有 iOS Simulator/UIKit，未生成修正后运行截图，未独立视觉评审；没有用网页或生成图代替实机图。参考原图保存在忽略目录 `.build-cache/ui-detail-20261111/message-detail-reference.png`。
- 日志：`.build-cache/ui-030-focused.log`、`ui-030-contract.log`、`ui-030-syntax.log`、`syntax-report.json`。

## 最小实机确认

1. 关于显示 0.2.30；使用消息库里已有文字打开详情，首先看到消息正文与来源/时间，而不是内部编号。
2. 两块白色圆角分组和底部蓝色按钮按指定参考图核对。长正文可滚动；按钮不覆盖内容；大字号时文字不截断。图片页只核对现有元信息，不为本轮视觉要求启动新的媒体验证。
3. 目标行与底部按钮打开相同的既有选择器，返回后沿用确认；可以取消，无需再次实际转发。更多里的版本/记录可查看并返回。
4. 设置和群同步的常驻解释文字已去除，实际转发间隔、捕获状态、异常及未保存提醒仍正确；群分组的小字在最后一行下方，不重叠。
5. 切后台后隐藏消息，回前台重新核对账号；详情、记录、设置等内页均可返回。

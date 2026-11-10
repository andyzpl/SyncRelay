# SyncRelay 0.2.27 UI 修正测试包

日期：2026-11-10。状态：已推送，macOS 原生回归、普通 DEB 构建及下载后独立核验全部通过；未安装，尚无本版 iOS 实际运行证据。

## 授权与范围

用户明确要求「推送打包 我实机体验」。本次在 `codex/library-forward-dispatch-20261110` 分支提交首页、设置代表页和悬浮形态修正及对应测试，以 0.2.26 为基线升为 0.2.27。安装及实机操作由用户完成；不改变发送逻辑、宿主 ABI、schema 或能力门禁，不开放持续监听、视频或新派发链路。详见 [首批视觉核对记录](UI-VISUAL-REVIEW-20261110.md)。

## 精确构建身份

- 分支：`codex/library-forward-dispatch-20261110`，没有合并到 main。
- 包源码提交：`ab8eef97d1e5f618692a1ef884a6bf933f249f0d`。
- `control` 与 `Core/SRVersion.h` 的版本均为 `0.2.27`。
- [GitHub Actions 42848233992](https://github.com/andyzpl/SyncRelay/actions/runs/42848233992)，job `129941458779`，结论 `success`；显式 dispatch 一次，`build_deb=true`。
- [产物 13780625033](https://github.com/andyzpl/SyncRelay/actions/runs/42848233992/artifacts/13780625033)，名称 `SyncRelay-development-deb`，保留期 7 天。

后续证据文档提交不改变包源码身份，不需要重复构建。

## 验证分层

- 本地：14 项 UI 聚焦 Python、430 项完整 Python、4 个 C 回归程序通过；arm64 / arm64e 各 66 个语法单元零诊断。
- macOS：同一源码完整 430 项 Python 通过；32 个原生编译目标（28 Objective-C、4 C）按工作流配置执行 90 次，全部成功。包含更新后的胶囊几何回归；Foundation/宿主模拟不是实际微信交互。
- 生产包：固定工具链构建普通 `iphoneos-arm` DEB，非 RootHide 转换包；CI 的 `dpkg-deb`、`lipo` 和内容路径核验通过。
- 下载后：ZIP SHA-256 与 GitHub artifact digest 相符，DEB SHA-256 与包内 SHA256SUMS 相符；独立解析 control 和 fat Mach-O，arm64 / arm64e 两片均含精确版本、提交、run ID、四入口和本轮新增的首页 cell、结果关闭/恢复等 UI 标记。标记仅证明代码在包内，不证明视觉及手势正确。
- UIKit：`tests/ios/SRFloatingProgressTests.m` 只有测试源码及语法检查，未链接/执行，不属于 macOS Foundation CI 清单。
- 真机：Windows 没有 iOS 运行环境，没有实际截图或手势验收。构建成功不代表视觉已验收，也不代表任务全部送达。

## 产物与日志

- 本地目录：`dist/0.2.27-test-42848233992/`。
- DEB：`andyz.syncrelay_0.2.27_iphoneos-arm.deb`，569428 字节。
- DEB SHA-256：`ea08997e149f7a30b1bca1f62cc8d897975749aee19f71248d975c79d03e5b17`。
- ZIP SHA-256：`8bd46d7cdc3647433870b6ed5e27125bccf1994ee78f997ee5fd0c46537c0916`。
- 同目录保存原始 ZIP、`SHA256SUMS`、`DEVELOPMENT-NOTICE.txt`、`artifact-metadata.json` 和 `ci-provenance.json`。
- 本地日志：`.build-cache/ui-0.2.27-contract.log`、`.build-cache/ui-0.2.27-ci-result.json`、`.build-cache/ui-0.2.27-ci-logs.zip`、`.build-cache/ui-0.2.27-native.log`、`.build-cache/ui-0.2.27-package.log`；本轮语法日志为 `.build-cache/ui-visual-syntax.log`、`.build-cache/syntax-report.json`。

## 最小实机核对

先从「设置 → 关于」确认版本 0.2.27。沿用已有安装方式，不要求卸载或清理数据库。

1. 首页四行高度、标题/副标题关系、白色列表宽度和圆角、图标对齐与下方留白；进入设置，检查三个分段及返回。
2. 快捷入口开启时，空闲 S 只打开入口；显式开始一个小范围测试任务后，完整胶囊的进度和暂停直接可见。
3. 普通拖到边缘保持完整；再向外推并松手，变成零缝隙深灰把手。两侧分别核对，右侧顶部为 ‹，下面正立竖排「转」「发」「中」。
4. 点把手或向内拉只恢复胶囊，不弹详情、不改变任务。贴边暂停和结束应原位换字；恢复后关闭结果才回到空闲 S（快捷入口关闭则隐藏）。
5. 检查返回手势、键盘及前后台；返回前台不自动启动捕获或发送。无需重复已有充分证据的 28 群派发。

首页和设置页仍需真实截图与原参考图并排核对；悬浮需要实际手势观察。第一批确认前不铺剩余页面。

# 0.2.27+aprobe.1 阶段 A 只读采样候选

日期：2026-10-23。状态：**单次 CI 已成功，普通 DEB 已下载并完成独立核验；用户已安装并完成第 3 轮停止快照，取得一条他人实时文字及实际 getter `I` 的有限观察证据；未执行数据迁移，图片就绪、本人延迟、离线同步和完整来源语义仍无真机结果。** 仅到本页限定的采样检查点，不表示阶段 A 整体验收。

## 精确身份与范围

- 基线：`f652d5e97180a15f43437fd1e449f3b3063e87fc`。
- 候选提交：`45c468418e0874bdece0dd39d2c52205d7521de6`。
- 源码树：`a59a3ac3b31fa7a74e32107d8bb932efdda7358e`。
- 独立分支：`codex/operations-a-device-probe-20261023`。
- 候选版本：`0.2.27+aprobe.1`；包 ID 沿用 `andyz.syncrelay`，目标为普通 `iphoneos-arm` DEB、arm64/arm64e。
- [CI 39815504152](https://github.com/andyzpl/SyncRelay/actions/runs/39815504152)：`workflow_dispatch`、`build_deb=true`，仅派发一次。先跑测试，成功才进入打包；失败不交付包，不自动重跑相同源码。

源码组合为上轮已固定的 42 个工程文件、6 个文档，以及隔离版本/control/工作流 notice 的按行调整，相对基线共 50 个变更文件。没有改变主工作区版本文件、HEAD 或真实 index。新增的工作区 `.workbuddy`、诊断、素材、第三方包、`.build-cache` 和 `dist` 均未加入变更；基线已经跟踪的记忆文件保持原 blob，没有新上传其修改。

精确候选在提交前已通过本地 160 项 Python；这不是 Objective-C 编译/执行或真机证据。主工作区文件字节、完整 status 和 index 摘要已在提交前后核对一致。

本地执行记录：`.build-cache/takeover-20261023/request.json`、`candidate-manifest.json`、`protection.json`、`snapshot-python.log`、`status.json`、`job-119952916546.log`、`verification.json` 和 `artifact.zip`。原始构建身份及证据不因后续本地文档回填而改写。

## 实际结果与产物

| 项目 | 结果 |
| --- | --- |
| CI / job | `39815504152` / `119952916546`，success，run attempt 1 |
| 环境 | macos-15-intel，实际 macOS 15.7.9 |
| 原生测试时间 | 北京时间 2026-10-23 00:37:22–00:41:55 |
| Python | 精确隔离候选本地及 CI 均为 160 项通过 |
| Objective-C | 22 个程序编译、链接后各执行三轮，共 66 次；新增只读 probe 用例三轮通过 |
| C | media-quota 程序三轮，pacing / operations-state 各一次，共 5 次 |
| 执行总数 | 25 个程序合计 71 次；112 条 PASS 输出包含分项与重复，不是 112 个程序 |
| 打包 | 五个打包/上传步骤全部成功，生产源码含 UI 在 arm64/arm64e 上实际编译、链接；没有单独重跑相同源码的测试 CI |
| Artifact | `12441329181`，`SyncRelay-development-deb`，1 个 |
| 包文件 | `dist/0.2.27+aprobe.1-test-39815504152/andyz.syncrelay_0.2.27+aprobe.1_iphoneos-arm.deb` |
| 包字节数 | `365180` |
| DEB SHA-256 | `c7864dca3f3f8c5dc58819621583444e66ff12b0319efe1367323d7fa197f07e` |
| Artifact ZIP SHA-256 | `95f1e4c82248b93416aac9b057003103c1621097e2c91b300c31e257abeb71cf` |

下载后核对：GitHub artifact digest、包摘要与 SHA256SUMS、control 的包 ID/版本/架构/依赖、全部载荷只含 dylib/plist、注入过滤仅为 `com.tencent.xin`、无安装脚本。两架构分别核对完整提交/run/版本、更新后的中文采样入口、`hookSamples` / `actualGetterEncoding` 等新字段及 schema 14 库表标记；Mach-O 架构、边界、系统依赖、安装路径、最低 iOS 15.0 与 SDK 15.6 符合预期。仅核对签名载荷存在，未作密码学签名/设备信任或安装兼容验证。

产物目录另有 `DEVELOPMENT-NOTICE.txt`、`SHA256SUMS` 和本地 `ci-provenance.json`。保存后再次独立回读核对包字节、SHA-256 与 provenance 一致。**工程结果仍是模拟对象执行和生产编译，不是真实微信 ABI/时间语义认证，也不是真机结果。**

## 产品与设备边界

本包目标仅为显式启动、有界、可停止的文字交付及文字/图片早期 hook 元数据采样。可观察实际消息对象的 getter 声明，但不能把观察位当认证位；`sourceTimeSemanticsVerified=false`、`imageReadinessObserved=false`。

不准备/下载图片，不创建内容、计划、run 或 claim，不由探针发送。原手动发送能力在采样之外仍存在，不得用其测试来源时间。自动捕获、新胶囊/库 UI、库内容派发和视频不开放。仍缺图片被动资源就绪入口及全部真实来源时间证据，阶段 A 不标整体验收。

schema 为 14。与 schema 11 旧专项包不是可互换构建；在旧设备库上启动会执行现有迁移，需另获设备数据迁移授权。**本次授权不包含安装、RootHide 转换、设备迁移或数据清理。** 先核对设备当前构建、schema、包环境和重要待继续任务，不清库、不降 user_version，不把版本号较高当功能超集。

设备操作和逐项证据判据见 `OPERATIONS-A-DEVICE-READINESS.md`。首份诊断已确认当前手机为该普通 DEB 的 `0.2.27+aprobe.1`、微信 8.0.79.35、`storageReady=1`，且没有采样活动；下一步可直接按设备清单操作，不要安装旧 `timeprobe.1` 包。任何后续覆盖安装、RootHide 转换或 schema 11→14 数据迁移仍需另行明确授权；准备文档和本页结果回填仅为本地修改，不为文档再次构建相同生产源码。

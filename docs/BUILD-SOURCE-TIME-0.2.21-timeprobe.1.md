# 0.2.21+timeprobe.1 文字来源时间专项包

> 2026-10-23：本页保留旧包构建证据，不是当前安装建议。该包仅支持 schema 11，当前开发源码为 schema 14，不能用它验证或回退当前库。新候选 `0.2.27+aprobe.1` 已完成工程测试、构建与下载核验，见 `BUILD-0.2.27-aprobe.1.md`；安装/迁移仍未授权，无真机结果，设备步骤见 `OPERATIONS-A-DEVICE-READINESS.md`。

日期：2026-10-22。状态：**普通 DEB 已构建、下载并离线复核，已到文字子集真机采样节点；尚未安装或取得真机结果，不代表阶段 A 整体验收。**

本包只用于来源时间采样，不测试运营胶囊或完整运营流程，不开放自动捕获。图片、实际消息对象逐对象 ABI、被 receiver 提前过滤的回调仍不在本包观察范围内。真机步骤和完整待验矩阵见 `docs/OPERATIONS-SOURCE-TIME-DEVICE-CHECK.md`。

## 构建身份

| 项目 | 值 |
| --- | --- |
| 插件版本 | `0.2.21+timeprobe.1`，独立专项后缀，不占用并行消息类型的 0.2.22–0.2.24 版本线 |
| 包 ID / 架构 | `andyz.syncrelay` / `iphoneos-arm`；实际二进制含 arm64、arm64e |
| 独立分支 | `codex/operations-source-time-device-20261022` |
| 精确提交 | `c9be95413384e30416abdc356505295a947ac9df` |
| 源码树 | `cb9ee97554f08e3442e30982bba08e7b800c1692` |
| 已验证父提交 | `91b310d84129aa42ce2ea292ca5d846f0a5200c0` |
| CI | [39730283085](https://github.com/andyzpl/SyncRelay/actions/runs/39730283085)，job `119663509751`，`success` |
| Artifact | `12405590075`，`SyncRelay-development-deb` |
| 包文件 | `dist/0.2.21+timeprobe.1-test-39730283085/andyz.syncrelay_0.2.21+timeprobe.1_iphoneos-arm.deb` |
| 字节数 | `316044` |
| DEB SHA-256 | `34dfdb48d37e29af85da75c015e5dac3a0145f3431826be6a4387aacbbf7416c` |
| Artifact ZIP SHA-256 | `1ce56b1bc8cd70009cd8ca828d737445faa51c80d962d5d798ca39d58bfac4e3` |

本次只触发一次 `build_deb=true`，没有重跑或以旧包代替。相对已验证父提交，仅覆盖 `Core/SRVersion.h`、`control` 的版本/范围说明，以及工作流产物的 `DEVELOPMENT-NOTICE.txt` 文案；生产逻辑和测试源码不变。仍在新提交上完整执行原生回归后才打包，不单凭父提交通过就宣称新产物通过。

使用独立 Git index/快照，不移动工作区 main 的 HEAD 或真实暂存区，不改工作区版本文件。不包含并行类型适配的未提交变更，也不修改其分支或工作树。没有新增上传个人诊断、第三方包或私有文件；基线历史已跟踪的 `.workbuddy/memory/2026-10-21.md` 保持原 blob，不在本轮新增变更中。

## 已通过的工程验证

- 隔离快照本地与 CI 均通过 92 项 Python；完整工作区通过 102 项，差额 10 项为刻意未纳入的并行类型测试。
- CI 实际编译、链接 19 个 Objective-C 程序，并各执行三轮，共 57 次；文字只读采样及同步通知重开用例包含在内。
- 两个 C 程序在本机及 CI 均编译执行通过。CI 的 94 条 PASS 日志包含重复/分项输出，不是 94 个独立程序。
- 精确打包快照的 arm64/arm64e 共 98 个语法编译单元通过、零诊断；macOS 模拟回归不代表 UIKit 或微信真机行为。
- 普通 DEB 构建和五个打包/上传步骤均成功。下载后核对 ZIP digest、DEB SHA-256、control 身份、完整载荷集合、微信 `com.tencent.xin` 注入过滤；无安装脚本。
- 两架构的版本、完整提交、run ID、采样类/诊断字段及中文采样入口均匹配。最低 iOS 15.0、SDK 15.6；dylib 安装路径和依赖均为预期系统路径。仅核对签名载荷存在，不宣称设备信任或安装兼容已验证。

包中只有 `Library/MobileSubstrate/DynamicLibraries/SyncRelay.dylib` 与对应 plist。产物目录同时保留 `SHA256SUMS`、`DEVELOPMENT-NOTICE.txt` 和本地 `ci-provenance.json`。

本地证据在 `.build-cache/operations-source-time-package/`：`request.json`、`status.json`、`job-119663509751.log`、`verification.json`、`schema-compatibility.json`、`artifact.zip`、精确快照和 `syntax.log`。这些构建证据不含 GitHub 凭据，也不含手机诊断。

## 安装与版本切换边界

1. 这是普通 DEB，**不是 RootHide 转换包**。仅在已确认支持这种包的原测试环境使用；若现有环境要求 RootHide 转换，不直接安装、不改名冒充转换完成。
2. 与现有插件使用相同包 ID，安装会替换现有插件，不能并装。版本后缀用于区分专项，不代表包含 0.2.22/0.2.23/0.2.24 的链接、文件或更多消息类型功能，也不建议把它设为日常升级包。
3. 源码已核对 `f652d5e...`（0.2.21）、`7eb9360...`（0.2.22）、`4169afa...`（0.2.23）的数据库初始化/迁移及配置校验契约与本包一致，均为 schema 11。**这是已提交源码的契约比较，不是真机升级/降级验收。** 未核验未发布的 0.2.24、其他同版本构建或后续版本；若手机已装这些包，先提供插件版本/构建号，暂不覆盖或强制降级。
4. 只在没有需要保留的活动捕获/预览或发送任务时安排本轮。若有重要暂停任务，不为采样而取消、清数据库、删除历史或清 claims。不要卸载清数据后重装来绕过兼容检查。
5. 本包沿用 schema 11；旧库可能在插件初始化时正常迁移。**“采样只读”仅指采样模块不创建内容/计划/run/claim，不表示整个插件不做数据库初始化、配置保存或日志写入。** 不盲目回退到不能读取 schema 11 的旧包，尤其不能靠清除防重记录回退。

## 本轮开放与不开放

入口：我 → 设置 → SyncRelay 转发 → 更多设置 → **来源时间只读采样（文字）**。

采样默认关闭，明确开始，每轮最多 16 个已交付文字回调或 120 秒；关闭设置页可继续，后台/锁屏/失去前台即停止，回前台不自动重开。账号/配置失效会清空证据；新轮会替换旧轮，退出进程不会保留，需先手动导出。

采样不生成预览/内容/计划/run/claim，不调用发送 API，不准备图片；与捕获和发送实验互斥。既有手动 1–20 群发送仍存在于采样之外，**本次不要使用它来验证时间字段**，也不要把整个插件称为“完全不能发送”。

`sourceTimeSemanticsVerified`、`actualWrapABIObserved`、`imageReadinessObserved`、`prefilteredCallbacksObserved` 均保持 false；观察到样本或本地策略通过不会改变这些能力位。阶段 A 未整体验收，B/C/D 不开放。主动重发、目标级去重、人工排除、新群自动入组、免密码备份恢复继续按 v2 阶段 C 保留，不因本阶段包删减需求。

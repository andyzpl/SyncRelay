# 0.2.27+aprobe.2 阶段 A 页面切换修复候选

日期：2026-10-23。状态：**单次 CI 成功，普通 DEB 已下载并完成独立核验；用户随后安装并导出八份只读采样诊断，未取得数据库迁移过程证据。** 本候选只验证页面切换期间来源时间只读采样的生命周期修复，不表示真实微信来源时间语义、图片就绪或阶段 A 整体验收通过。

## 精确身份

- 候选提交：`51803d43fe068d16c462cea0729264a26cf5f2f5`。
- 独立分支：`codex/operations-a-device-probe-20261023-aprobe2`。
- 插件版本：`0.2.27+aprobe.2`；包 ID `andyz.syncrelay`；普通 `iphoneos-arm` DEB，含 arm64/arm64e。
- schema：14；未修改迁移 SQL、receiver ABI、发送核心、消息库派发或视频能力。
- CI：[39920510733](https://github.com/andyzpl/SyncRelay/actions/runs/39920510733)，`workflow_dispatch`、`build_deb=true`，本次仅派发一次。

本候选相对 `.1` 的生产逻辑变更仅为 `UI/SRPanel.m` 的采样生命周期修复：采样 active 后不再依赖设置面板对象或 `panelIdle`，微信内页面切换及短暂 inactive 不会触发停止；真正进入后台仍停止。另更新来源时间契约测试、版本/control 和本地设备说明。主工作区 HEAD、暂存区及用户已有未提交改动未被覆盖。

## CI 与产物核验

| 项目 | 结果 |
| --- | --- |
| Job | `120304330942`，success，macos-15-intel |
| Python | 精确 `160` 项通过 |
| 原生/生产 | 25 个程序编译/链接；pacing 与 operations-state 各执行 1 次，其余 23 个各执行 3 轮，共 71 次；双架构生产编译链接与验证步骤均成功。日志 `112` 条 `PASS:` 为分项输出，不是程序数 |
| Artifact | `12485999082`，`SyncRelay-development-deb` |
| 包文件 | `dist/0.2.27+aprobe.2-test-39920510733/andyz.syncrelay_0.2.27+aprobe.2_iphoneos-arm.deb` |
| 包字节数 | `366144` |
| DEB SHA-256 | `82c8ad39f17cac7d8373f6fdbea8444537bb2d4cd0b86742ad204a5b640d24c6` |
| Artifact ZIP SHA-256 | `063f3d260e3e94cdef0dcf77736697d247d55c7c6be85a05b417292c16a14b05` |

下载后独立核对通过：artifact digest 与 `SHA256SUMS`、control 的包 ID/版本/架构、载荷仅含 dylib/plist、注入过滤仅为 `com.tencent.xin`、无安装脚本、Mach-O arm64/arm64e 两切片、系统依赖和签名载荷存在。`DEVELOPMENT-NOTICE.txt` 明确采样上限、显式启停、后台停止和 schema 14 边界。证据保存在 `.build-cache/aprobe2/verification.json`、`.build-cache/aprobe2/artifact.zip` 及产物目录的 `ci-provenance.json`。

## 使用边界

本包仍只开放显式启动、有界、可停止的文字交付及文字/图片早期 hook 元数据采样；不准备或下载图片，不创建内容、计划、run、claim，不发送，不自动捕获。`sourceTimeSemanticsVerified=false`、`imageReadinessObserved=false` 保持不变。消息库 UI、库内容派发、视频和 B/C 功能均未开放。

设备已安装该精确 `.2` 并导出八份诊断：本人/他人实时文字各 3 条，后台轮次为 `inactive`；离线最终轮同时出现旧消息 `older_than_boundary/strict=0` 和新消息 `after_boundary/strict=1`，停止后两类样本均保留；图片轮取得 1 条 type 3 早期 hook，且 `imageReads=0`；最新本人轮只有正常有 server ID 的回调，未取得延迟补 ID 证据。页面切换没有成对前后快照，故只记为有限支持证据。RootHide 转换、再次迁移或数据清理均不在本次范围。CI/DEB 通过和这组有限真机证据都不等于完整来源时间语义或阶段 A 整体验收。

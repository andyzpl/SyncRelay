# SyncRelay 0.2.28 实机反馈修正包

日期：2026-11-11。状态：已推送，macOS 原生回归、普通 DEB 构建和下载后独立核验通过；未安装，无本版 UIKit 实际运行证据。

## 范围

延续上一轮推送打包授权，修正用户实机反馈的空闲快捷入口、页面视觉和二级页返回。空闲改为「同步」短胶囊；插件内页使用自有返回动作和保留 dirty 确认的侧滑；群同步/分组/消息库列表改圆角分组，清理列表内部字段。详情见 [UI-NOTES.md](UI-NOTES.md)。没有安装或代替用户操作设备，没有修改业务状态、发送逻辑、ABI 或开放新能力。

## 精确构建身份

- 分支：`codex/library-forward-dispatch-20261110`，没有合并到 main。
- 包源码：`a47422ed9227278a8ad86049bff0ba41251542c6`，版本 `0.2.28`。
- [Actions 42853360406](https://github.com/andyzpl/SyncRelay/actions/runs/42853360406)，job `129959724285`，结论 success；显式 dispatch 一次。
- [产物 13783020901](https://github.com/andyzpl/SyncRelay/actions/runs/42853360406/artifacts/13783020901)，保留 7 天。

后续证据文档提交不改变上述二进制源码身份。

## 验证

- 本地 17 项 UI 聚焦、完整 433 项 Python、4 个 C 回归通过；arm64 / arm64e 各 68 个语法单元通过。
- UIKit 测试源码覆盖四入口返回、设置内层返回、dirty 按钮/侧滑确认、根页及旧页回调保护；本机不能链接/运行 UIKit。
- 同一源码 macOS：433 项 Python、32 个原生编译目标（28 Objective-C、4 C）及配置执行 90 次通过；不包含 UIKit 测试。
- 生产包：固定工具链普通 iphoneos-arm DEB（非 RootHide 转换包）构建及 CI 包内容检查通过。下载 ZIP 摘要与 GitHub artifact digest 一致；DEB 摘要与包内 SHA256SUMS 一致。独立解析 control 和 Mach-O，arm64/arm64e 两片均含精确版本、提交、run、新导航类/返回与 dirty 协议方法，以及既有首页/胶囊标记。标记不证明实际视觉/手势正确。
- 用户提供的四张实机图是修正前基线，不作为本版运行图。不宣称已经像素还原或返回实机验收通过。

## 本地产物与证据

- `dist/0.2.28-test-42853360406/andyz.syncrelay_0.2.28_iphoneos-arm.deb`，566822 字节。
- DEB SHA-256：`4a14739a5754fd6ffa34cffd25fa0d4e745babc5ace49403fafcdf8b404836c8`。
- ZIP SHA-256：`b9e68337cfe37b2c0290a61ac9ea79383bbce62bc1069feda67ad922f5bd7984`。
- 同目录有 ZIP、SHA256SUMS、artifact-metadata.json 和 ci-provenance.json。
- 日志：`.build-cache/ui-return-focused.log`、`ui-return-contract.log`、`ui-return-syntax.log`、`syntax-report.json`；本次 CI 的 `ui-0.2.28-ci-result.json`、`ui-0.2.28-ci-logs.zip`、`ui-0.2.28-native.log`、`ui-0.2.28-package.log`。
- `.build-cache/ui-device-20261111/comparison.html` 将原图与用户四张实际截图同宽并排，仅为修正前差距基线，不是新版运行图；没有拉伸或生成图替代。

## 最小实机确认

1. 关于显示 0.2.28；空闲为写着「同步」的短胶囊，点击只打开首页。
2. 首页四入口逐个进入，点左上箭头回主菜单；设置进入资源/诊断/关于后，先返回设置，再返回首页。选群页的批量菜单仍在。
3. 未修改时可以侧滑返回。改了未保存的来源/分组后，按钮和侧滑均先提示；点继续编辑留在原页，点放弃返回。保存后返回再进入核对配置。
4. 群同步、消息库和群分组的白色列表应左右留边并带圆角；分组分段不贴边，设置入库说明不挤在右侧。与原参考图继续对照，拍修正后实际图。
5. 原转发胶囊、主动外推把手和点/向内拉回保持；贴边暂停/结束不弹出。无需重复已有充分证据的全量派发测试。

# SyncRelay

微信母群消息手动分批转发插件，目标环境 iOS 16.0.3、微信 8.0.76 / 8.0.79。

## 当前状态：0.2.5 方向字段诊断，已打包待定点手机重测

0.2.4 手机报告已确认 iOS 16.0.3、微信 8.0.79.35 上保存后可以开始等待，两个消息入口均被观察到，但所选母群会话的回调被 from/to 方向检查拒绝，未进入规范化候选。该报告不能确定具体字段值或哪个字段不匹配，也不能证明既有规则下的母群切换已验收。

0.2.5 为同一次等待中最多 12 次母群会话回调补充宿主原方法执行前/后的脱敏方向证据：字符串读取状态、账号/来源群的相等关系、消息类分类、消息类型。只记录布尔值/数字，不读正文、不导出原始 ID，不放宽原有捕获校验，也不自动采用调用前的数据。证据仅在内存，需失败当次导出；步骤见 `docs/DEVICE-CHECK-0.2.5.md`。普通包已构建核验，不宣称已修复抓取或手机兼容。

本轮普通 DEB：`dist/0.2.5-test-39461950419/andyz.syncrelay_0.2.5_iphoneos-arm.deb`，157802 字节；编译源码 `bcbc987f14af491156795325d5bdb95992dc124a`，后续文档提交不改变包身份。本地 54 项双架构语法与 9 项 Python 测试、[私有 Actions 39461950419](https://github.com/andyzpl/SyncRelay/actions/runs/39461950419) 的 28 条核心 PASS 及 9 项 Python 测试、普通包构建/上传通过。下载后核验哈希、包身份/载荷、两个 slice 的编译身份/方向诊断标记/签名载荷、系统依赖及微信主进程过滤。SHA-256：`e64d9d707acfb3c011a17b9b9e80da7695a118833134d3b5c8f1f607817b36ee`。同目录含来源清单与 `PHONE-TEST.md`；未做 0.2.5 手机验证，真实转发仍关闭。

### 0.2.4 历史测试包与实现

用户反馈更换母群后不能开始等待，以及已等待但抓不到消息。0.2.4 更换母群不再清空全部目标规则，仅移除新母群及空规则；来源成员仍需重新选择并保存。缺账号/母群/来源成员/目标规则分别给出具体原因。

新增可查看、复制、手动导出的 JSON 运行报告、最多 300 条脱敏持久事件、回调分支计数和构建身份。默认不导出草稿本体、原始 wxid、群 ID或正文，也不自动上传。维护流程见 `docs/RUNTIME-DIAGNOSTICS.md`；手机步骤见 `docs/DEVICE-CHECK-0.2.4.md`。抓取失败仍需新报告定位，不能宣称已经修复。

本轮同时按用户指定的微信/Mikoto 原生列表方向收拢样式：紧凑导航、通栏 grouped 列表、左名称/右当前值、诊断下移，群/成员仍显示原始 ID。没有 iPhone/模拟器画面，未验证实际视觉；发送仍未启用。

本轮 0.2.4 普通 DEB：`dist/0.2.4-test-39458985577/andyz.syncrelay_0.2.4_iphoneos-arm.deb`，151916 字节，编译源码 `14e634fa32f39d0a3cad7698fedaf55b4dc1b70f`（后续文档提交不改变包内身份）。本地 arm64/arm64e 共 54 项语法检查、5 项 Python 诊断解析测试，以及[私有 Actions 39458985577](https://github.com/andyzpl/SyncRelay/actions/runs/39458985577) 的 28 条核心 PASS、5 项 Python 测试、普通 DEB 构建和下载后核验通过。SHA-256：`cdece7971eefd6e65666ee5c184a434a70234478287557147341babd4f5309f6`。两个 slice 均含确切提交/run，只有自身 dylib/plist、微信主进程过滤和系统依赖，签名载荷存在。手机步骤同目录 `PHONE-TEST.md`；尚未验证实际捕获、分享、原生样式或两版兼容，真实转发仍关闭。

0.2.3 提供明确的“我（当前登录账号）”来源选项，移除禁止本人作为唯一来源的限制；母群从手动排除列表隐藏并明确标为自动排除，生成/保存时的母群目标保护保持不变。本人文字通过原发送链之后的只读观察及可选精确 ID 回读取得服务器 ID；不扫描历史、不调用发送接口。尚未真机验证，步骤见 `docs/DEVICE-CHECK-0.2.3.md`。

历史 0.2.3 普通 DEB：`dist/0.2.3-test-39454590524/andyz.syncrelay_0.2.3_iphoneos-arm.deb`，140428 字节，源码 `0956862a59e5c6d299df6528a6134e4c80f0dc15`。本地 arm64/arm64e 共 50 项语法检查、[私有 Actions 39454590524](https://github.com/andyzpl/SyncRelay/actions/runs/39454590524) 的 25 条 PASS、普通 DEB 构建及下载后核验通过。SHA-256：`c445d3e8a757930be7b2a5a8aa10c3caf75c74a08a99538aee67a1aaa04323c2`。仅自身 dylib/plist、仅微信主进程过滤、双架构且只有系统依赖；未验证手机运行，不会自动转发。

不是可用的群转发成品，真实转发仍未启用。新版主入口为「我 → 设置 → SyncRelay 转发」，不再强制显示悬浮按钮。面板内“开启悬浮入口”默认关闭，独立保存开关，打开后才显示“同步／预览／观察”（预览优先）；关闭立即移除，重启保持选择。
成员读取、手动文字接收和发送观察均为带签名检查的候选适配，尚未在两版微信上真机验证；接口不匹配会停止并提示诊断。
0.2.1 已收到手机反馈：「我 → 设置」找不到入口，不能再把其模拟测试通过当成宿主适配通过。离线核对 Mikoto 的宿主路径后，0.2.2 补充 `m_tableViewMgr` / `WCTableViewNormalCellManager`，保留旧版表路径；增加页面加载/出现及安装较晚时的刷新。原生私有表不匹配时，只在设置列表底部保留同名可点击入口，不强制悬浮、不接管微信的表代理。存储失败也可进入诊断，规则操作停用。实现/证据边界见 `docs/GROUPS-AND-SETTINGS.md`，重测步骤见 `docs/DEVICE-CHECK-0.2.2.md`。尚无手机通过结论。

历史 0.2.2 普通 DEB：`dist/0.2.2-test-39450276375/andyz.syncrelay_0.2.2_iphoneos-arm.deb`，132424 字节，源码 `bdc418c494ae1c76041fe0d3727afcbbddf0b4c1`。本地 arm64/arm64e 语法共 50 项、[私有 Actions 39450276375](https://github.com/andyzpl/SyncRelay/actions/runs/39450276375) 的 25 条 PASS、普通包构建与校验/上传通过。下载后再次核对清单、注入过滤、双架构及签名载荷、系统依赖和包哈希：`74723dc097ed2f8fab9d5f2ed59f78103366fd9fc239020559b65780ed35139b`。这不是设置入口真机通过或两版微信兼容的证明，也不包含 0.2.3 本人来源修正。

历史 0.2.1 包：`dist/0.2.1-test-39441160370/andyz.syncrelay_0.2.1_iphoneos-arm.deb`，源码 `d87cd4a`。48 项语法、[私有 Actions](https://github.com/andyzpl/SyncRelay/actions/runs/39441160370) 25 条 PASS 和包校验通过；126876 字节，SHA-256 `c9af1bb7698002508cb48e67ba3650a2a564e5dcd770d85028582833e62714fb`。该包入口在用户设备未出现，不能重新交付同一包作为修正版。

首轮 0.2.0 用户反馈只返回 4 个普通群；旧包不会自动具有本轮修正。0.2.1 在原联系人接口之外补充本地会话用户名，按群 ID 合并，并展示脱敏来源计数；真实覆盖范围仍需手机核对，不把本地候选当成全部已加入群。

已编写母群选择、成员原始 wxid 显示/多选、文字/图片开关、随机间隔编辑、排除群搜索与批量操作、100/200 群自动分规则、分组去重与按账号保存草稿。
保存草稿不会创建发送批次；手动捕获后的确认只建立内容计划，也不会发送。没有可用的开始/继续/重新执行按钮。草稿与已确认计划、运行记录分离，保留旧执行历史。

## 单条源消息与历史

1. 保存统一条件和规则后，手动点击“等待一条母群文字”；接收入口不会在启动时安装，只有这次操作通过签名及账号检查后才挂接候选。
2. 可关闭面板回母群，由已选择的成员（含本人）发一条文字。候选核对会话/来源群、当前账号、原始发送者、消息类型和非零服务器 ID；不按昵称或正文猜身份，不回退临时本地 ID。本人路径可以按刚观察到的精确 local ID 回读，不能扫描历史。
3. 第一条匹配后停止等待，在“单条源消息预览”核对完整正文、群 ID、wxid 和冻结配置；可放弃，确认则事务性建立全部规则，绝不开始发送。
4. 修改等待中的草稿、离开前台或账号变化会取消等待；回前台不自动重新等待。预览只是内存数据，进程退出后需重新捕获；确认后的计划可重开读取。
5. “已确认内容计划与历史”分页查看计划、规则状态、批次和异常群。完成时间读取原有结束时间，不用打开页面时间；只显示异常群细节，不逐条刷出成功记录。

当前候选处理其他成员与本人的文字，未开放图片/媒体或接收历史扫描。回调是否包含离线补同步、正文是否带群消息前缀、服务器 ID 字段及精确回读是否稳定，均需真机核对；不能把签名检查通过当作兼容性证明。真实转发接入前仍须补充本插件发送消息的回环过滤。
细节与证据边界见 `docs/RECEIVE-CANDIDATE.md`。

## 原包研究与手动发送观察

已继续分析用户提供的 MikotoHelper DEB：限定离线 ARM64 模型还原 `PJTransmitModel` 的 12 次及 `PJHelper` 元类的 224 次业务方法注册，核对一个普通文字路径的 `MMContext -> CMessageMgr -> AddMsg:MsgWrap:` 调用点。不是只搜选择器，也不是完整源码还原；输入哈希、原始地址和模型边界见 `docs/MIKOTO-SEND-EVIDENCE.md`。

新增“只读观察一次手动文字发送”：手动选择一个授权测试群，关闭面板后在 120 秒内由用户用微信正常发送一条普通文字。观察原链之后的元数据及精确本地 ID 读取，保留原始状态码；不读正文、不代发、不写投递成功。切后台、锁屏、账号变化或期限到达后停止，不自动重开。报告在“查看适配诊断”中复制，不含账号/群/消息 ID。

已找到的一个 `MessageReturn:MessageInfo:Event:` hook 的附加逻辑调用 `changeHeaderFinish`，不能把它误当成已验证的文字发送回执；发送观察不 hook 此入口，也不把服务器 ID 或状态数字直接解释为成功。细节见 `docs/SEND-PROBE.md`。

当前优先修正 0.2.1 手机缺失入口，群来源合并维持不变；入口恢复后再核对是否仍只返回 4 群。本轮不做 100/200 群实发测试。

旧 0.2.0 包记录：功能/测试源码 `201bbd4`，打包提交 `c9bec6e`。本地语法 42 项和[私有 Actions](https://github.com/andyzpl/SyncRelay/actions/runs/39434037504) 22 条 PASS；文件 117410 字节，SHA-256 为 `adf7853d7aa0b3141044e1236d21189faa698de5b6ec5cdd0f1c7ca284142461`。后续收到只返回 4 个普通群的反馈，不将旧测试结果视为群读取完整性证明。

## 自动分组

1. 统一设置一次母群、来源成员 wxid、文字/图片类型和间隔；所有草稿规则共用这些条件，不需重复设置。
2. 在“搜索并排除群聊”勾选不想转发的群；可按名称/原始 ID 搜索，并批量排除或恢复搜索结果。取消全部排除也可保存。
3. “自动分配规则”填写每条 100 群、200 群各生成几条。例如 10 + 10：最多新增 20 条规则、3000 群；先分 100 群规则，再分 200 群规则。
4. 预览实际可分配数、生成条数、缺口和剩余，再确认生成。群不足不报错中止：最后一条按实际数量，后续不建空规则。已有规则保留并自动去重。
5. 生成仅修改草稿，需“保存草稿”才能持久化；不会捕获或发送。未来执行仍需逐条手动开始，绝不自动接力。

候选群池不写死为 3000；当前使用 12345 个模拟群测试读取、搜索和分配。实际能读取多少受微信接口、本地群记录、设备资源影响，尚未真机验证完整性。
手动选择是可选入口，全选目标也自动拆成每条不超过 200 群；100/200 是本轮分组规格，不是底层存储的全局上限。
更改排除项会先提示从已有草稿规则移除的目标及空规则，不自动补齐或重排其他规则；不会更改已创建的计划/执行历史。临时未被接口列出的排除 ID 仍保留在排除页。
随机节拍和小批次不构成平台限制规避或必达承诺。

旧版设备清单保留于 `docs/DEVICE-CHECK-0.2.0.md`。历次构建结果、产物与 SHA-256 见开发进度文档。

已编写的模块：

- `Core/SRStore.m`：计划、互斥分组、独立执行批次、持久化状态、暂停/恢复、重新执行、结果关联。
- `Core/SRPacing.c`：至少 10 秒的随机节拍计算，单调时钟输入，恢复时不补发错过节拍。
- `Core/SRConfiguration.m`、`Core/SRSelection.m`：草稿校验、完整列表批量选择、来源群与重复目标排除。
- `Core/SRGroupPlanner.m`：共享条件、按配额自动分组、不足额预览和持久化排除的候选草稿生成，不触发发送。
- `Core/SRSourceCapture.m`、`Core/SRSourceMessage.m`：规范化消息过滤、单条预览冻结和确认后原子创建计划；已连接手动文字接收候选，尚待真机验证。
- `Core/SRRunner.m`：串行派发、账号互斥、节拍和超时核对核心；仅使用测试发送器验证，启动时不会运行它。
- `Adapter/`：运行时签名检查、只读联系人/成员候选接口、脱敏诊断；没有主动发送 API。
- `Adapter/SRWeChatReceiver.m`：手动文字接收候选，保留原接收链，只向内存捕获器提供核对后的规范化数据。
- `Adapter/SRWeChatSendProbe.m`：最长 120 秒的单群手动文字发送观察，保留原链、精确 ID 关联、有限脱敏样本，不读正文或推断送达。
- `Adapter/SRWeChatSettingsEntry.m`、`Core/SREntryPreferences.m`、`UI/SRSettingsFallback.m`：新旧微信设置表、生命周期/晚安装刷新、设置页内恢复入口和默认关闭的悬浮开关；不替换微信表格代理，不强制悬浮兜底。
- `UI/SRPanel.m`、`UI/SRPlanScreens.m`：原生设置、搜索多选、手动等待、单条确认、计划/规则/历史/异常只读页面及适配诊断。
- `Tweak/SRBootstrap.m`：仅在微信主进程初始化存储和设置入口，不注入扩展进程。
- `tests/`：直接调用生产核心的测试。模拟确认不是微信真实回执。

尚未完成：文字接收真机核对、图片接收/媒体准备、真实发送适配、执行控制按钮、调度定时器/发送生命周期接入、失败补发 UI/策略、常亮与设备验收。
规范化过滤和调度核心说明见 `docs/RELAY-CORE.md`；它们不等于已经接入微信。
群枚举保留原包实际使用的 `getContactList:contactType:` `(1,0)`，补充 `MMNewSessionMgr.GetUserNamesOnSessionList`（数组或集合），会话独有群还需精确联系人 ID 核对；读取前后复核账号，合并去重。某个来源不可用时明确提示降级，均不可用时停止；不遍历猜参数或请求服务器通讯录。原包来源证据见 `docs/GROUPS-AND-SETTINGS.md`，不能保证覆盖全部已加入群；成员来自本地群成员字段，也不保证实时完整。
`SRStore` 的 claim 是存储层操作；接入发送器时必须先经过节拍、单账号身份和适配可用性检查。
传入 confirmed 只说明调用方声称已验证结果；未来适配器必须提供实际确认依据，消息 ID 本身不证明服务器已接收。

## 编译

沿用相邻 OwnHide 项目的私有 GitHub Actions/macOS + 固定版本 Theos/SDK 方式。
工作流：`.github/workflows/build.yml`。日常 push 只运行 C 和 Objective-C 核心测试，不安装 Theos、不生成 DEB。
只有需要手机验证时，手动触发并明确勾选 `build_deb`，才会在测试通过后构建普通 DEB，检查 arm64/arm64e slice 并上传私有 Actions artifact。该选项默认关闭。

普通包载荷位于 `Library/MobileSubstrate/DynamicLibraries`。不附带安装脚本，不自动重启微信，不发布 GitHub Release。
包不包含第三方 MikotoHelper 二进制、反汇编输出或本地工具缓存。

macOS 本地核心测试：

```sh
clang -std=c11 -Wall -Wextra -Werror -I. Core/SRPacing.c tests/pacing_test.c -o /tmp/sr-pacing
/tmp/sr-pacing
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I. Core/SRStore.m Core/SRConfiguration.m Core/SRSourceMessage.m Core/SRPacing.c tests/store_test.m -framework Foundation -lsqlite3 -o /tmp/sr-store
/tmp/sr-store
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I. Adapter/SRRuntime.m Adapter/SRWeChatReader.m Core/SRSelection.m Core/SRConfiguration.m Core/SRPacing.c tests/adapter_test.m -framework Foundation -o /tmp/sr-adapter
/tmp/sr-adapter
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I. Core/SRGroupPlanner.m Core/SRSelection.m Core/SRConfiguration.m Core/SRSourceMessage.m Core/SRStore.m Core/SRPacing.c tests/group_planner_test.m -framework Foundation -lsqlite3 -o /tmp/sr-groups
/tmp/sr-groups
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I. Adapter/SRRuntime.m Adapter/SRWeChatReceiver.m Core/SRConfiguration.m Core/SRSourceMessage.m Core/SRSourceCapture.m Core/SRStore.m Core/SRPacing.c tests/receive_test.m -framework Foundation -lsqlite3 -o /tmp/sr-receive
/tmp/sr-receive
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I. Core/SRStore.m Core/SRConfiguration.m Core/SRSourceMessage.m Core/SRPacing.c tests/plan_queries_test.m -framework Foundation -lsqlite3 -o /tmp/sr-queries
/tmp/sr-queries
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I. Adapter/SRRuntime.m Adapter/SRWeChatSendProbe.m tests/send_probe_test.m -framework Foundation -o /tmp/sr-send-probe
/tmp/sr-send-probe
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I. Adapter/SRRuntime.m Adapter/SRWeChatSettingsEntry.m Core/SREntryPreferences.m tests/settings_entry_test.m -framework Foundation -o /tmp/sr-settings
/tmp/sr-settings
```

完整需求和真实进度见 `开发需求与进度.md`。两版微信兼容性目前均未真机验证。

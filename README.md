# SyncRelay

微信母群消息手动分批转发插件，目标环境 iOS 16.0.3、微信 8.0.76 / 8.0.79。

## 当前状态：0.2.0 读取适配与配置草稿

不是可用的群转发成品，尚无消息捕获或发送能力。注入并打开微信后，右下方“同步”按钮进入设置。
成员读取是带签名检查的候选适配，尚未在两版微信上真机验证；接口不匹配会停止并提示诊断。

已编写母群选择、成员原始 wxid 显示/多选、文字/图片开关、随机间隔编辑、排除群搜索与批量操作、100/200 群自动分规则、分组去重与按账号保存草稿。
保存草稿不会创建发送批次；没有开始/重新执行按钮。草稿与已运行记录分离，数据库升级保留旧执行历史。

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

设备验证步骤见 `docs/DEVICE-CHECK-0.2.0.md`。历次构建结果、产物与 SHA-256 见开发进度文档。

已编写的模块：

- `Core/SRStore.m`：计划、互斥分组、独立执行批次、持久化状态、暂停/恢复、重新执行、结果关联。
- `Core/SRPacing.c`：至少 10 秒的随机节拍计算，单调时钟输入，恢复时不补发错过节拍。
- `Core/SRConfiguration.m`、`Core/SRSelection.m`：草稿校验、完整列表批量选择、来源群与重复目标排除。
- `Core/SRGroupPlanner.m`：共享条件、按配额自动分组、不足额预览和持久化排除的候选草稿生成，不触发发送。
- `Core/SRSourceCapture.m`、`Core/SRSourceMessage.m`：规范化消息过滤、单条预览冻结和确认后原子创建计划；尚未挂接微信接收接口。
- `Core/SRRunner.m`：串行派发、账号互斥、节拍和超时核对核心；仅使用测试发送器验证，启动时不会运行它。
- `Adapter/`：运行时签名检查、只读联系人/成员候选接口、脱敏诊断；没有发送 API。
- `UI/SRPanel.m`：原生设置、搜索多选、草稿保存、适配诊断。
- `Tweak/SRBootstrap.m`：仅在微信主进程初始化存储和设置入口，不注入扩展进程。
- `tests/`：直接调用生产核心的测试。模拟确认不是微信真实回执。

尚未实现：微信实际消息捕获、发送适配、执行控制界面、调度定时器/生命周期接入、失败补发 UI/策略、媒体缓存、常亮与设备验收。
规范化过滤和调度核心说明见 `docs/RELAY-CORE.md`；它们不等于已经接入微信。
群枚举当前只调用候选 `getContactList:contactType:` 的 `(1,0)` 参数，不能保证覆盖全部已加入群；成员来自本地群成员字段，不能保证为实时完整名单。界面显示该限制。
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
```

完整需求和真实进度见 `开发需求与进度.md`。两版微信兼容性目前均未真机验证。

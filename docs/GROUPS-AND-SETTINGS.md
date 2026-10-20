# 群来源与 0.2.2 设置入口修正依据

日期：2026-10-20。原包 dylib SHA-256：`0a11bacae2a0131b0ccbdf20ce49f9374bcd50c0d054fc290e9ba9e3b725eb43`。

## 群列表修正

用户在首轮 0.2.0 手机上只读到 4 个普通群。旧实现仅调用 `CContactMgr.getContactList:contactType:` 的 `(1,0)` 并过滤普通群 ID，模拟大列表通过并不证明微信返回全部群。

- 原包 `0x1763110`、`0x1765df8` 的选择器装载附近实际传参也是 `(1,0)`，因此不盲目换 contactType 或遍历参数。
- `PJMessageGalaxyViewController` 初始化注册入口 `0x32e4740` 将 `candidateItemsFromHomeSessions` 注册到 `0x32cd560`。
- 该方法在 `0x32ce03c` 调用 `getMMContextWithServiceName:`，解码后的服务名为 `MMNewSessionMgr`；返回值存入由 `[x29-0xb8]` 指向的局部槽。
- 同一方法 `0x32ce8a8` 从该槽取接收者，调用 `GetUserNamesOnSessionList`。这里是原包主会话候选为空后的补充路径，不是“全部已加入群”证明。
- 后续代码对数组直接使用、对支持 `allObjects` 的集合转换。新版只接受明确数组或 NSSet，不调用未知对象的任意转换方法。

复现：

```sh
python tools/offline_mikoto_trace.py --entry 0x32e4740
python tools/offline_mikoto_trace.py --entry 0x32cd560 --mode session-source
```

`session-source` 先在隔离内存中运行字符串/方法注册初始化，再以空主会话集合和服务 token 执行候选方法，在本地用户名读取边界停止。注册/消息均是拦截模型，不加载原包、不调用微信、不联网、不发送；不模拟群数量、返回内容或真实服务可用性。每阶段上限 100 万指令/15 秒、映像上限 128 MiB，未知导入停止。

新版独立实现使用当前已核对账号的 `MMServiceCenter` 获取 `MMNewSessionMgr`，带方法签名检查读取本地会话用户名，再与联系人候选合并。会话独有群必须通过 `getContactByName:` 返回相同 ID；空/错格式/不匹配目标不入选。读取结束再次核对账号。不同来源失败分别显示状态，两个来源均失败则停止，不静默当作空群池。诊断只保留总量、可读/不可读状态及未核对计数。

仍未证明：`MMServiceCenter` 在两版设备是否可取该服务；无会话记录且未入旧联系人返回值的群是否遗漏；本地记录中的群是否仍可发送。必须真机对照，不能把合并数当作已加入群总数或可发送承诺。

## 设置入口

原包 `WCHLSettingViewController` 的初始化注册入口 `0x5b7cf44` 可还原其配置方法：`reloadTableData` 为 `0x5b75fb4`，`createMoreFunctionCell` 为 `0x5b7c6e0`。其中 `0x5b7703c` 使用 `sectionInfoDefaut`，`0x5b77094` 使用 `addCell:`，`0x5b770bc` 读取 `m_tableViewInfo`，`0x5b770e8` 使用 `addSection:`；`0x5b7ca00` 使用 `normalCellForSel:target:title:`。这些是表构建方式的参考，不等于本插件在宿主设置页面实测通过。

0.2.1 根据这些表构建线索只接入 `m_tableViewInfo` / `MMTableViewCellInfo`，用户随后反馈「我 → 设置」没有入口。这些是 Mikoto 自己配置页的 API，不能直接代表宿主新版设置的表管理器；此处为本轮实际发现的适配遗漏，不把测试桩通过等同真机通过。

### 新确认的宿主设置路径

- 主初始化器 `0x5b823c8` 在首个导入调用之前已解码类名：`0x60ffdd0` 是 `AddContactToChatRoomViewController`，`0x60ffe20` 是 `ChatRoomInfoViewController`，`0x60ffe60` 才是 `NewSettingViewController`。不能将前两个 `reloadTableData` 误作主设置页。
- 同一类槽在 `0x5babd88`、`0x5babe1c`、`0x5babe4c` 分别装载 `viewDidLoad`、`reloadTableData`、`willAppear`，后两个实现地址分别为 `0x5bc3bfc` / `0x5bc3ed0`。
- `0x5bc3bfc` 的局部字符串初始化将 `0x6100f5f` 解为 `m_tableViewMgr`；`0x5bc3e40` 经 ivar helper 读取该字段，`0x5bc3e74` 将表和宿主传给 `PJMisakaManager.load_Misaka:WithVC:`。另一个 getter `0x5bc4238` 解码 `0x6100f9b` 得到同一字段。
- `PJMisakaManager` 初始化 `0x34f8d0c` 注册 116 个方法，其中 `load_Misaka:WithVC:` 位于 `0x33d8ea0`。该方法入口至首个 Objective-C 调用的离线前缀已将 `0x5f43f90` 解为 `WCTableViewNormalCellManager`；`0x33e0284` 从此地址取类名，`0x33e0304` 使用 `normalCellForSel:target:title:rightValue:accessoryType:`，`0x33e04a8` 取 `sections`，`0x33e04e4` 对首个 section 使用 `insertCell:At:`，`0x33e063c` 刷新表。
- `0x33d8ea0` 的通用注册模式在首个未支持 `_objc_msgSend` 停止，因此不是完整方法模拟成功。仅采信已解码类字符串和独立核对的静态调用点，不推断后续所有分支、原包功能门控或两版手机行为。

复现字符串边界：

```sh
python tools/offline_mikoto_trace.py --entry 0x5b823c8 --mode settings-strings
python tools/offline_mikoto_trace.py --entry 0x5bc3bfc --mode settings-strings
python tools/offline_mikoto_trace.py --entry 0x5bc4238 --mode settings-strings
python tools/offline_mikoto_trace.py --entry 0x34f8d0c
python tools/offline_mikoto_trace.py --entry 0x33d8ea0
```

`settings-strings` 只执行四个白名单入口的局部解码区，在首个导入调用或审定的字符串边界停止；不执行 `installEarlyBypassHooks`、不模拟/修改功能门控、不调用微信。报告位于忽略的 `analysis/reports/`，不随包分发。

### 0.2.2 独立实现

优先读取 `m_tableViewMgr` 的 getter / 对象 ivar，再兼容 `m_tableViewInfo`。新版 cell 工厂增加经 SEL、object、整数宽度验证的五参数形式。在可核对 `getAllCells` / `cells` 数组的已有 section 内插入并按自身对象标记去重；宿主复用 section 清除该行后可恢复。另一条带检查的候选是 `WCTableViewSectionManager.defaultSection`（本轮未从该宿主调用点证明，必须 runtime 匹配），旧表仍使用 `MMTableViewSectionInfo.sectionInfoDefaut` 加独立 section。

只扩展 `NewSettingViewController` 已存在且签名正确的 `reloadTableData`、`viewDidLoad`、`viewWillAppear:`、`viewDidAppear:` 和 `willAppear`。继承方法仅在子类新增覆盖，宿主原链先行、原异常传播，附加逻辑有重入/异常保护；不全局 hook UIKit，不替换 data source/delegate。安装及回前台检查已显示的设置页，避免异步存储完成晚于第一次加载。设置入口不依赖消息版本白名单，消息读取/观察仍维持原版本门禁。

若私有表/工厂不匹配，在该设置页已加载的 UITableView 底部放置同名入口，保留原 footer；原生行恢复后撤掉补充入口并恢复 footer。它不是窗口悬浮按钮，只用于防止再次无法进入诊断。找不到对应 UITableView 时不修改未知视图，仍需手机截图/日志定位。存储初始化或恢复失败也安装入口，打开后明确禁用规则操作，只保留诊断与入口开关。

模拟回归增加 manager-only、只有生命周期没有 reload、主 BOOL 原参数/异常、晚加载和已显示实例刷新、重复进出/清行恢复、恢复回调/重入/错误签名、未知版本诊断可达。UIKit 页脚、注入共存和两版真实 UI 仍待手机验证，见 `DEVICE-CHECK-0.2.2.md`。以上修正不证明用户设备缺失入口只有一种原因。

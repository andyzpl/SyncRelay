# 0.2.1 群来源与设置入口依据

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

新版不复用原包代码或绕过原包任何功能门控。独立对宿主 `NewSettingViewController.reloadTableData` 做严格 void/no-args 检查，只在原链完成后追加「SyncRelay 转发」独立 section。表信息 getter / 对象类型 ivar、sections 数组、cell factory 中 SEL/object 参数、void/object 变更和表刷新均逐项检查。只在已确认的数组内查找本插件自己的 section 标记去重；不替换宿主代理，不全局 hook UITableView，不把昵称/标题相等作为 section 身份。

继承方法只在子类新增覆盖，保留捕获的原链；宿主原方法异常照常传播，插件附加逻辑异常不改变原链。section 保留 action，action 弱引用宿主控制器，避免原设置页面被持有。若签名/数据不匹配则不追加、不强制开浮窗；具体宿主表布局仍待两版微信手机核对。

模拟测试覆盖重复重建/不清空重载、表替换、继承链、getter 与对象 ivar、错误返回/SEL/指针类型、原异常、目标弱引用和悬浮开关默认关闭/独立持久化。UIKit 的实际呈现、注入时机和共存插件链必须真机测试，见 `DEVICE-CHECK-0.2.1.md`。

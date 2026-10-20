# MikotoHelper 文字发送路径补充证据

日期：2026-10-20。范围：用户提供的 2.5.0 DEB 内的运行时方法注册、普通文字构造及一个发送调用路径。不是完整源码还原，不代表已验证微信 8.0.76 / 8.0.79。

## 输入与分析方式

- 输入：项目根目录 `MikotoHelper-2.5.0-iphoneos-arm.deb`。
- DEB SHA-256：`96a02987015af185976ca97ed0848b13335afbb6122ff67bbf885a2bccfa223d`。
- 解出的 `MikotoHelper.dylib` SHA-256：`0a11bacae2a0131b0ccbdf20ce49f9374bcd50c0d054fc290e9ba9e3b725eb43`。
- 所有代码地址是该 Mach-O 的未加 ASLR slide 虚拟地址，不是文件偏移，也不能直接套用到微信本体或其他 Mikoto 版本。
- 先核对 ARM64 指令及精确选择器引用，再用 `tools/offline_mikoto_trace.py` 对限定入口做离线指令模拟。没有把第三方 dylib 加载到 Windows、真实 Objective-C runtime 或微信里运行。

离线模型采用合成对象，拦截导入函数，假设所查类存在；不支持的导入/选择器立即停止。限制为 128 MiB 镜像、100 万条指令、15 秒模拟时间。文字路径在 `AddMsg:MsgWrap:` 边界停止，不实施发送。`completedModel=true` 只说明该模型路径完成，不说明原插件运行正常、所有分支均覆盖或手机兼容。

### 用户提供的 WorkBuddy REA 报告

本轮另参考用户提供的 `rea_mikoto/report.md`，41140 字节，SHA-256 为 `88459888644c8d7000ec9802b1a03803977579c69c2dd582ddf7d37c66303a6f`。报告属于静态包/方法名/导入与关键词扫描，报告自身也明确未执行二进制、未提供完整伪代码；作为待核对资料，不作为执行指令。

其记录的包版本、103163504 字节 ARM64 dylib、`AsyncOnAddMsg:MsgWrap:`、`GetMsg:LocalID:` 和转发方法名与当前研究线索相符。关键词命中数不证明功能实现或调用归属，签名存在不证明具体 entitlement 权限。报告不补足普通文字可靠回执、线程、两版兼容或真实转发成功的证据，因此本次不据此放开发送；先交付当前只读诊断包上手机核对。

## 运行时业务方法映射

原插件通过 `class_replaceMethod` 安装业务实现，静态类表里显示的 `initialize` 不能当作业务方法全集。

| 注册入口 | 模型结果 | 说明 |
| --- | --- | --- |
| `0x541d788` | `PJTransmitModel` 的 12 次注册 | 目标是类对象，替换其实例方法；不能因为注册发生在 `+initialize` 就写成类方法 |
| `0x29d0034` | `meta:PJHelper` 的 224 次注册 | 目标是元类，对应 PJHelper 类方法；不是微信原生方法 |

本轮重点映射如下。这里只列定位结果，不把原插件的调度、授权检查或工具方法作为本项目运行依赖。

| 方法 | 实现地址 | 原始编码 |
| --- | --- | --- |
| `-[PJTransmitModel addTransmitModelWithDataArray:WithObjArray:WithTime:]` | `0x5410564` | `v40@0:8@16@24q32` |
| `-[PJTransmitModel taskManagerWithCurentTaskModel:]` | `0x541564c` | `v24@0:8@16` |
| `+[PJHelper getMessageWrapWithText:WithFromUsr:WithToUsr:WithSource:CreateTime:]` | `0x271cf70` | `@52@0:8@16@24@32@40i48` |
| `+[PJHelper sendMsgWithText:WithToUserName:WithReSourece:]` | `0x272d588` | `v40@0:8@16@24@32` |
| `+[PJHelper sendMsgWithText:WithToUserName:WithReSourece:WithCheckLoadID:]` | `0x271ea34` | `v44@0:8@16@24@32B40` |
| `+[PJHelper transmitMsg:WithUserName:WithSource:WithCheckLoadID:WithUserInfo:]` | `0x276c264` | `v52@0:8@16@24@32B40@44` |
| `+[PJHelper AddMsgWithTextMessageWrap:]` | `0x27880e8` | `@24@0:8@16` |

`WithTime:` 的编码是整数，但时间单位、真实派发顺序、取消/恢复语义及上限尚未由这些注册记录证明。不能照搬为“原包保证每隔 N 秒成功发送”。

## 普通文字的一个原生调用路径

`0x272d588` 的限定文字路径中，精确调用点与离线模型一致：

```text
MMContext currentContext
  -> context getService: CMessageMgr
  -> PJHelper getMySelfWxidNew
  -> PJHelper getTimetempSystem
  -> PJHelper getMessageWrapWithText:WithFromUsr:WithToUsr:WithSource:CreateTime:
  -> CMessageMgr AddMsg:MsgWrap: (目标群, 已构造的文字 wrap)
```

关键指令位置：`currentContext` 调用 `0x272e2b0`，`getService:` 调用 `0x272e2f4`，`AddMsg:MsgWrap:` 选择器装载 `0x272e67c`、调用 `0x272e680`。模型报告的 `caller` 是 LR 返回地址，例如 `0x272e684` 对应前一条调用指令；不要把两者混淆。

模型只用合成的消息体、账号和目标，构造工具方法也被替身拦截。它没有验证 native CMessageWrap、服务对象、线程、账号权限、网络、返回值或发送回执。此调用者未使用 AddMsg 返回值来判定送达；发现调用点不等于发现成功判据。

另行核对 `0x271cf70` 的局部构造指令：

- `0x271def8` 装载 `initWithMsgType:`，`0x271defc` 把类型设为 1，`0x271df00` 调用。
- `0x271df68`、`0x271df84`、`0x271dfa0` 分别装载 from、content、to 的 setter。
- `0x271dfb4` 装载 `setM_uiMesLocalID:`，随后传入 0。不能预先伪造已分配的本地 ID。
- source 与创建时间还有独立处理。尚未完成整条构造路径所有分支与两个微信版本的实际字段核对，SyncRelay 本轮不复制构造并主动发送。

## 已排除的误判

1. `AddMsgWithTextMessageWrap:` 是 PJHelper 方法，方法体包含其他命令/界面处理，不能当成微信原生发送 API，也不能要求手机安装 Mikoto 才能使用本项目。
2. 某个其他路径出现 `status=4` 不说明普通文字发送必须如此；其构造类型为 `0x2710`，不能迁移到上述 type=1 的路径。
3. `MessageReturn:MessageInfo:Event:` 名字不证明“发消息成功回调”。本轮找到的注册在 `0x5bb19d4` 装载该选择器，`0x5bb19e8` 调用 `MSHookMessageEx`，hook IMP 为 `0x5be7ae8`；其调用原实现后附加的条件逻辑在 `0x5be7bcc` / `0x5be7bd0` 调用 `changeHeaderFinish`。该附加逻辑关联头像完成处理，所属原生类尚未确认，不能据此将任何 event/status 数字映射为发送成功。
4. 早期 `analysis/reports/send-selector-xrefs.json` 使用过子串匹配，会把 AddMsg 与 AsyncOnAddMsg 混淆；其中零引用或引用数量不是当前证据。以精确选择器、指令和新离线报告为准。
5. `PJTransmitModel` 的方法注册已定位，不代表其完整调度算法、平台限制应对或持久化方式已经还原。同步规则仍采用本项目独立核心。

## 可重复检查

依赖限定在本地 `analysis/python-libs`：LIEF `1.0.0-d05b3499b`、Unicorn `2.1.4`。这些依赖、原包及解包/报告均不加入私有库或 DEB。

```sh
python tools/offline_mikoto_trace.py --entry 0x541d788
python tools/offline_mikoto_trace.py --entry 0x29d0034
python tools/offline_mikoto_trace.py --mode text-route --entry 0x272d588
```

本轮三项分别得到 12 次注册、224 次注册、6 次合成 Objective-C 消息调用，均无未支持调用；最后一项在发送边界停止。报告位于：

- `analysis/reports/offline-registration-541d788.json`
- `analysis/reports/offline-registration-29d0034.json`
- `analysis/reports/offline-text-route-272d588.json`

对应局部指令保存在 `analysis/reports/disasm-272e260.txt`、`analysis/reports/disasm-271de70.txt`、`analysis/reports/disasm-5be7ae8.txt` 及 `send-callsite-windows.txt`。这些是本地研究证据，不是运行日志或最终反编译源码。

## 对开发的直接影响

新增只读 `SRWeChatSendProbe`：由用户在一个授权测试群手动发送一条普通文字，观察原入口和精确本地 ID 读取后的元数据，不读正文、不创建消息、不推断送达。观察方法和手机步骤见 `SEND-PROBE.md`、`DEVICE-CHECK-0.2.0.md`。

已经具备第一轮小范围手机验证价值：先核对注入入口、群/成员 wxid 和手动接收，再核对一次手动发文字的 ABI、ID 关联与原始状态变化。它不是 100/200 群发送验收；真实转发、图片和成功/失败判据仍待后续实现与设备验证。

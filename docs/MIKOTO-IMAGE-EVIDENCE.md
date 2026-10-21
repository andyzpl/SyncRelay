# 图片来源读取证据与边界

日期：2026-10-21。仅研究用户提供的 `MikotoHelper-2.5.0-iphoneos-arm.deb`，没有把第三方二进制加载到宿主进程或加入 SyncRelay 包。

## 可以确认的调用点

- 原 dylib SHA-256：`0a11bacae2a0131b0ccbdf20ce49f9374bcd50c0d054fc290e9ba9e3b725eb43`。
- 消息库方法中的字符串初始化入口 `0x3652694`，解码边界 `0x3652d90`；解出的 `0x5f62111` 是 `CMessageWrap`，不是 PJHelper 或猜测的消息管理类。
- `0x36534d4` 读取消息类型，`0x36534d8` 与 3 比较。
- `0x36534e8` / `0x36534ec` 加载上述字符串，`0x36534f0` 调用 `objc_getClass`。
- `0x36534f4` / `0x36534f8` 将原 wrap 放入 x2；`0x3653500` 加载精确选择器 `getMsgHdOrMiddleImg:`，`0x3653504` 调用。
- 返回对象先判空，然后在 `0x365354c` 作为 UIImage 传入 `UIImageJPEGRepresentation`，该处质量参数为 0.5。这证明这一调用路径将其结果作为图片，而不是文件路径。

由此采用的候选是 `+[CMessageWrap getMsgHdOrMiddleImg:wrap]`。不照搬原插件的二次压缩策略，也不把这个名称解释为“总能取原图”或“会自动下载”。

## 可重复的离线检查

本机逆向依赖使用 Python 3.12 运行时；LIEF 的现有 wheel 不兼容当前 `py -3` 对应的 Python 3.11。

```powershell
& 'C:/Users/Andyz/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' tools/offline_mikoto_trace.py --mode image-strings --entry 0x3652694
```

结果：`completedModel=true`，终点 `0x3652d90`，0 次导入调用、0 次注册、0 次 Objective-C 消息调用，字符串为 `CMessageWrap`。此模式只执行限定的本地字符串解码指令；二进制哈希、镜像、指令数及时间仍有限制。它不验证任何手机运行行为。

本地忽略目录证据：`analysis/reports/offline-image-strings-3652694.json`、`analysis/reports/disasm-3651f00.txt`、`analysis/reports/disasm-3653430.txt`。原包、原始报告和逆向依赖不提交仓库，无论仓库是私有还是公开。

## SyncRelay 的独立实现

1. 对原生类实际存在的类方法核对 `object(object)` 的完整 ABI，使用普通消息派发，不猜地址、不读取 ivar，也不依赖安装 Mikoto。
2. 先按当前账号、母群、所选 wxid 和类型过滤；接收和本人发图都要求非零服务器 ID。本人仍只按原来观察到的精确本地 ID 尝试回读，不扫描最近消息。
3. 对暂未准备好的原生图片设置 30 秒单调时钟轮询窗口；停止、切后台、换账号、换来源或代次改变后不再接纳结果。没有自动下载接口，需在母群手动加载后重新捕获新消息。
4. 校验 UIImage 和尺寸后编码为独立静态 PNG 快照；不存微信临时路径、远程 URL、XML、CDN key，不承诺原文件/原画质/动画。拒绝超过 12000 像素单边、3200 万像素或 20 MiB 的快照。
5. 自有文件以随机 UUID 命名，描述符包含版本、尺寸、格式、字节数和 SHA-256，并绑定账号/群/发送者/消息 ID 的摘要。预览/确认重新检查资源与来源，不把“有引用”当作图片可用。
6. 保存文件使用独占创建、0600 权限和不跟随符号链接；读取限定在自己的目录和 UUID 文件。256 MiB 配额达到后拒绝新快照，不擅自删除计划图片。取消预览删除其文件；确认计划保留，重启清理未被已确认计划引用的遗留快照。
7. 诊断仅含阶段、计数、ABI、尺寸之外的资源错误分类，不导出图片、路径、哈希、XML 或原始标识。真实 wxid/图片只出现在账号核对后的本地配置/预览中。

## 仍未证明的部分

- 用户已明确确认本人发图捕获成功且实际预览为正确图片，见 `DEVICE-RESULT-0.2.14.md`。本轮没有附带图片诊断，仍未确定返回中图/大图、可用时机、是否需先点开，以及其他发送者/版本的行为。
- 图片 getter 的等待窗口不强制中断一次正在运行的原生调用，也不能保证微信进程绝不被系统终止。
- 图片发出路径中虽存在 `initWithMsgType:3`、`setImage:withData:isOriginImage:` 与 `AddMsg:MsgWrap:` 等线索，尚未完成各参数/分支/原图属性的运行时验证；0.2.14 不调用这些发送方法。
- `getPathOfMsgImg:` 同时在语音等路径出现，不能据名称把它当作某条图片的绝对路径。本实现不使用它，也不派生后缀、替换扩展名或猜下载目录。
- 不把离线证据、模拟测试、预览成功或消息 ID 当成送达证明；不开放图片实发、批量、自动重试或下一规则自动接力。

## 图片发送扩展对象证据（0.2.15）

注册信息确认 `+[PJHelper sendMsgWithImage:WithToUserName:]` 的 IMP 是 `0x2733a40`、编码 `v32@0:8@16@24`。新增有界 `image-route` 离线模式，仅接受该入口和原二进制哈希；输入、UIImage/JPEG 数据、账号/目标和服务都是合成对象，未知导入或消息立即停止，在 AddMsg 调用边界停止。

两条合成能力分支均完成，关键结果：

- `0x2735bb8` 解码类名为 `CMessageWrap`，`0x2735bd4` 执行 `initWithMsgType:3`。
- `0x2735bf8` 使用 `SettingUtil getLocalUsrName:0`；随后给 wrap 设置 from/to。
- `0x2735c5c` 对 wrap 执行 `valueForKey:@"m_extendInfoWithMsgType"`，图片 setter 的接收者是其返回的扩展对象，**不是 wrap**。
- 图像与 `UIImageJPEGRepresentation` 返回的数据同时传入 setter；long 选择器存在时，在 `0x27360ac` 调用 `setImage:withData:isLongOriginImage:`；long 不存在、origin 存在时，在 `0x2736720` 调用 `setImage:withData:isOriginImage:`。两条被执行的分支 x4 均为 0；不据此猜测其完整业务语义、标量 ABI 或所有其他分支。
- `0x2736b7c` 设置时间，`0x2736b94` 设置 `m_uiStatus=1`；之后解析到 `MMContext.currentContext` → `getService:CMessageMgr` → `0x2736d38 AddMsg:MsgWrap:`。离线模型在最后一个调用之前停止。

可重复命令（Python 3.12 环境同前）：

```powershell
& 'C:/Users/Andyz/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' tools/offline_mikoto_trace.py --mode image-route --entry 0x2733a40 --output analysis/reports/offline-image-route-long.json
& 'C:/Users/Andyz/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' tools/offline_mikoto_trace.py --mode image-route --entry 0x2733a40 --image-long-selector absent --output analysis/reports/offline-image-route-origin.json
```

分别为 14/15 条 Objective-C 消息，`completedModel=true`、`stoppedAtSendBoundary=true`、0 个问题。该结果证明受上述合成假设约束的离线接收者/参数流，不证明真实扩展类名、KVC 对应 getter 存在、原生图片编码/写入、iOS 方法 ABI 或手机发送。

SyncRelay 0.2.15 因此只增加独立的未发送消息接口检查：严格匹配 `i/I/q/Q` 构造器并维持 ARC init-family 所有权、核对初始类型与零 ID、只用已声明零参数对象 getter 获取扩展、只检查两种图片 setter 的实际 ABI。getter 缺失时报告并停止，不沿用 Mikoto 的 KVC/ivar 方式，不调用图片 setter或解析服务。诊断规范化类型且不泄漏本地标识。这是图片实发前的检查点，不是图片发送实现。

## 对应的手机实测（1103）

与交付身份一致的 0.2.15 诊断，在 iOS 16.0.3 / 微信 8.0.79.35 上确认 q 构造器和实际扩展 getter 可用；扩展的 origin setter 存在，ABI 为 v(@,@,B)，long 方法不存在，故选中 origin 分支。本轮没有调用 setter、消息服务或发送。这补充了离线模型不能证明的实际 getter/ABI 证据，但没有证明对象参数的全部业务语义、资源装载、写盘副作用、发送或送达；详见 `DEVICE-RESULT-0.2.15.md`。

## 0.2.16 独立单群图片实现

图片实验按上述接收者和参数流，传入已校验静态快照对应的 UIImage 及 JPEG 数据、零 BOOL 标志，再设置时间/status 并通过原服务提交一次。没有复制 Mikoto 二进制、KVC/ivar 取值或动态修补接口。构造器、扩展和实际服务均重新验证；原文字 host/adapter 文件不改。

这是待真机核对的新实现，不代表 UIImage/JPEG 业务契约、媒体写入与异步生命周期已通过。实验保留持久占位、单目标/一次机会、前台节拍、未知结果不重试；不盲清宿主路径、不接入批量。范围见 `DEVICE-CHECK-0.2.16.md`。

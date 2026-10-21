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

本地忽略目录证据：`analysis/reports/offline-image-strings-3652694.json`、`analysis/reports/disasm-3651f00.txt`、`analysis/reports/disasm-3653430.txt`。原包、报告和逆向依赖不提交私有库。

## SyncRelay 的独立实现

1. 对原生类实际存在的类方法核对 `object(object)` 的完整 ABI，使用普通消息派发，不猜地址、不读取 ivar，也不依赖安装 Mikoto。
2. 先按当前账号、母群、所选 wxid 和类型过滤；接收和本人发图都要求非零服务器 ID。本人仍只按原来观察到的精确本地 ID 尝试回读，不扫描最近消息。
3. 对暂未准备好的原生图片设置 30 秒单调时钟轮询窗口；停止、切后台、换账号、换来源或代次改变后不再接纳结果。没有自动下载接口，需在母群手动加载后重新捕获新消息。
4. 校验 UIImage 和尺寸后编码为独立静态 PNG 快照；不存微信临时路径、远程 URL、XML、CDN key，不承诺原文件/原画质/动画。拒绝超过 12000 像素单边、3200 万像素或 20 MiB 的快照。
5. 自有文件以随机 UUID 命名，描述符包含版本、尺寸、格式、字节数和 SHA-256，并绑定账号/群/发送者/消息 ID 的摘要。预览/确认重新检查资源与来源，不把“有引用”当作图片可用。
6. 保存文件使用独占创建、0600 权限和不跟随符号链接；读取限定在自己的目录和 UUID 文件。256 MiB 配额达到后拒绝新快照，不擅自删除计划图片。取消预览删除其文件；确认计划保留，重启清理未被已确认计划引用的遗留快照。
7. 诊断仅含阶段、计数、ABI、尺寸之外的资源错误分类，不导出图片、路径、哈希、XML 或原始标识。真实 wxid/图片只出现在账号核对后的本地配置/预览中。

## 仍未证明的部分

- 当前设备实际是否提供此方法、是否返回中图/大图、何时可用、是否需要先点开图片，必须真机确认。
- 图片 getter 的等待窗口不强制中断一次正在运行的原生调用，也不能保证微信进程绝不被系统终止。
- 图片发出路径中虽存在 `initWithMsgType:3`、`setImage:withData:isOriginImage:` 与 `AddMsg:MsgWrap:` 等线索，尚未完成各参数/分支/原图属性的运行时验证；0.2.14 不调用这些发送方法。
- `getPathOfMsgImg:` 同时在语音等路径出现，不能据名称把它当作某条图片的绝对路径。本实现不使用它，也不派生后缀、替换扩展名或猜下载目录。
- 不把离线证据、模拟测试、预览成功或消息 ID 当成送达证明；不开放图片实发、批量、自动重试或下一规则自动接力。

# 微信发送结果回调调查

日期：2026-11-13。范围：本地可执行文件的只读静态分析，以及现有发送适配器的源码核对。没有新增 hook、诊断入口、发送实验、UI 状态或数据库写入；没有提交、推送、CI、打包或安装。

## 1. 结论与未完成项

- **不能把“插件尚未接入可靠发送结果”说成“微信没有回执”。** 本地 8.0.76 样本存在可追溯至协议响应的发送成功/失败路径，不只是带有 success/fail 名字的方法。
- 普通文字候选链为 `SendMessageEventHandler` → `ISendMessageExt` 的 `OnSendMessageSuccess:` / `OnSendMessageFail:`；`CMessageMgr` 是这两个方法的实际实现者之一。
- 普通图片另有 `ImageUploadTaskController` → 消息 CGI → `IMsgExt` 的 `OnMsgSendSuccess:` / `OnMsgSendFail:`。**上传完成、消息 CGI 成功不是同一个事件。** 不能只监听文字链就宣称覆盖图片。
- 上述成功路径支持“宿主处理了服务端发送成功响应”的解释；不能扩展为目标设备已收到、所有群成员已收到或已读。
- **当前设备版本仍未核实完成。** 现有设备记录是微信 `8.0.79.35`，本次实际二进制为 `8.0.76`，两者不能互相替代。还缺同版二进制核对与该版本真实回调的参数/时序证据，生产确认逻辑保持不变。

## 2. 样本身份与分析方法

输入是本地文件 `微信8076_com.tencent.xin(防封).ipa` 中的 `Payload/WeChat.app/WeChat`。文件名表明它可能经过修改；本次不认证它是未经改动的官方发行文件。

| 字段 | 值 |
| --- | --- |
| Info.plist 版本 / 构建 | `8.0.76` / `8.0.76` |
| Mach-O | arm64，64 位 |
| 主程序字节数 | `543567424` |
| 主程序 SHA-256 | `b74e8230acb27b6a1e6f5868be8e2e1beac04d91c3be2cbe54af03579a2583d1` |
| Mach-O UUID | `E2266B3E-B0B1-322E-ABA9-B7B65A33B9D3` |
| `LC_ENCRYPTION_INFO_64.cryptid` | `0` |
| 静态地址基址 | `0x100000000` |

下文地址均为该文件的未加 ASLR slide 的虚拟地址，不是设备运行时地址，不可复制为其他版本的 hook 偏移。

分析读取 Mach-O sections、Objective-C class/method/protocol/selector 元数据，并用 Capstone 反汇编实际方法及 block。该文件使用 `LC_DYLD_CHAINED_FIXUPS`、指针格式 `DYLD_CHAINED_PTR_64_OFFSET`；指针字段先解码 rebase/bind，不把原始带链位的数值当绝对地址。方法列表同时处理相对项，协议编码也来自实际元数据。

`objc_msgSend` 调用经三层 branch island 到导入 stub：`0x107c26248` → `0x10f85a038` → `0x117471880` → `0x1178db74c`，最终绑定 `_objc_msgSend`。这条解析用于确认下文调用，不只凭寄存器使用方式猜测。

原始二进制、完整方法索引、反汇编和辅助脚本保留在本地被 Git 忽略的 `.build-cache/receipt-research/`，不纳入源码或发布包。没有执行或加载微信主程序，没有调用宿主 getter、下载媒体或访问聊天数据库。

## 3. 普通文字：协议响应到成功通知

### 3.1 入口和真正的结果处理者

静态链路：

```text
CMessageMgr AddMsg:MsgWrap:
  -> SendMessageMgr AddMsgToSendTable:MsgWrap:
  -> SendMessageMgr SendMsg
     -> ProtobufCGIWrap，CGI 522 (0x20a)
     -> eventHandlerClass = SendMessageEventHandler
  -> ProtobufEvent NotifyFromPrtl:MessageInfo:
     -> OnProtocolResponse:shouldContinue:
  -> 检查整体响应，再逐条检查返回码、关联原消息
  -> 写入响应 newMsgId，设置发送状态
  -> handleSendSuccessMsg:
  -> ISendMessageExt / OnSendMessageSuccess:
  -> CMessageMgr OnSendMessageSuccess:
     -> AsyncOnModMsg:MsgWrap:
```

关键证据：

| 地址 / 方法 | 可核对的实际行为 |
| --- | --- |
| `0x104970cbc`，`CMessageMgr AddMsg:MsgWrap:` | 普通发送分支在 `0x10497131c` 加载 `AddMsgToSendTable:MsgWrap:`，在 `0x10497138c` 加载 `SendMsg` 并调用；图片另有分支。不是 AddMsg 返回后立即发成功通知。 |
| `0x10556bc6c`，`SendMessageMgr SendMsg` | 构造 `SendMsgRequestNew` / `ProtobufCGIWrap`，`0x10556bcf4` 传入 CGI `0x20a`；设置事件处理类为 `SendMessageEventHandler`。 |
| `0x1051e569c`，`ProtobufEvent NotifyFromPrtl:MessageInfo:` | 分发协议通知，`0x1051e5a18` 加载 `OnProtocolResponse:shouldContinue:`；另有 `OnProtocolConnectFail:` 路径。 |
| `0x105567f78`，`SendMessageEventHandler OnProtocolResponse:shouldContinue:` | 读取 `m_pbResponse.baseResponse.ret`；响应为空或整体 ret 非 0 不进入逐条成功处理。`0x1055680ac` 为 ret 为 0 时的跳转。 |
| 同方法 `0x1055681a4` 起 | 遍历响应 `list`，读取 `toUserName`、`clientMsgId`、`newMsgId` 等；通过 clientMsgId 对应原发送集合里的消息，不以“当前任务”代替具体消息关联。 |
| 同方法 `0x105568550` / `0x105568554` | 再检查单条响应 `ret`；只有该条 ret 为 0 才跳到 `0x1055686c8` 的成功分支，且要求找到对应消息对象。整体 ret 为 0 不是所有条目成功的充分条件。 |
| `0x1055686cc` 至 `0x1055686f4` | 从单条响应读取 `newMsgId`，调用消息对象 `setM_n64MesSvrID:`，随后 `setM_uiStatus:2`。 |
| `0x105568838` | 在上述成功路径调用 `handleSendSuccessMsg:`，参数是关联到的原消息对象。 |
| `0x10556917c`，`handleSendSuccessMsg:` | 经 `MMContext`、协议 `ISendMessageExt` 广播 `OnSendMessageSuccess:`；普通分支在 `0x1055693d0` 调用 `callExtensionOnMainThread:selector:sync:block:`，sync 参数为 0。另有特殊联系人分支和数据库更新后的通知安排，不应假设回调紧跟 AddMsg 同步发生。 |
| block `0x10556975c` | 实际调用 extension 对象的 `OnSendMessageSuccess:`，传入捕获的消息对象。 |
| `0x1049819d0`，`CMessageMgr OnSendMessageSuccess:` | 取得消息 `GetChatName`，在 `0x104981a70` 调用 `AsyncOnModMsg:MsgWrap:`。该包装器本身不解析服务器错误码，语义来自上游链路。 |

### 3.2 失败和重试

- 单条响应 ret 非 0：`0x1055685b0` 传入状态 5，更新该条消息状态，然后经 `ISendMessageExt` 广播 `OnSendMessageFail:`；block 为 `0x105568978`。
- `CMessageMgr OnSendMessageFail:` 的 IMP 为 `0x104981a94`，同样转为 `AsyncOnModMsg:MsgWrap:`，不是它自己定义错误码。
- `OnProtocolConnectFail:` 的 IMP 为 `0x105568c68`，先读 `canRetry`；`0x105568c9c` 在允许重试时跳过本次最终失败处理，不允许重试才调用 `HandleSendFail`。
- `HandleSendFail` 的 IMP 为 `0x105568d50`，设置相关消息状态 5，再安排失败广播。网络错误的首次通知不能无条件作为插件最终失败，更不能触发插件自动重发。

### 3.3 ABI 和参数范围

| 实际所有者 | selector | 编码 |
| --- | --- | --- |
| `SendMessageEventHandler` | `OnProtocolResponse:shouldContinue:` | `v32@0:8@16^B24` |
| 协议 `ISendMessageExt`；实现者包括 `CMessageMgr` | `OnSendMessageSuccess:` | `v24@0:8@16` |
| 同上 | `OnSendMessageFail:` | `v24@0:8@16` |

`OnProtocolResponse:shouldContinue:` 的第一个显式参数是协议包装对象，第二个是 BOOL 指针；结果广播的唯一显式参数是该条消息对象，不是一个 BOOL 成功值，也不是一组消息。`ISendMessageExt` 协议引用位于 `0x11f43fe18`，两项方法及编码均在其实际 optional instance method list 中。

## 4. 图片：上传与消息发送必须分开

### 4.1 上传完成并不是最终消息成功

`CMessageMgr AddMsg:MsgWrap:` 在 `0x1049713bc` 调用 `StartUploadImageMsg:MsgWrap:`；后者 IMP 为 `0x10497b47c`，经 `imageUploadMgrWithMsgWrap:` / `StartUploadImage:` 交给图片上传管理链。

这条入口与下文 controller 不是只靠类名拼接：`CMessageMgr init` 在 `0x10496d494` 创建 `ImageUploadUnifyMgr`，写入 `imageUploadMgrWithMsgWrap:`（IMP `0x10496dc04`）读取的同一 ivar；`ImageUploadUnifyMgr StartUploadImage:`（IMP `0x101ec2ab0`）在 `0x101ec2c68` 创建 `ImageUploadTaskController`，再调用 `initWithMsgWrap:delegate:` 并加入队列。

`ImageUploadTaskController onImageUploadTaskSucc:` 的 IMP 为 `0x101eb3314`：

- `isJustUploadDataWithoutMD5Hit` 分支可以直接通知上传完成，不走普通消息 CGI 发送。
- 普通分支检查 `isSendingImageMsg`，在 `0x101eb34d8` 设置其为 1，再调用 `sendImageMsg`。

因此 `onUploadTaskSuccess:` / `OnUploadMsgDataSuccess:` 不能脱离上游阶段直接当“消息发出”。`ImageUploadUnifyMgr onUploadTaskSuccess:` 还包含 `IsBypassMessage` 分支；`CMessageMgr onUploadBypassImageCdnFinish:` 只会继续 `StartSendMsg:`，也不是目标收到通知。

### 4.2 消息 CGI 和成功/失败结果

```text
ImageUploadTaskController sendImageMsg
  -> 生成图片消息请求
  -> WCCgiBlockHelper + WCBaseCgi，CGI 110 (0x6e)
  -> WCBaseCgi MessageReturn:Event:
     -> 检查网络消息状态、CGI 编号、响应和 baseResponse.ret
     -> didGetResponse:
  -> WCCgiBlockHelper baseCgi:didGetResponse:
  -> 成功 block
  -> ImageUploadTaskController onImageMsgSendSucc:
     -> response.newMsgId 写入自身 msgWrap
     -> 状态 2，百分比 100
     -> IMsgExt / OnMsgSendSuccess:，参数为 msgWrap
```

| 地址 / 方法 | 可核对的实际行为 |
| --- | --- |
| `0x101eb01f4`，`sendImageMsg` | 构造 `WCCgiBlockHelper` 的 init/start/success/fail 四类 block。 |
| init block `0x101eb0b6c` | 创建 `WCBaseCgi`；`0x101eb0b90` 传入 CGI `0x6e`，debugModuleName 为静态字符串 `UploadImgMsg`。 |
| start block `0x101eb0bc0` | 设 request，然后启动 baseCgi；不是把媒体上传完成直接当消息成功。 |
| `0x10690c9a8`，`WCBaseCgi init` | 默认 cacheType 为 0；`0x10690ca84` 将 `isTreatBaseResponseRetAsNetworkingRet` 设为 YES。上述图片 init block 没有关闭该项。 |
| `0x10690e74c`，`WCBaseCgi MessageReturn:Event:` | 非 0 `m_uiMessage` 走网络失败；检查返回 CGI 编号；要求响应存在；在上述默认选项开启时，`0x10690ec44` 只让 ret 为 0 走成功路径。选项关闭另有分支，不能泛化所有 WCBaseCgi 的成功 block 都代表业务 ret 为 0。 |
| `0x10690ef10` 起 | 成功路径调用 `didGetResponse:`；其 IMP `0x10690e494` 转发给 `baseDelegate` 的 `baseCgi:didGetResponse:`。 |
| `0x106ba4190`，`WCCgiBlockHelper baseCgi:didGetResponse:` | 调用成功 block，传入 helper、baseCgi、response；response 位于 block 的 x3，不是文字回调的协议包装参数。 |
| 成功 block `0x101eb0c5c` | 取上述 response，清除 sending 标志，在 `0x101eb0ddc` 调用 `onImageMsgSendSucc:`。 |
| `0x101eb19b0`，`onImageMsgSendSucc:` | 取自身 `msgWrap`；`0x101eb1c60` 传入状态 2、百分比 100；`0x101eb1c8c` 读取响应 `newMsgId`，`0x101eb1ca0` 调用 `setM_n64MesSvrID:`；随后更新消息及广播。 |
| `0x101eb2114` / `0x101eb211c` | 载入协议 `IMsgExt` 与 selector `OnMsgSendSuccess:`，通过 `callExtension:selector:block:` 广播。不是此处明确要求主线程的广播，接入端不能自行假定其执行线程。 |
| 广播 block `0x101eb23c4` | 从捕获的 controller 读取 `msgWrap`，在 `0x101eb2414` 调用接收者的 `OnMsgSendSuccess:`，显式参数是消息对象，不是 controller 或 response。 |

失败 block 为 `0x101eb0e00`，其参数区分 error 和 response，检查网络失败时会调用 `onImageSendCGIConnectFail:`，可能由宿主安排重试；否则进入 `onImageMsgSendFail:`（IMP `0x101eb127c`）。该方法还有 ret `0x66` 的重新处理分支，因此它每次进入也不等价于“最终失败”。`onTaskFail`（IMP `0x101eb15f8`）设置状态 5，并经 `IMsgExt` 广播 `OnMsgSendFail:`；实际广播 block 为 `0x101eb1940`，传入 msgWrap。

### 4.3 已核对 ABI，不补猜参数类名

| 实际所有者 | selector | 编码 |
| --- | --- | --- |
| `ImageUploadTaskController` | `onImageMsgSendSucc:` | `v24@0:8@16` |
| 同上 | `onImageMsgSendFail:` | `v24@0:8@16` |
| 同上 | `onImageSendCGIConnectFail:` | `B24@0:8@16` |
| `WCBaseCgi` | `MessageReturn:Event:` | `v28@0:8@16I24` |
| `WCCgiBlockHelper` | `baseCgi:didGetResponse:` | `v32@0:8@16@24` |
| 协议 `IMsgExt` | `OnMsgSendSuccess:` / `OnMsgSendFail:` | 均为 `v24@0:8@16` |

`IMsgExt` 协议引用位于 `0x11f43f9b0`。目前确认的是 response 对象被读取哪些 selector 及其来源链；没有取得当前版本该对象的真实运行时类和字段 ABI，不根据 `UploadImgMsg` 字符串猜参数类名或结构体布局。

## 5. 排除的伪证据与插件现状

- 不能因为找到 `MessageReturn:MessageInfo:Event:` 就认定它是消息结果。完整类方法索引显示头像、账号等多个模块也实现它；此前 Mikoto 的同名 hook 未建立发送所属类及调用链，不能作为消息回执证据。
- `CMessageMgr OnMessageSentBySender:` 与 `OnErrorBySender:ErrNo:` 本轮没有建立到普通文字/图片服务端响应的同等链路，不因名字把它们选为通用确认入口。
- `AsyncOnModMsg:MsgWrap:` 和 `ModMsg:MsgWrap:` 是更宽泛的修改通知，不能每次触发就判定发送成功。
- `status == 2` 和非零 server ID 在上述特定成功路径中确实被写入；这不证明它们在所有来源、类型、历史回读和其他版本中都有相同含义。不能用历史消息带 server ID 替代本次发送的关联响应。
- 当前 `Adapter/SRWeChatTextSendHost.m` 与 `Adapter/SRWeChatImageSendHost.m` 调用 AddMsg 后只做精确 local-ID 回读，最后仍返回 `uncertain` / `submitted_delivery_unknown`。源码核对未发现其消费上述成功/失败广播。**这说明插件尚未接入此类结果，不说明宿主没有结果。**
- 服务器发送成功响应不包含本轮已证明的收件端设备确认或群成员已读证据；不得把“服务端确认”写成“所有目标成员已送达”。

## 6. 当前版本还需要什么

下一步先取得与设备实际微信版本/构建一致的解密 IPA 或主程序 WeChat；如设备版本变动，以新记录为准，不盲用历史 `8.0.79.35`。不需要账号凭据、聊天数据库、消息正文或媒体文件。

同版静态核对必须重新确认上述类、协议、selector、类型编码、响应分支和图片路径；不能只比对方法是否存在。之后才能确定最小范围的运行时验证：实际 receiver/proxy、回调参数类、线程、AddMsg/结果通知的先后、原消息关联，以及宿主重试后的最终结果。现有设备记录中的消息服务属于 NSProxy 体系，不能假定直接给 CMessageMgr 加 hook 就必然覆盖真实调用。

在这些条件满足前，不新增生产确认状态、不升级历史记录、不自动补发，也不让 UI 先显示“已送达”。若以后接入，只能对本次账号、目标、消息、run 和 generation 精确关联；重复通知幂等，晚回调或身份不匹配拒绝，进程退出/观察超时不能冒充失败或成功。

## 7. 本轮校验层级

- 主程序 SHA-256 已重新计算并与样本记录匹配。
- 离线复核脚本通过 30 项静态断言，涉及方法编码/IMP、协议和 selector 引用、关键条件分支与赋值指令、`objc_msgSend` 最终导入；结果在本地 `verified-anchors.json`。
- 这些断言只是所分析文件的静态证据复核，不是 Objective-C 原生测试、生产构建或设备回调验证。
- 本轮只新增调查文档，未修改生产行为，因此未重跑与本次调查无关的 UI/Core 测试；此前测试结果也不被用来证明微信回调语义。

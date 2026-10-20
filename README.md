# SyncRelay

微信母群消息手动分批转发插件，目标环境 iOS 16.0.3、微信 8.0.76 / 8.0.79。

## 当前状态：0.1.0 开发骨架

本版本不是可用的群转发成品，没有设置入口、成员读取、消息捕获或发送能力。
注入后只创建独立 SQLite 数据库并将中断批次恢复为待手动继续；不会向任何群发消息。

已编写的模块：

- `Core/SRStore.m`：计划、互斥分组、独立执行批次、持久化状态、暂停/恢复、重新执行、结果关联。
- `Core/SRPacing.c`：至少 10 秒的随机节拍计算，单调时钟输入，恢复时不补发错过节拍。
- `Tweak/SRBootstrap.m`：仅在微信主进程初始化存储，不注入扩展进程。
- `tests/`：直接调用生产核心的测试。模拟确认不是微信真实回执。

尚未实现：微信适配、wxid 列表、来源/类型过滤、界面、实际调度循环、失败补发 UI/策略、媒体缓存、常亮与设备验收。
`SRStore` 的 claim 是存储层操作；接入发送器时必须先经过节拍、单账号身份和适配可用性检查。
传入 confirmed 只说明调用方声称已验证结果；未来适配器必须提供实际确认依据，消息 ID 本身不证明服务器已接收。

## 编译

沿用相邻 OwnHide 项目的私有 GitHub Actions/macOS + 固定版本 Theos/SDK 方式。
工作流：`.github/workflows/build.yml`。先运行 C 和 Objective-C 核心测试，全部通过后构建普通 DEB，检查 arm64/arm64e slice 并上传私有 Actions artifact。

普通包载荷位于 `Library/MobileSubstrate/DynamicLibraries`。不附带安装脚本，不自动重启微信，不发布 GitHub Release。
包不包含第三方 MikotoHelper 二进制、反汇编输出或本地工具缓存。

macOS 本地核心测试：

```sh
clang -std=c11 -Wall -Wextra -Werror -I. Core/SRPacing.c tests/pacing_test.c -o /tmp/sr-pacing
/tmp/sr-pacing
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I. Core/SRStore.m Core/SRPacing.c tests/store_test.m -framework Foundation -lsqlite3 -o /tmp/sr-store
/tmp/sr-store
```

完整需求和真实进度见 `开发需求与进度.md`。两版微信兼容性目前均未真机验证。

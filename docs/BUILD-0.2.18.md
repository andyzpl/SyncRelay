# 0.2.18 节奏调整交付记录

日期：2026-10-21。状态：普通 DEB 已构建并独立核验，待用户覆盖升级后进行真机节奏回归；本轮仍不扩大每条规则 1–3 个授权群的检查范围。

## 确切构建

- 源码：`76eb1240c59e5876905c3a99849f0128dd6cf534`。
- [公开 macOS CI 39605044161](https://github.com/andyzpl/SyncRelay/actions/runs/39605044161)，artifact `12347983752`；测试、普通 DEB 构建和包核验均成功。
- 普通 DEB：`dist/0.2.18-test-39605044161/andyz.syncrelay_0.2.18_iphoneos-arm.deb`，275384 字节，版本 `0.2.18`，架构 `iphoneos-arm`。
- DEB SHA-256：`72c13c4aaabc6b688acca0aa2dc37f0cecfc04a54c6196c390a1aefa6ff670ff`。
- artifact ZIP SHA-256：`1d5e0b92e157feea63b4f65aca72a84f054be3fad8826d389c6f14d5b3621907`。

## 回归与包核验

- CI 实际日志通过 66 项 Python 测试、52 条原生 `PASS`；包括 3 秒节拍边界、5–10 秒默认值、旧规则表迁移和 pending-only 恢复。
- 下载后检查 Debian ar、control/data 载荷集合、包和附件摘要、双架构 Mach-O、代码签名载荷及注入 plist。仅包含 `SyncRelay.dylib` 和对应 plist，过滤目标为 `com.tencent.xin`；依赖仅系统框架和 `firmware (>= 15.0)`。
- arm64 slice 640896 字节，arm64e slice 657504 字节；两架构均存在签名载荷，不依赖 Mikoto 或其他第三方二进制。
- `deviceVerified=false`：编译和包核验不等于已在本机注入或已确认真实群送达。

## 本轮行为

- 最低间隔为 3 秒；下限小于 3 或上限小于下限会被拒绝。
- 新建规则默认下限 5、上限 10 秒；上下限相同为固定间隔，上限仍可自定义。
- 已保存账号配置、已冻结计划和运行快照不会因覆盖升级被静默改写；需要改变时在设置页重新保存。
- schema 8 只兼容迁移旧 `rules` 间隔约束，保留计划、配置、历史、媒体和防重复占位。

手机检查步骤见 `docs/DEVICE-CHECK-0.2.18.md`。先验证新规则默认值、3–3 可保存、2–10 被拒绝，再用 1–3 个授权测试群回归文字/图片、暂停继续和重启后的 pending-only 恢复。

# 0.2.31 夜间收口记录

日期：2026-11-15。范围：离线 UI/Core 收口；不新增微信 selector/ABI，不开放视频、动态媒体、后台续跑、自动重发或 100/200 群真实发送。

## 实际修改

- 历史运行记录可进入账号绑定的目标群明细页；每个目标显示未发、在途、已提交（未确认送达）、已确认送达、失败、待核对或已取消。
- 图片历史详情只从已保存并校验的本地快照读取缩略图；账号变化、快照缺失或校验失败时不替代、不主动读取宿主图片。
- 自动生成的 100/200 群规则记录 grouping capacity 和 `auto` 来源；已有规则对象（包括旧自定义名称）原样保留，生成顺序仍按 100 群配方再按 200 群配方。
- 目标明细和源快照读取均绑定账号与 run，列表投影不携带正文或源快照。

## 证据边界

- Python 契约与回归：`py -3 -m unittest discover -s tests -p '*_test.py'`，241 项通过。
- `git diff --check` 通过。
- 本轮运行环境为 Windows；没有 macOS Foundation/UIKit、clang 或固定 iPhoneOS SDK，因此未执行 Objective-C 原生编译、双架构语法、生产打包或 DEB 载荷核验。
- 指定的 `docs/WECHAT-SEND-RESULT-RESEARCH.md` 不存在；发送 ABI 仍以现有 `docs/MIKOTO-SEND-EVIDENCE.md` / `docs/SEND-PROBE.md` 为准，未新增宿主假设。
- 未安装、操作手机、重启微信、代发消息或清理设备数据；没有新增真机证据。

## 版本与产物

- 分支：`codex/nightly-closeout-20261115`
- 提交：`a739eb0` 及后续缩略图收口提交（均已推送到 `origin`）
- DEB：未生成。仓库工作流只在 `main` push 或手动 `workflow_dispatch(build_deb=true)` 构建；本环境没有 `gh`、GitHub token 或 macOS 构建机，无法安全触发手动构建。不得把 Python/静态结果写成包或真机通过。

明早若取得包，先核对 control 版本、arm64/arm64e、源码 commit/run、DEB SHA-256 和载荷过滤，再按现有小群前台步骤实测；本轮改动本身不扩大真实发送范围。

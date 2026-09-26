# 双模式本地候选包验收

日期：2026-09-26。**宿主、归档及受控 Probe 双模式真机验收通过**。未发布版本、推送远端、更新插件或替换 Logo。

后续[标准模式备忘录工作流验收](standard-notes-workflow.md)验证了中文多行插入、替换及页面往返，同时发现媒体截图失真和黄色光标误拒绝；该真实 App 工作流尚未全部通过，不扩大下述 Probe 验收结论。

## 候选包身份

- 版本：`0.1.0-dev.dualmode.20260926.1`，macOS arm64。
- 源提交：`f9c78bca52f25e78add7f75e5264d9b6f5c5a460`，`sourceDirty=false`。
- 归档 SHA-256：`b2549692367c9f8049b711a2ed946ff5d08f48bd8ec969ce6731dc28fd2c14aa`。
- Runner 内容摘要：`6d7ffaa343b6ea9dfeaf1e6098aae9b233a066b3d310c61a490082351e1d50b5`。
- CLI 为本地 ad-hoc 签名，未公证；包内 Runner 未携带开发签名，实际使用需合法签名准备。

本候选包含截图源固定、方向重新同步，以及录屏静止尾帧持续时间修复。功能证据见 [截图来源策略](native-capture-source-policy.md)、[截图性能与方向](native-capture-performance.md)、[共享录屏](runner-recording.md)和[录屏时间线](native-recording-timeline.md)；这些已有源码级真机证据不等同于本候选包的真机验收。

## 本轮已执行

- 以 `build-release.py --require-clean` 构建 Release CLI 和独立 Runner；构建前后确认源提交及工作区干净。
- `verify-release.py --require-clean` 验证归档校验和、文件清单、Runner 摘要、路径安全、签名及源码路径泄漏，并在源码外含空格目录搬移执行。
- 搬移后的命令版本、帮助、兼容入口和软链接入口检查通过；动态链接依赖均来自系统目录。
- 隔离配置下默认 `standard`，只读查询不创建偏好；两种模式的显式保存读取通过。
- 为真机验收再次独立解压到源码外含空格目录，包内 CLI 成功发现唯一有线连接的配对 iPhone；全新配置返回 `standard` / `default` / `saved:false`，配置目录未创建。
- Python 宿主测试 **48 项通过**。本轮未修改产品源码，未重跑完整 Swift 套件；最近功能提交 `96f5295` 的结果为 316 项执行、315 项通过、1 项既有跳过。

宿主环境为 macOS 27.0 (26A428)、Xcode 27.0 (27A266a)。只读设备检查发现 iPhone 12 Pro / iOS 27.0。最初 Apple 返回 `passcodeRequired=true`，因此暂停真机操作；用户解锁就绪后完成下述验收。归档校验工具自身仍返回 `deviceVerified:false`，真机证据单独记录。

## 标准模式真机验收

所有命令均使用源码外独立解压的包内 CLI、隔离配置及工作目录，没有调用开发 `.build` 二进制。省略 mode、尚未运行 setup 时连接成功：`standard` / `default`、`controlAvailable=true`、`runnerStarted=false`。首次连接保存 standard 偏好。

- 打开普通 Probe 后，媒体截图 `o1` 显示 A=9、B=4、C=4、D=3，屏幕为 390×844 points。
- 首次点击前没有及时获得完整新媒体帧，截图来源转为 Apple PNG；保护返回 `stale_observation` / `not_dispatched`，未发送触控，并附上 `o2`。会话截图策略固定为 `coredevice_only`，原因 `no_fresh_complete_frame`。
- 目视核对 `o2` 后，基于新观察选择 `(71, 122)` points 点击 A。屏幕保护通过，触点释放已排队；新截图 `o3` 确认 **A 从 9 变为 10**，其余计数不变。
- 输入结果保留 `unknown` / `native_input_unacknowledged`、CLI 退出码 1；成功结论来自实际截图变化，没有重放未知输入。断开确认自有媒体 UUID 停止、接收器和连接关闭、隧道释放；另外核对宿主已退出、观察缓存已删除。

## Runner 点击与共享原生录屏

`setup` 使用包内 Runner 与已有合法签名产物，返回 `compiled:false`、`reused:true`，验证连接、截图采集和断开。Runner 摘要与本候选一致。显式 `--mode runner` 连接时未提供源码 `.xctestrun`。

- 打开 Probe 并查看截图后，以 90 秒为上限开始自有原生媒体录屏。开始后重新观察，使用 `o2` 的 `(71, 122)` points 通过 Runner 点击 A 一次；动作完成且判稳，新截图确认 **A 从 10 变为 11**。
- 手动停止本次录制 ID：宿主录制 73.309 秒，MP4 **73.300 秒**，1184×2576，完整解码 **2284 帧**。无时间戳不连续或畸形包，有 1 个启动阶段丢弃单元。
- 最后真实帧位于视频约 68.337 秒，正常停止时媒体健康，末帧显示持续时间为 **4.964 秒**，`tailTimingSource=host_monotonic_receive`。没有缩放已有帧时间戳或制造新帧。
- 使用自写 Apple AVFoundation 验证器精确抽取视频第 1、55、72 秒：目视确认第 1 秒 A=10，第 55 秒和尾帧保持区间第 72 秒 A=11，画面方向正常，均为 Probe。视频文件完成与解码状态不是点击成功的唯一证据。
- 停止前后 Runner PID 与会话标识相同，`hidServiceOpened=false`；自有媒体 UUID 停止、接收器关闭和隧道释放已确认。最终正常 disconnect，无强制结束；另行确认宿主和 xcodebuild 已退出、观察缓存已删除。
- setup、显式 Runner 连接及断开后，隔离配置仍为 `standard` / `configuration` / `saved:true`。逐文件对比确认解压后的包内容未被签名准备或验收修改。

原始归档、构建日志、宿主测试、设备结果、截图、MP4、抽帧、清理记录及证据摘要保存在 `.local/research/dual-mode-package-20260926/`。不提交私人设备标识。本轮验证固定竖屏、受控 Probe 点击及录屏共存；不代表全部手势、所有 App 或其他设备兼容。全新 Mac 首次配对、下载隔离/Gatekeeper、公证及公开分发不在本轮范围。

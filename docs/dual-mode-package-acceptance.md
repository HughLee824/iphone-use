# 双模式本地候选包验收

日期：2026-09-26。当前阶段：**宿主与归档验证通过，新候选包的真机动作验收待解锁后执行**。未发布版本、推送远端、更新插件或替换 Logo。

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

宿主环境为 macOS 27.0 (26A428)、Xcode 27.0 (27A266a)。只读设备检查发现 iPhone 12 Pro / iOS 27.0，Apple 锁屏状态为 `passcodeRequired=true`。本轮尚未启动候选包设备会话、发送触控或录制视频；包检查结果保持 `deviceVerified:false`。

## 待完成的真机验收

解锁并停留在普通 iPhone-use Probe、释放其他控制客户端的媒体会话后：

1. 使用独立解压的包内 CLI、全新配置，省略 mode 连接标准模式，确认不启动 Runner。目视读取截图后选择坐标，只点击一个 Probe 目标，以新截图计数变化验证；原生输入返回 unknown 时不重放。
2. 使用同一包内 Runner 完成合法签名准备，显式选择 Runner 模式；验证一次 Probe 点击与自有原生媒体录屏共存，检查实际视频画面和时间信息。
3. 断开各自会话，核对媒体所有权、宿主退出和观察缓存清理；确认显式 Runner 选择未意外改变标准模式偏好。

原始归档、构建日志、宿主测试、只读设备结果和进度记录保存在 `.local/research/dual-mode-package-20260926/`。不提交私人设备标识。全新 Mac 首次配对、下载隔离/Gatekeeper、公证及公开分发不在本轮范围。

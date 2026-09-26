# 标准模式首次使用与本地包验收

日期：2026-09-26。本轮实现标准模式默认入门路径、Runner 可选签名路径和隔离配置验收；未发布版本、推送远端或更新客户端插件。Logo 保持不变。

## 实现

- 中英文 README、首次任务、安装说明和 onboarding 以标准模式开始；只有 Runner 才要求签名与 setup。明确当前原生适配器要求 macOS/iOS 27、完整 Xcode、配对、Developer Mode 与解锁。
- CLI 的 setup、connect、config、observe 帮助与双模式一致。点击坐标沿用屏幕 points 契约，文档说明从原 PNG 尺寸映射，不能直接传像素或缩放预览坐标。
- 可选 `IPHONE_USE_CONFIG_DIR` 指定绝对配置目录，覆盖时不迁移旧用户偏好或推断已有 Runner 准备状态；不改变设备锁、系统配对或 Runner 签名目录。默认目录仍为 `~/.iphone-use`。
- 包校验在含空格的源码外临时目录执行，确认空配置默认 standard、只读 get 不写文件、两种模式可保存，并在任何 set 前确认实际配置路径。检查 Mach-O 链接库仅来自系统；不将帮助、签名或归档成功当作真机验证。
- 原生 Swift/C/Objective-C 桥接编入 CLI，没有额外研究文件或第三方设备工具运行依赖。系统 RemoteXPC、AVConference 和 Xcode 安装的 CoreDevice 服务/元数据仍是运行前提；它们不随包分发。

## 宿主与包验证

相关 Swift 测试 29 项通过（模式配置、旧名迁移、Runner 包准备）。Python 完整套件 47 项通过；补充隔离配置 CLI 回归后，模式 CLI 7 项通过。测试覆盖已有损坏偏好/Runner 记录不污染隔离目录、非法目录拒绝、两种偏好读写及拒绝非系统动态库。`git diff --check` 通过。

最终本地候选为 `0.1.0-dev.standard.20260926.2`，归档 SHA-256：

```text
0e0ed273cb0046cb3edee68613bf06e5877d60177be0063e4cff83dd195ff64c
```

它从本轮未提交工作区构建，`sourceDirty=true`，不是公开发行包。Release CLI 与无开发签名 Runner 构建成功；归档、签名、源码路径泄漏检查、搬移后软链接入口、新旧命令版本及模式隔离检查通过。`verify-release.py` 返回 `deviceVerified:false`，真机结果单独记录。

## 真机进度

环境为 Apple Silicon / macOS 27.0 (26A428)、Xcode 27.0 (27A266a)、iPhone 12 Pro / iOS 27.0 (24A437)。设备通过本次候选 CLI 发现，未将设备标识写入产品。执行的 CLI、工作目录与配置目录都位于源码目录外；保留共享设备锁以免隔离验收绕过互斥。

- 首个候选省略 mode、未运行 setup、未提供 xctestrun，成功选择 `mode=standard` / `modeSource=default`，`runnerStarted=false`。原生截图成功，但媒体被占用，`controlAvailable=false` / `native_media_busy`。未发送点击，自有媒体/隧道及宿主均确认清理；发现 Device Hub 进程，但进程存在本身不能证明某个流的所有者。
- 最终候选的包内 Runner 使用已有合法开发签名完成 setup，返回 `compiled:false`，验证连接、截图采集和退出。显式 `--mode runner` 使用同一包重签产物连接成功，打开普通 Probe，截图已目视确认，正常 disconnect。没有使用源码 `.xctestrun` 代替包内产物。
- setup 与显式 Runner 连接后，隔离配置仍返回 `standard` / `default` / `saved:false`，没有将默认模式改成 Runner。
- **标准模式首次点击闭环尚未验收通过**：等待用户释放测试设备的其他媒体连接后，在最终候选上重新执行空配置默认连接、Probe 截图、一次点击及清理。不能把源码后端过去的成功测试或本次 Runner 回归代替这项验收。

原始归档、日志、截图和 JSON 保存在 `.local/research/standard-package-onboarding-20260926/`，不提交私人设备信息。全新 Mac、无既有配对的首次信任、免费签名、浏览器下载/Gatekeeper 和公开 Homebrew 渠道不在本轮验收范围。

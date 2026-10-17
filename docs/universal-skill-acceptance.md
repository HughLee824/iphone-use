# 通用 skill 验收（0.1.12）

## 安装与冲突处理

`iphone-use-skill` 是独立 npm 包，发布内容由 `scripts/build-skill-package.py` 从唯一的 `skills/iphone-use` 源生成。它不包含 iPhone-use CLI，也不修改已有三个客户端的插件。

- 安装器 11 项测试通过：包括实际 npm 打包执行、重复安装、冲突/同源别名、更新/降级、卸载、用户文件保护。
- 本机从生成的 tgz 通过 `npm exec --package=… -- iphone-use-skill install --agent cursor --project …` 安装成功；再次安装返回 `already-installed`，检查为 `managed`、0.1.12、无冲突。
- 完整 Python 测试 61 项通过；最终 Node 测试 57 项通过、1 项跳过；CI 包含共享 Node 测试、安装器测试及 Runner 编译。
- DeepSeek Harness 实际 Electron 运行时回归测试 5 项通过。

检查范围仅覆盖已知文件系统发现目录；团队/远程注入、额外自定义目录和显式加载的插件仍需核对客户端实际目录。OpenCode 当前只验证安装与冲突处理，不能据此声称它已通过模型驱动的真机任务。

## Cursor 模型驱动验收

环境：Cursor Agent CLI 2026.10.16-e3cb207、本机默认模型、iPhone-use CLI 0.3.7。从临时项目的 `.cursor/skills/iphone-use` 加载工作流 0.1.12 与 `references/generic-agent.md`，使用原生 Shell / Read 工具。

Cursor 认证需要能写入 macOS Keychain。项目命令权限通过临时项目 `.cursor/cli.json` 配置；CLI 必须从该项目目录启动，仅传 `--workspace` 不保证加载该目录的命令权限。没有修改用户全局权限，也没有使用 unrestricted/force 模式。

早期执行因项目权限未加载或复合命令未匹配白名单，在 preflight 处停止，未连接手机。改为从验收项目启动并逐条执行已授权命令后通过。CLI 输出由外层 stream-json 日志保留，不需要通过重定向或管道再次保存。最终真机验收通过：

1. 发现有线 iPhone 12 Pro（iOS 27.0.1），按保存配置建立 Runner 会话，未切换模式或重新安装 Runner。
2. 启动默认本地预览；通过应用查询发现 Settings，打开设置后读取 Accessibility 页面 PNG。
3. 根据当前截图与 Runner 引用返回 Settings 首页；读取新 PNG，点击 General，再读取第三张 PNG 确认页面。两次导航 tap 均返回 `completed`，未修改设置。
4. Cursor 原生 Read 对三张 PNG 均返回非空图片 blob；每张图在下次操作前复制到本机证据目录。外层保留九份 CLI JSON 回执，执行方复核最终 PNG 可见 General 页面。
5. 断开本任务会话成功：`shutdownAcknowledged`、`runnerProcessExited`、`recordingCleanupAcknowledged`、`mediaStopAcknowledged`、`receiverClosed`、`tunnelReleaseAcknowledged`、`observationCacheRemoved` 均为 true。默认浏览器可能保留已停止预览的标签页；未声称自动关闭标签。

此验收只覆盖 Cursor 在上述 Mac/真机环境中的 Runner 导航；未验证标准模式、文本输入或其他客户端的真机任务。

原始 CLI 回执、Cursor 执行日志及截图仅保留在本机临时验收目录，不提交设备标识或手机画面。

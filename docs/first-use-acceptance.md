# 首次使用流程收口

2026-10-01。本轮复用现有安装、设备发现、模式配置和连接命令，未新增 doctor、配置层或引导系统。未发布版本、推送远端或更新插件。

后续已构建包含本次修复的[最终本地候选包](first-use-candidate-acceptance.md)，并完成该归档的两种模式最短真机验证；下文保留源码阶段证据。

## 修改

- 安装文档优先说明实际提供的本地候选包校验、解压和完整目录安装；尚未发布的新 Homebrew/下载渠道移到单独的未来入口，不再用旧 AgentSoma 0.1.0 推断新包版本。
- README 两种语言、首次任务和 connect 帮助明确标准模式无需 Runner 签名/setup，完整 Xcode 是两种模式共同要求；标准模式连接还需检查 `controlAvailable`，不能仅看 `ok:true`。
- CoreDevice 保留原始错误及阶段，区分无法找到 devicectl、无效/缺失开发目录和未接受 Xcode 许可，给出对应处理步骤。
- 原生连接的既有前置校验失败时，仅当 Apple 明确报告 unpaired / disabled 才返回 `device_not_paired` / `developer_mode_disabled`；缺失或未知字段仍返回 `native_device_unavailable`，不猜测权限状态。
- 媒体占用提示要求用户结束其他客户端会话、清理自己的观察会话并显式重连。Runner 超时提示检查实际授权提示及日志，不把超时本身归因为权限。

没有修改输入、判稳、媒体互斥、模式优先级或自动恢复行为。未调用 stopAll，未自动完成系统授权。

## 宿主验证

完整 Swift 测试执行 340 项，339 通过、1 项既有跳过、0 失败。随后以进程级 `DEVELOPER_DIR` 指向不存在的临时目录，实测 xcrun 的原文为 `missing DEVELOPER_DIR path`，补充该分支后定向 Discovery 9 项通过。新增 CLI 回归测试确认此错误返回 `xcode_unavailable`、保留 Apple 原文，且不创建配置或会话目录。没有修改系统 Xcode 选择。

最终 Python 测试 49 项通过，Node 模板测试 15 项通过，插件同步检查通过。首轮受限执行中的 SwiftPM `sandbox_apply: Operation not permitted` 留有日志；获准在正常宿主权限下执行后得到上述测试结果，不将其误记为产品测试失败或设备授权失败。

按安装文档的校验、解压、移动完整目录和建立软链接步骤，在含空格的 `/private/tmp` 目录完成一次安装演练；仅将文档中的 `$HOME/.local` 目标替换为临时测试目录，未修改真实用户安装。使用已有 `0.1.0-dev.media.20261001.1` 包，校验和通过、命令版本正确，全新配置查询返回 `standard/default/saved:false`，不创建偏好目录。此项验证安装说明，不代表该旧候选已经包含本轮源码修改。

## 真机最短流程

实际环境重新检查为 macOS 27.0 (26A428)、Xcode 27.0 (27A266a)，动态发现有线 iPhone 12 Pro / iOS 27.0 (24A437)。最初只读检查报告锁屏，用户解锁并停留在 Probe 后才继续。

使用本轮构建的 Debug CLI、源码外含空格工作目录及全新 `IPHONE_USE_CONFIG_DIR`：

1. 只读配置查询为 `standard/default/saved:false`。省略 mode 连接后，`mode=standard`、`modeSource=default`、`controlAvailable=true`、`runnerStarted=false`。
2. 标准模式截图实际显示 Probe 的 `Double 1 / Single 1`。没有发送点击或文本；随后停止自有媒体、接收器和隧道并断开。
3. 显式 `--mode runner --xctestrun` 复用之前合法签名的兼容 Runner，通过 CoreDevice 连接。实际 XCTest 截图同样显示 Probe、计数不变。未指定应用目标，元素状态为 `axStatus=unavailable` / `foreground_app_unknown`；本轮验证截图，不将其计为元素读取成功。未重复 setup、重签或编译 Runner。
4. Runner 正常断开，shutdown 确认，xcodebuild 退出码 0、`forced:false`。独立检查两种模式宿主、Runner 的 xcodebuild 进程已退出，`ipc.sock` 与观察缓存已删除。
5. 最终隔离默认配置仍为 `standard/configuration/saved:true`。显式 Runner 连接未改变默认模式。

真机验证执行于最后补充的 `missing DEVELOPER_DIR path` 分类前；之后仅增加该宿主错误匹配及回归测试，没有再重复设备流程。未撤销设备配对、关闭 Developer Mode 或制造媒体冲突；这些错误分支使用宿主受控输入验证，不声称在真机上触发过。也没有重新验证全新 Mac 首次配对、签名准备、Gatekeeper 或公证分发。

私有证据在 `.local/research/first-use-20261001/`，包含实际工具/设备结果、构建测试日志、安装演练、错误复现、两种模式的截图/快照/连接及退出事实和证据摘要。仅脱敏结论提交仓库；本轮没有重新打包候选。

# 首次使用修复候选包验收

2026-10-01。**最终本地候选 `0.1.0-dev.firstuse.20261001.2` 已完成归档、搬移、隔离配置、新错误提示及两种模式的连接/截图/清理验证。** 保留同一归档供后续试用，不发布、推送、创建 tag 或更新插件。

## 固定候选身份

- 架构：macOS arm64。
- 源提交：`4baf9a182a8bc088ac516966eab28b122c03fe6f`，`sourceDirty=false`，包含 `f1c1cd9` 的首次使用修复。
- 归档：`iphone-use-0.1.0-dev.firstuse.20261001.2-macos-arm64.tar.gz`。
- SHA-256：`163f6ad1acf714da15b43db21ce3bf32e417cab0f396677733f56d8aace9ef6f`。
- Runner 摘要：`c50a7d9dc8930320716ec1c02261813713f3b230bec8cef68c71d2677cb571e6`，与上一媒体候选相同。
- CLI 为 ad-hoc 签名，未公证；包内 Runner 无开发签名，用户的签名准备保存在包外。

归档与校验和位于 `.local/research/first-use-candidate-20261001/final/package/`。固定交付上述归档，不将后续文档提交或旧包重命名为它。

## 构建和宿主检查

`build-release.py --require-clean` 在构建前后确认干净提交，构建 Release CLI 和隔离的 unsigned Runner。`verify-release.py --require-clean` 检查校验和、归档路径、清单、签名、源码路径泄漏、许可证及动态链接依赖，并在含空格目录执行搬移、软链接入口、兼容命令和隔离模式读写检查。Mach-O 依赖均来自系统目录。

为设备验收另行解压到 `/private/tmp` 含空格目录，通过该目录的软链接执行包内 CLI，工作目录也在源码外；没有调用 `.build`。全新隔离配置只读查询返回 `standard/default/saved:false`，不创建偏好目录。临时 `DEVELOPER_DIR` 指向不存在的目录，实际 xcrun 错误被新包分类为 `xcode_unavailable`，保留 Apple 原文并给出工具链处理指引；未修改系统工具链配置或启动设备会话。

本轮打包宿主测试 18 项全部通过。未修改产品代码、未重跑完整 Swift/Python/Node 套件，沿用[首次使用修复](first-use-acceptance.md)的代码验证：Swift 340 项执行、339 通过、1 项既有跳过；最后错误匹配补充后 Discovery 9 项通过，Python 49 项、Node 15 项和插件检查通过。归档工具的 `deviceVerified:false` 仍指工具本身未测试设备，真机证据独立记录如下。

第一份 `.1` 候选已通过两种模式的最短流程，但随包 README 中存在指向未打包文档的相对链接。修复仅限安装文档：明确延伸内容位于源码仓库，补入常见错误处理表，移除无效本地链接。保存为 `4baf9a1` 后重新构建 `.2`，重复该归档的搬移及最短设备流程；没有替换 `.1` 的文件或将其真机证据当成 `.2` 的结果。

## 真机验证

重新检查宿主为 macOS 27.0 (26A428)、Xcode 27.0 (27A266a)，Apple 动态发现有线测试 iPhone。设备仍为 iPhone 12 Pro / iOS 27.0。最初锁屏，用户解锁并确认 Probe 就绪后继续。没有硬编码设备标识，也没有输入、手势、剪贴板访问或设置变更。

| 模式 | 最终 `.2` 包实际结果 |
| --- | --- |
| standard | 未运行 setup、省略 mode 连接，返回 `modeSource=default`、`controlAvailable=true`、`runnerStarted=false`；媒体截图来源 `native_media`，1170×2532，目视确认 Probe 和 `Double 1 / Single 1` |
| runner | 先正常关闭标准会话，再显式 `--mode runner`，没有传源码 `.xctestrun`；新包直接复用包外已有合法签名准备，无需 setup 或重新签名。`native-coredevice` 连接，XCTest 截图目视确认 Probe 和相同计数 |

本轮 Runner 未指定目标应用，快照为 `axStatus=unavailable` / `foreground_app_unknown`；截图成功不算元素读取成功。两模式的图片来自不同采集链路和时间，仅核对页面与计数，不声称逐像素相同或已经重新验收手势、文本和录屏。

标准模式 disconnect 确认自有媒体停止、接收器/连接关闭、隧道释放与 shutdown。Runner shutdown 确认，xcodebuild 退出码 0，`forced:false`。另外检查两种宿主及 xcodebuild 已退出，`ipc.sock`、观察缓存已删除。未调用 stopAll 或关闭其他客户端。

结束后隔离配置仍为 `standard/configuration/saved:true`；显式 Runner 连接未改默认模式。对比解压后与验收后的逐文件摘要一致，未向包内写入签名或修改载荷。

## 证据与边界

最终 `.2` 的构建/归档校验、搬移上下文、诊断错误、两种模式连接、PNG/快照、disconnect/exit、包前后摘要及证据清单位于 `.local/research/first-use-candidate-20261001/final/`。`.1` 的对应证据保留在上一级，不能混用版本或摘要。私人设备标识、原图和签名资料不提交仓库。

此次完成本地候选交付，不扩展全新 Mac、首次配对、首次签名、其他 OS/设备、Gatekeeper 或公证分发范围。完整文本/手势/录屏证据仍属于[上一媒体候选](runner-candidate-acceptance.md)；本轮按任务范围仅验证新包最短接入流程。

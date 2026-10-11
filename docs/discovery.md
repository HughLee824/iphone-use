# 设备/App 发现与完整 CLI 调用

设备发现通过 Mac 上的 `xcrun devicectl list devices`，App 发现通过 `devicectl device info apps --include-all-apps`。读取 Apple 工具的 JSON 文件，不解析显示表格，不增加第三方运行工具。Xcode 16 所带工具的本地 `help` 明确将 JSON 文件列为脚本消费接口；字段依据原生设备输出映射。

## CLI 契约

```sh
iphone-use devices
iphone-use connect --device "$DEVICE_ID" --xctestrun "$SIGNED_XCTESTRUN"
iphone-use --session "$SESSION" apps
iphone-use --session "$SESSION" apps --offset 50
iphone-use --session "$SESSION" apps --query Settings
iphone-use --session "$SESSION" open com.apple.Preferences
iphone-use --session "$SESSION" observe
# agent 读取返回的 PNG，使用本次实际返回的元素引用执行动作，再 observe。
iphone-use --session "$SESSION" disconnect
```

`devices` 无需会话，返回 CoreDevice 已知的设备，并不等于所有设备此刻都能建立会话。`id` 优先使用 UDID，缺失时使用 CoreDevice identifier；它们都可用于 connect。名称、系统版本、平台、设备类型、连接方式、隧道和配对状态只映射原生返回值，缺失字段为 `null`。不推测锁屏或会话就绪状态，也不把曾配对设备排除出列表。

示例节选（设备 ID 为占位值）：

```json
{"ok":true,"result":{"devices":[{"id":"DEVICE_UDID","name":"iPhone 12 Pro","osVersion":"26.6","platform":"iOS","deviceType":"iPhone","connection":{"transport":"wired","tunnelState":"disconnected","pairingState":"paired"}}]}}
```

`apps` 使用会话已确认的规范 UDID，由 Mac 查询安装元数据。每项仅返回 `name` 和 `bundleId`，名称未知为 `null`。按 bundle ID 排序，每页最多 50 项；`--query` 对名称或 bundle ID 做不区分大小写的子串匹配，`--offset` 用于同一查询的后续页。`total` 为匹配总数，末页 `nextOffset` 为 `null`，无匹配返回空数组。字段映射和分页上限由宿主实现。

实际筛选响应的 result：

```json
{"apps":[{"bundleId":"com.apple.Preferences","name":"Settings"}],"nextOffset":null,"offset":0,"total":1}
```

每次 apps 都重新查询安装列表；它不是 AX 观察，也不缓存 App 清单快照。查询之间发生安装或卸载可能改变后续分页位置。成功查询在完成时续期，参数错误、越界或底层查询失败不续期；所有查询均保留已有观察引用。只读查询不会向 Runner 发命令，也不会操作设备 UI。临时原生 JSON 和日志在调用结束后删除；连接预检仍保留在会话诊断目录。

## 接入失败诊断

CoreDevice 的非零退出保留原始日志末尾最多 4000 个字符，并在错误消息中注明失败阶段（例如 `list devices`、`device info details`、`device info lockState`、`device info apps`）和退出码。错误分类依据完整日志，截取日志尾部不会改变分类。

| 错误码 | 依据与下一步 |
| --- | --- |
| `coredevice_initialization_timeout` | 原始输出包含 CoreDeviceService 初始化超时。它不能证明设备断开、服务损坏或沙盒限制中的哪一种原因。若调用在沙盒内，先通过调用工具的授权机制，用允许 CoreDevice 通信的本机执行环境对照一次只读 `iphone-use devices`。 |
| `coredevice_access_denied` | 原始输出包含 `Operation not permitted` 或 `Permission denied`，大小写不敏感。先检查本机执行权限；在受限环境中，同样先对照一次只读 devices。它不表示 CLI 已自动提权，也不证明一定是某一种沙盒机制。 |
| `coredevice_failed` | 其他原生失败，按实际阶段、退出码和原始错误排查，不归入权限或初始化问题。 |

成功发现设备后，再根据 devices 返回的信息和原始任务继续 connect。若允许通信的执行环境中仍失败，应继续使用实际错误定位设备连接、配对或开发服务问题；不要反复执行同一失败命令、直接跳到 connect 重复相同预检，或默认重启系统服务。iPhone-use 不自动重试、提权或重启服务。

这些诊断同样适用于 connect 的 CoreDevice 预检，以及 apps/open 的安装清单查询；沿用现有的错误消息传播和动作三态规则。仅修改 CLI/宿主代码时，重新 `swift build` 并用新 CLI 建立会话；是否需要更新 Runner 由协议兼容性检查决定。

## 打开已安装 App

open 已移除 Fixture/Calculator 白名单。Mac 在派发前重新查询安装列表，按 bundle ID 精确核对。未列出的 App 返回 `app_not_installed`、`outcome=not_dispatched`、`requiresObservation=false`，原引用保留；查询失败同样不能冒充已派发或已完成。

Runner 只检查 bundle ID 格式，封装 XCTest 的 activate/launch、前台状态和执行事实。已运行则 activate，未运行则 launch；open 不隐含安装或重启。当前握手要求 `launchVersion=2`，同时确认 Runner 支持 terminate/relaunch；旧 Runner 必须重新构建，见 [生命周期](runner-app-lifecycle.md)。

安装列表不保证某个 App 一定能启动、暴露可用 AX 或接受全部输入方式。若安装检查后设备/App 状态变化，仍由既有执行阶段与三态结果表达，不自动重发，也不扩大兼容性承诺。观察与动作继续沿用 [观察契约](observations.md) 和 [动作契约](actions.md)。

## 当前边界

发布包使用 setup 准备 Runner 后直接 connect；源码开发使用 build-runner 生成已签名的 `.xctestrun`，见 [接入说明](onboarding.md)。两种流程都需要本机 Xcode 和开发签名。设备发现和安装清单不证明免 Xcode 部署、无 Runner 控制、物理重连自动恢复或任意 App 的全部操作兼容性。

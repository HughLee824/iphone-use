# Runner Home 与 App 生命周期

2026-09-23：Runner 增加 `home oN`、`terminate BUNDLE` 和 `relaunch BUNDLE`，与标准模式使用相同命令名称。设备协议升级为 `actionVersion=8`、`launchVersion=2`，需重新 build-runner 或安装配套 Runner。原生服务连接、媒体会话和 HID 路径不参与 Runner 的这些操作。

## 命令及完成条件

```sh
iphone-use --session "$SESSION" open com.example.probe --observe
iphone-use --session "$SESSION" home o1 --observe
iphone-use --session "$SESSION" open com.example.probe --observe
iphone-use --session "$SESSION" terminate com.example.probe --observe
iphone-use --session "$SESSION" relaunch com.example.probe --observe
```

替换实际会话、bundle ID 和观察引用。Home 使用当前截图，不接受元素引用或坐标；terminate/relaunch 以精确已安装 bundle ID 为目标，无需旧观察。不会自动选择前台 App，也不会在失败后切换模式。

| 操作 | Runner 执行及确认 | 不代表什么 |
| --- | --- | --- |
| Home | 检查已知 App/弹窗、当前观察和整屏守卫；调用一次 XCTest Home 按下/释放 | 不自动确认主屏幕，也不承诺目的画面静止 |
| terminate | XCTest terminate 后等待 `.notRunning`；最多等待 5 秒状态确认 | 不清除磁盘数据，不证明 App 的扩展进程全部退出 |
| relaunch | 先确认 `.notRunning`，再调用一次 launch 并等待 `.runningForeground` | 前台状态不代表网络加载、界面动画或业务页面已就绪 |

Home 的 `homePressCompleted=true` 只确认输入调用完成，`homeScreenConfirmed=false` 始终保留。初版实机已回到主屏幕，但时钟图标不断变化，使通用判稳超时；因此 Home 使用专用回执，不等待主屏幕静止，也没有扩大像素差异阈值。其他 Runner 手势和文本输入仍要求原有判稳。`--observe` 截图可能仍在转场中，需要时另行 observe，不重发 Home。

Home 后清除当前 App 目标，观察可为截图可用、`scope=unknown`、AX 不可用；这不是失去截图能力，也不会生成主屏幕元素引用。用明确 bundle 的 open 建立新的已知 App 上下文。当前 Home 首次输入仍要求一个已知 App 或弹窗，未扩展未知前台/主屏幕上的任意操作。

生命周期事实分别记录 `alreadyStopped`、`terminationRequested`、`terminationAcknowledged`、`stoppedConfirmed`、`launchRequested`、`launchAcknowledged`、`foregroundConfirmed` 和 `appState`。`pageReadyConfirmed=false`，由外部 Agent 检查新图。已停止的 terminate 不调用终止接口，返回 `execution.started=false` 的已验证空操作；已停止的 relaunch 仅启动一次。宿主专门核对这些事实，不能用普通输入成功回执伪造一次派发。

## 顺序、失败与范围

宿主复用串行设备队列与观察失效机制。Runner 通过自己的 XCTest 连接执行，无新增服务或框架依赖。SpringBoard、本 Runner 宿主 App 和测试 bundle 不可作为终止目标。

每个可能改变状态的调用前标记执行开始；XCTest 报错即停止后续步骤。退出未确认时不继续 launch；退出与启动之间还会检查取消及目标是否已自行重启。异常或回执缺失保留部分事实和 unknown，不自动重放。5 秒仅是状态确认等待上限，不是整个命令的硬期限；XCTest 输入调用沿用既有有界 application-state 策略，宿主传输仍使用既有超时。

Runner 生命周期结果不提供 PID 身份保证，也不复用原生路径的 PID 信号语义。它通过 XCTest 的 App 状态确认结果；本轮另外用 Apple CLI 仅读取进程列表作为独立真机证据。停止、状态读取及下一步启动之间不是原子事务，外部行为仍可能改变 App 状态。

不带 `--observe` 时仅返回操作事实；带该选项时动作与观察分别返回。截图失败不会使已执行操作变成未执行，也不会触发重试。标准模式仍使用原有 Apple CLI 进程检查及自动附图行为。

## 真机与宿主验证

环境重新检查为 macOS 27.0 (26A428)、Xcode 27.0 (27A266a)、iPhone 12 Pro / iOS 27.0 (24A437)。通过 devicectl 动态发现唯一物理测试 iPhone，未硬编码设备标识。只操作既有普通 iPhone-use Probe，未修改设置、访问聊天或使用剪贴板。

| 验证 | 观察到的事实 |
| --- | --- |
| Home → open | Home 后截图显示主屏幕；open 返回 Probe。最终版 Home 回执正常；即时截图仍可能处于收起动画中 |
| terminate | 从前台状态 4 变为停止状态 1；独立进程列表确认原 PID 6292 消失 |
| 再 terminate 已停止 App | `alreadyStopped=true`、`terminationRequested=false`、`execution.started=false` |
| relaunch 已停止 App | 只启动一次，新 PID 6308；截图显示 Probe 初始页面 |
| 最终版 Home → open | 操作完成且原 PID 6308 保持，证明 open 激活原进程 |
| relaunch 运行中 App | 确认停止后启动，PID 从 6308 变为 6309；新截图显示 Probe 初始页面 |
| 关闭测试会话 | 两次自身 shutdown 均确认，xcodebuild 退出码 0、观察缓存移除；相关宿主和 xcodebuild PID 均已退出 |

最初 Home 的 `frame_stability_timeout / unknown` 保留在证据中，没有将原失败记录改为通过或重放原观察。修改完成条件后通过新会话、新观察验证。当前命令的 completed 仍不替代上表的截图/进程核验。

宿主 `swift test` 执行 288 项：287 通过、1 项既有 opt-in 测试跳过、0 失败。覆盖 Home 全屏保护和旧观察失效、两种模式的生命周期准入、部分执行事实、回执缺失、无输入的已停止确认，以及 Home 专用规则不放宽其他动作判稳。CLI 动作/观察测试 15 项、模式测试 6 项通过。最终 Release CLI 与签名 Runner 构建成功。未运行远端 CI，也未对真实 XCTest 终止超时或断连做故障注入。

原始回执、截图、两版构建记录及独立进程检查保存在本机忽略目录 `.local/research/runner-lifecycle-20260923/`，不作为运行依赖。本轮没有发布版本或推送远端。

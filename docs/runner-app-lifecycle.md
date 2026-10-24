# Runner Home 与 App 生命周期

Runner 通过 XCTest 提供 `home oN`、`terminate BUNDLE` 和 `relaunch BUNDLE`。与标准模式使用相同命令名称，但确认条件和执行事实不同。

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

Home 的 `homePressCompleted=true` 只确认输入调用完成，`homeScreenConfirmed=false` 始终保留。主屏幕时钟等内容可能持续变化；Home 使用专用回执，不等待主屏幕静止，也没有扩大像素差异阈值。其他动作保留各自的后置校验与稳定性事实。`--observe` 截图可能仍在转场中，需要时另行 observe，不重发 Home。

Home 后清除当前 App 目标，观察可为截图可用、`scope=unknown`、AX 不可用；这不是失去截图能力，也不会生成主屏幕元素引用。用明确 bundle 的 open 建立新的已知 App 上下文。当前 Home 首次输入仍要求一个已知 App 或弹窗，未扩展未知前台/主屏幕上的任意操作。

生命周期事实分别记录 `alreadyStopped`、`terminationRequested`、`terminationAcknowledged`、`stoppedConfirmed`、`launchRequested`、`launchAcknowledged`、`foregroundConfirmed` 和 `appState`。`pageReadyConfirmed=false`，由外部 Agent 检查新图。已停止的 terminate 不调用终止接口，返回 `execution.started=false` 的已验证空操作；已停止的 relaunch 仅启动一次。宿主专门核对这些事实，不能用普通输入成功回执伪造一次派发。

## 顺序、失败与范围

宿主复用串行设备队列与观察失效机制。Runner 通过自己的 XCTest 连接执行，无新增服务或框架依赖。SpringBoard、本 Runner 宿主 App 和测试 bundle 不可作为终止目标。

每个可能改变状态的调用前标记执行开始；XCTest 报错即停止后续步骤。退出未确认时不继续 launch；退出与启动之间还会检查取消及目标是否已自行重启。异常或回执缺失保留部分事实和 unknown，不自动重放。5 秒仅是状态确认等待上限，不是整个命令的硬期限；XCTest 输入调用沿用既有有界 application-state 策略，宿主传输仍使用既有超时。

Runner 生命周期结果不提供 PID 身份保证，也不复用原生路径的 PID 信号语义。它通过 XCTest 的 App 状态确认结果；可用独立的只读进程列表辅助真机核验。停止、状态读取及下一步启动之间不是原子事务，外部行为仍可能改变 App 状态。

不带 `--observe` 时仅返回操作事实；带该选项时动作与观察分别返回。截图失败不会使已执行操作变成未执行，也不会触发重试。标准模式仍使用原有 Apple CLI 进程检查及自动附图行为。

验证流程与边界见[测试指南](testing.md)。

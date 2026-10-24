# Runner 在 rednote 评论框输入失败的真机诊断

2026-10-17：复现 DeepSeek Harness 报告的评论输入失败。观察到当前设备上 XCTest 文本输入通道创建临时硬件键盘，随后软件键盘最小化、评论输入会话结束；后续的“找不到输入框／没有键盘焦点”是结果。直接触摸软件键盘可以输入。首轮仅记录诊断，后续新增公共 touch-paste 输入方式；各轮均未发送评论。

后续同日对照进一步发现：同一 Runner 会话改用 WDA 式事件合成仍然失败；由 `xcodebuild` 正常启动的诊断测试中，两条输入路径也都失败。因此不能把问题单独归因于 `XCUIElement.typeText` 封装或 standalone 启动方式。详细结果见文末补充实验。

随后直接启动设备上已安装的完整 WDA 16.15.0，其元素输入和 `/wda/keys` 两个接口也均复现相同 fallback、面板消失和空草稿。两个接口都返回成功，所以 HTTP 成功不能作为文本实际写入的证据。

最新系统备忘录对照：原版 Runner 和完整 WDA 均成功输入中英文混合段落，且成功输入时同样发生 display 解析失败、generic keyboard sender fallback 和临时硬件键盘接入。因此 fallback 本身不是输入失败的充分条件，不能单独认定为根因；当前证据更支持小红书评论框对键盘状态切换的特定响应，需要继续验证具体机制。

最新可用方案：独立准备设备剪贴板，再触摸评论框编辑菜单的 Paste。纯流程连续 3 次成功，覆盖中英文、重新打开空框、换行追加；未发送键盘按键，也未出现粘贴授权弹窗。standard 的现有 Command-V 粘贴则两次弹出授权框，授权后面板关闭且预期新文本未写入。以下历史实验按时间保留，最新结果见文末。

## 环境和原始失败

- iPhone 12 Pro，iOS 27.0.1，Xcode 27。
- 安装版 CLI 和原版 Runner：0.3.6；Runner 版本摘要 `ad2123cf0ef5f6e0c86753beebf73a1d6602231ce361f227cff4e986cda41f31`。
- App：rednote，bundle ID `com.xingin.discover`。场景为「每天认识一位设计师｜路易斯·康」笔记底部评论框。
- 初始 CLI 实验使用 runner 模式；后续单独测试完整 WDA 服务。最后一轮显式连接 standard 模式，验证独立剪贴板准备与触摸粘贴。

原始 Harness 日志中，打开评论面板后的观察含一个 `text_view`（`o10:e77`），identifier、label 均为空，软件键盘可见。首次使用 `replace`，第二次重新打开后使用 `insert`。两次均返回 `xctest_error`，截图显示评论面板已经消失。第一次还包含 `Neither element nor any descendant has keyboard focus`。

本次直接调用安装版 CLI，绕过 Harness，仍复现相同现象。这将问题定位到 Runner/XCTest 与 App 键盘行为的交互，而不是 Harness 的提示词或调用封装。

## 复现与对照

先连接设备、打开预览和 rednote，再进入上述笔记。点击底部评论入口，从新观察中取得实际 `text_view` 引用，执行：

```sh
iphone-use --session <session> type <fresh-text-view-ref> \
  --mode insert --text probe --observe --agent-output
```

观察到评论面板消失和 `xctest_error`。每次对照均重新打开面板、取得新观察，并检查空草稿；没有自动重放不确定结果。输入不包含换行，也没有点击发送。

| 对照 | 结果 | 证据文件前缀 |
| --- | --- | --- |
| 原版 Runner，中文 `输入诊断`，replace | 失败，面板消失，`inputCompleted=false` | `08-replace` |
| 原版 Runner，ASCII `probe`，insert | 失败，面板消失，`inputCompleted=true`、动作未完成 | `10-insert-ascii` |
| 原版 Runner，坐标触摸软件键盘 A | 成功，截图和 AX value 均为 `A` | `12-soft-key-a` |
| 原版 Runner，坐标触摸软件键盘删除键 | 成功，草稿恢复为空 | `13-clear-soft-key` |
| 原版 Runner，单独触摸 text_view | 面板保持打开，可出现编辑菜单 | `14-focus-touch` |
| 诊断 Runner，关闭自动 UI interruption handling，insert `probe` | 仍失败，面板消失 | `22-insert-no-interruptions` |
| 同一诊断 Runner，insert `b`，同步采集设备日志 | 仍失败；捕获下面的键盘状态变化 | `25-insert-device-log` |

诊断 Runner 只在忽略目录的源码副本中临时设置 `doesNotHandleUIInterruptions=true`，动作结束恢复原值；没有改动仓库 Runner 源码。签名构建和安装成功，但实验未解决问题，不能作为修复。详细系统日志来自这一诊断构建；原版构建已独立复现相同截图和错误。

## 系统日志中的触发链

以下为设备时间 2026-10-17 16:43:21（UTC+8），原始日志 `24-device.log` 的行号：

| 时间 | 行号 | 事件 |
| --- | --- | --- |
| .526250 | 14005 | testmanagerd 开始 `Typing 'b'` |
| .526279 | 14007 | `Failed to resolve displays. Defaulting to generic keyboard sender.` |
| .526478 | 14010 | Recap 创建 `(Recap) keyboard` 虚拟 HID 服务 |
| .563026 | 14103 | backboardd 报告 `Hardware keyboard attached` |
| .580523 | 14227 | discover 收到 `hardwareKeyboardAttached = YES` |
| .587031 | 14516 | discover 的 UIKit 执行 `Setting keyboard minimized = 1` |
| .807247 | 16585 | 键盘 placeholder 高度从 301 变成 0 |
| .808587 | 16632 | discover 清空输入 delegate，结束当前 input session |
| .815562 | 16932 | Recap 键盘被移除 |

对应动作后的截图不再包含评论面板；重新打开后草稿为空。这些日志支持以下触发链，但不能确定 App 内部的关闭回调：

**XCTest 文本输入 → 临时 Recap 硬件键盘接入 → App 收到硬件键盘状态变化 → 软件键盘最小化 → 评论输入会话结束 → text_view 不再存在。**

日志中也有向 App 派发输入事件的记录，不能把失败描述为“完全没有发送输入事件”。App 未保留预期草稿，与工具保留 `unknown` 执行结果相符。

无法从现有证据确定 rednote 内部究竟由哪个回调关闭面板，也没有确定 XCTest 为什么无法解析 display 而回退到 generic sender；这些是后续深入系统兼容性调查的边界。不能外推所有 App 或所有 iOS 版本都存在这一行为。

## 代码中的对应路径与次生问题

[`Runner/LiveSessionTests.swift`](../Runner/LiveSessionTests.swift) 的 `perform` 在输入前先核对观察路径，再以元素类型、identifier 和 label 建立唯一查询，检查快照、enabled 和 hittable。空 identifier/label 确实不理想，但本次通过了输入前检查，并进入了事件派发；单纯修改 selector 不能解释或消除键盘状态变化。

- `replace` / `append` 会调用 `target.tap()`、Command-A，随后 `target.typeText(...)`。
- `insert` 直接调用 `target.typeText(...)`。它也失败，因此额外的聚焦 tap、Command-A 和中文输入不是必要触发条件。
- 文本动作后仍读取 `target.frame`，用于 `postInputTextFields`。此时评论面板已经消失，重新解析 query 可以再产生 XCTest snapshot 错误。
- `execute` 在 `perform` 返回后设置 `inputCompleted=true`，之后判稳才再次检查记录的 XCTest issues。因此部分失败具有 `inputCompleted=true`，并不意味着文本已被 App 接受或业务动作成功。

[`Sources/IPhoneUseCore/Backends/AppleNative/Input/NativeHID.swift`](../Sources/IPhoneUseCore/Backends/AppleNative/Input/NativeHID.swift) 的 `prepareKeyboard` 已明确记录同类风险：注册新 HID 键盘可能改变硬件键盘状态并隐藏整个 composer，所以 standard 路径借用已公布的 CoreDevice 键盘。后续真机验证见文末：避免新增硬件键盘有效，但仍需避开快捷键粘贴的授权弹窗路径。

## 修复方向和验收条件

优先调查 Runner 是否可以使用不会新增硬件键盘的输入通道，或者让调用者明确选择经过验证的 standard 路径。不能把切换 insert、补 tap、重复 query、关闭 UI interruption handling 或盲目重试当作已验证修复。

另一个可独立改进的问题是输入后的诊断：避免只靠重新解析已经消失的 `target.frame` 获取输入区域；保留输入前已核验的区域和分阶段错误信息，区分输入调用、面板消失与输入后观察失败。这能改善报错，但本身不能修复文本输入。继续保留 `unknown` 和禁止自动重放的约束，不应吞掉错误后宣称输入成功。

后续修复应在同一评论框验证 ASCII 和中文、insert 和 replace，核对截图和 AX 正文；确认键盘及面板保持可用、没有意外提交、草稿可清空。若更改公共输入路径，还需回归普通输入框、多行框及既有文本操作。

## 证据、恢复和验证范围

本机原始回执、截图、AX 快照、设备日志与临时诊断构建保存在忽略目录 `.local/rednote-input-20261017/`，不随仓库发布：

- `original-257.json`、`original-271.json`、`original-285.json`、`original-293.json`：原始 Harness 观察和失败。
- 表中各前缀的 JSON、PNG 和 snapshot：本次对照实验。
- `device-timeline.txt`：上述日志时间线；`24-device.log`：完整日志。
- `16-disconnect-release.json`、`28-disconnect-diagnostic-clean.json`：实验会话清理回执。
- `29-restore-original.json`：重新安装原版已签名 Runner 的确认。
- `30-connect-restored.json`：恢复后通过默认已准备的 Runner 重新连接成功，返回 0.3.6 和原版本摘要。
- `31-disconnect-restored.json`：恢复验证会话关闭确认。

实验结束前，软件键盘测试字符已删除，重新打开草稿为空；评论数仍为 0，没有发送评论或改变点赞。设备上已恢复原版 Runner。预览媒体、隧道和 Runner 清理收到确认；设备日志采集进程已停止。

这次生产仓库只新增本文。未运行宿主测试套件；验证包括原版真机复现、软件键盘对照、诊断 Runner 构建和真机反证、设备日志、原版恢复连接及会话清理。不能将这些结果表述为修复已通过验收。

## 补充实验：WDA 输入路径与启动方式交叉对照

2026-10-17 17:07–17:10，继续在同一设备、同一 App 进程（PID 2203）、同一笔记上对照。所有输入均为 `probe`，没有换行或发送动作。

### 同一 Runner 会话，仅切换输入 API

独立源码副本新增一个诊断桥接函数，按 Appium WDA 当前 iOS 路径依次构造：

```text
XCSynthesizedEventRecord.initWithName
XCPointerEventPath.initForTextInput
path.typeText(atOffset: 0, typingSpeed: 60, shouldRedact: false)
record.addPointerEventPath
XCUIDevice.sharedDevice.eventSynthesizer.synthesizeEvent
```

参考 [WDA 的 FBTypeText](https://github.com/appium/WebDriverAgent/blob/master/WebDriverAgentLib/Categories/XCUIElement%2BFBTyping.m) 和 [FBXCTestDaemonsProxy](https://github.com/appium/WebDriverAgent/blob/master/WebDriverAgentLib/Utilities/FBXCTestDaemonsProxy.m)。这次复用了其事件构造和提交方式，没有部署完整 WDA 服务，不能将其称为完整 WDA 端到端验收。

诊断桥接在调用前检查 selector 可用性，等待明确的合成回调，失败或超时不重放。保留原 Runner 的目标核对、事件包装和输入后 `target.frame` 读取；没有沿用上一轮禁用 interruption handling 的改动。两次输入在同一 Runner PID 2824、同一 Runner session `E3D638A5-7988-4C3C-A653-73EF8BC9F4E9` 内交替执行：

| 路径 | generic keyboard fallback 时间（UTC+8） | 结果 |
| --- | --- | --- |
| WDA 式事件合成 | 17:07:26.241285 | 硬件键盘接入；评论面板消失；重新打开草稿为空 |
| 原生 `target.typeText` | 17:08:04.762363 | 同样的硬件键盘状态变化和面板消失；重新打开草稿为空 |

WDA 路径在 17:07:26.531950 返回 `success=1, error=null`，但截图显示业务输入失败；之后 Runner 的 `target.frame` 查询报错。证明不能以合成回调成功代替正文核对。调用前已经能看到软件键盘和评论输入框，第二次对照前又重新打开并检查了空草稿。

### 改变启动环境，保留两种输入实现

上述对照不能单独证明初始化有问题，所以补充了由 `xcodebuild test-without-building` 启动的诊断 XCTest。沿用同一源码副本和相同 WDA 桥接函数，通过独立测试入口依次运行两条路径；不进入生产命令服务，不设置 `IPHONE_USE_HOST_MANAGED`，不启用 startup Home guard，也不使用一秒的状态超时包装。

测试先核对已打开笔记的作者和评论入口，取得唯一空 `text_view`，每次输入前后保存截图和 AX 树。输入后重新打开评论框核验空草稿并收起；若出现非预期草稿则停止，不清除未知内容。

| 路径 | generic keyboard fallback 时间（UTC+8） | 结果 |
| --- | --- | --- |
| xcodebuild 启动 + WDA 式事件合成 | 17:10:36.046962 | `present=false, value=<missing>`；评论面板消失 |
| xcodebuild 启动 + 原生 `typeText` | 17:10:42.018058 | `present=false, value=<missing>`；评论面板消失 |

两次同样由 testmanagerd PID 2676 记录 fallback，随后出现 `Hardware keyboard attached` 和 App 的 `hardwareKeyboardAttached = YES`。WDA 事件在 Xcode 日志中的描述为 `display 0`，event synthesizer 的运行时类型为 `XCTRunnerDaemonSession`；这些是观察到的事实，尚未证明 display 0 本身就是错误，也未测试显式 display ID 能否修复。

`xcodebuild` 退出 0、显示诊断测试通过，仅表示测量流程完成和清理检查通过。该测试记录输入成败，没有断言输入必须成功；其两次文本输入实际上都失败。导出的截图也已人工核对，不能把测试运行成功写成输入修复成功。

### 本轮结论与边界

1. 在当前设备环境中，单独把公开 `typeText` 换成 WDA 的低层事件合成不能消除 fallback。
2. 单独改用 Xcode 管理的常规测试启动也不能消除 fallback，因此没有证据将问题定为我们 standalone 初始化遗漏的特有问题。
3. 各次失败均观察到设备端 testmanagerd 的 display 解析失败与 generic keyboard sender 路径；为什么 display 解析失败仍未确定。这些对照没有重启 testmanagerd 或重置系统状态，也没有覆盖其他 iOS/Xcode 版本。后续备忘录实验表明这条路径也可以成功输入，不能将其本身视为失败根因。
4. 用户所述“WDA 没问题”仍需与具体成功环境对应：WDA 版本/分支、输入 endpoint、编译 Xcode、设备系统及同一评论框的真实正文。当前 WDA 式事件合成、旧版 `_XCT_sendString` 和剪贴板输入不能视为同一个路径。

因此下一步应核对成功 WDA 的环境与实际调用链，或调查设备端 display 路由；不应直接替换生产输入实现，也不应把未经验证的初始化假设写成根因。

本轮证据保存在 `.local/rednote-wda-20261017/`：

- `source/`：独立诊断源码和两次构建；生产 Runner 源码未改动。
- `10-wda-probe*`、`12-public-probe*`：同一会话两种 API 的回执、截图、AX 快照。
- `04-device.log`、`ab-timeline.txt`：同一会话的原始设备日志及摘录。
- `16-xcode-device.log`、`17-xcode-run.log`、`init.xcresult`、`xcode-attachments/`：Xcode 启动对照的系统日志、测试输出和截图。
- `15-disconnect-ab.json`：诊断会话的预览、媒体、隧道和 Runner 关闭确认。
- `18-restore-original.json`、`19-connect-restored.json`、`20-disconnect-restored.json`：原版 0.3.6 Runner 恢复、连接验证与关闭确认。

本轮没有发送评论，最后草稿为空、评论数仍为 0；没有操作点赞或收藏。设备日志采集及 Xcode 测试已结束，原版 Runner 已恢复。没有运行宿主测试套件，因为本轮生产仓库只更新诊断文档。

## 补充实验：直接调用真机已安装的完整 WDA

2026-10-17 17:17–17:20，按用户要求启动设备现有 `com.facebook.WebDriverAgentRunner.xctrunner`，没有重新编译或替换 WDA。通过 USB 转发本地 18100 至设备 8100，直接调用其 HTTP 服务。

`/status` 报告 WDA **16.15.0**、构建时间 `Oct 15 2026 11:43:56`、SDK 27.0、设备系统 27.0.1。WDA PID 2831；本轮两个输入使用同一 WDA session `508DC4D1-962C-48E3-BF4A-FA8A2BEB2A53`。rednote PID 为 2832，与上一轮的 2203 不同；重新通过历史记录进入同一篇路易斯·康笔记。因此这是完整 WDA 的独立会话对照，不是上一轮 Runner 会话的延续。

两次输入前都已截图确认空评论框、光标和软件键盘；输入均为 `probe`，频率 60，不包含换行。

| WDA 接口（省略 `/session/:id`） | 请求正文 | 返回值 | 实际结果 |
| --- | --- | --- | --- |
| `POST /element/:uuid/value` | `{"text":"probe","frequency":60}` | `value: null`，成功 | 评论面板消失；重新打开后草稿为空 |
| `POST /wda/keys` | `{"value":["p","r","o","b","e"],"frequency":60}` | `value: null`，成功 | 评论面板消失；重新打开后草稿为空 |

元素接口先成功查到 `XCUIElementTypeTextView`，再发送输入；不是定位失败后跳过输入。按该版本的 [FBElementCommands 源码](https://github.com/appium/WebDriverAgent/blob/v16.15.0/WebDriverAgentLib/Commands/FBElementCommands.m)，元素入口调用 `fb_typeText`，`/wda/keys` 直接调用 `FBTypeText`。后者的结果排除了元素定位与元素输入前处理是唯一触发点的解释。

设备日志的时间顺序如下（UTC+8）：

| 事件 | 元素输入 | `/wda/keys` |
| --- | --- | --- |
| testmanagerd：`Typing 'probe'` | 17:17:46.504299 | 17:19:48.073674 |
| testmanagerd：`Failed to resolve displays. Defaulting to generic keyboard sender.` | 17:17:46.504371 | 17:19:48.073828 |
| backboardd：`Hardware keyboard attached` | 17:17:46.527932 | 17:19:48.108264 |
| discover：`hardwareKeyboardAttached = YES` | 17:17:46.534098 | 17:19:48.129149 |
| discover：`Setting keyboard minimized = 1` | 17:17:46.536602 | 17:19:48.154362 |
| testmanagerd：`Typing complete, replying to client.` | 17:17:46.806911 | 17:19:48.384286 |

**结论更新：当前设备、当前评论框下，已安装的完整 WDA 也不能成功输入。** “WDA 没问题”这个前提在本轮没有成立。结合之前的同一 Runner API 对照和 Xcode 启动对照，问题不是简单换成 WDA API 就能解决，也没有证据将其归为 Runner 独有的初始化缺陷。可观测的共同失败链仍在 testmanagerd 的 display 解析、键盘发送回退及 App 对键盘状态切换的响应上；display 为何解析失败仍未查明。

这次仍使用 testmanagerd PID 2676，没有重启系统服务或设备；尚不能区分持续存在的系统服务状态与系统版本/事件路由兼容问题。也不能由一个评论框的失败推断 WDA 在所有 App 的输入都失败。

证据目录：`.local/rednote-installed-wda-20261017/`。

- `01-status.json`：实际 WDA 版本和 SDK。
- `10-composer*`、`11-textview*`：第一次输入前的空输入框及元素定位。
- `12-element-input*`、`14-keys-input*`：两种接口回执、输入后截图和 AX 树。
- `13-reopen*`、`15-reopen-empty*`：重新打开后空草稿的截图及 AX 树。
- `09-device.log`、`timeline.txt`：原始设备日志及上述时间线摘录。
- `16-dismiss*`：最终收起空草稿，评论数仍为 0。
- `17-delete-session.json`、`18-stop-wda.json`、`19-final-processes.json`：会话删除、本人启动的 WDA 进程终止、设备无 WDA/Runner 进程的验证。

未发送评论、未点击点赞或收藏。WDA 会话、USB 转发和日志采集均已结束；保留设备原有 WDA 安装。生产代码没有改动，仅更新诊断文档；未运行宿主测试套件。

## 补充实验：系统备忘录作为成功对照

2026-10-17 17:23–17:25，按用户要求在系统备忘录 `com.apple.mobilenotes` 新建测试笔记，使用原版 Runner 0.3.6 和设备已安装的 WDA 16.15.0 分别输入。未修改原有笔记。先由 Runner 在空编辑器输入第一段，点击 Done 并断开；再由 WDA 打开同一条笔记、聚焦末尾，追加换行和第二段。两段除前缀外内容相同：

```text
Runner 输入诊断 2026-10-17：这是一段中文和 English 混合文本，数字 12345，标点正常。
WDA 输入诊断 2026-10-17：这是一段中文和 English 混合文本，数字 12345，标点正常。
```

| 路径 | generic keyboard fallback 时间（UTC+8） | 硬件键盘接入时间 | 实际结果 |
| --- | --- | --- | --- |
| 原版 Runner `type --mode insert` | 17:23:27.578032 | 17:23:27.638249 | 输入成功，截图和 AX 正文一致 |
| 完整 WDA `/element/:uuid/value`，频率 60 | 17:24:57.821268 | 17:24:57.849382 | 追加成功，截图和 AX 正文一致 |

两次日志均由同一个 testmanagerd PID 2676 输出，未重启设备或系统服务。WDA 输入后的即时截图显示软件键盘已收起，但编辑器和完整文本仍然存在。点击 Done 后，再从 AX 树读取整条笔记，与预期的两段文本逐字比对通过，没有缺字或重复。此轮未额外测试 WDA `/wda/keys`。

**这一成功对照修正了诊断边界：display fallback 和模拟硬件键盘接入，不足以单独解释小红书输入失败。** 当前设备的 Runner/WDA 文本通道可以正常工作；小红书评论输入框消失、焦点丢失，才是与备忘录成功场景相关的差异。结合此前时序，App 对键盘状态/布局切换的处理是更具体的调查方向，但尚未观测到其内部关闭面板的调用链，不能把该推断表述成已证明的 App 代码缺陷。

证据目录 `.local/notes-input-20261017/`：`05-runner-input*` 为 Runner 输入回执、截图和快照；`13-wda-input*` 为 WDA 输入结果；`14-wda-done*` 为最终笔记截图和 AX 树；`verification.json` 保存逐字核验结果；`device.log` 与 `timeline.txt` 保存设备日志。时间线还包含 WDA 启动阶段的另一条键盘事件，表格仅列与两次正文输入对应的时间。

测试笔记保留在手机上，供用户查看。Runner 会话及预览媒体已关闭；WDA 会话、本人启动的 WDA PID 2855、USB 转发和日志采集均已结束。最终设备进程检查无 WDA/Runner 残留。只更新本诊断文档，没有修改生产代码或运行宿主测试套件。

## 补充实验：避免键盘接入，使用剪贴板与触摸 Paste

2026-10-17 17:29–17:43，同一 iPhone、同一 rednote PID 2832、同一篇笔记。显式连接 standard 会话 `sc314d898d528439ab5f0bf84e86fd9c5`，没有修改默认模式或生产代码。本轮没有启动 Runner/WDA。所有成功均指草稿输入，未发送评论。

### 两种粘贴入口的差异

`text-prepare` 返回 `serviceSource=coredevice_builtin`，借用现有 CoreDevice 键盘服务，没有注册新的硬件键盘。随后对比：

| 路径 | 次数 | 实际结果 |
| --- | --- | --- |
| standard `type --method paste`，通过 HID Command-V | 2 | 都出现“rednote would like to paste from dtpasteboardd”系统授权弹窗；点击 Allow 后评论面板关闭，重新打开没有预期新文本 |
| 上述失败后，保留待恢复的剪贴板，触摸编辑菜单 Paste | 2 | 中文与中英文混合文本均完整进入，面板和软件键盘保留 |
| 独立准备剪贴板，不发送任何键盘按键，再触摸 Paste | 3 | 连续成功，无授权弹窗；覆盖空框、重新打开空框，以及带换行追加 |

第一条快捷键路径在 17:31:42.913398 记录 `App transitioned to background`，随后清空 `XYCBTextView` 输入 delegate，17:31:42.925049 记录 `Ending text input session`；同段明确为 `hardwareKeyboardStateChanged:NO`。因此它与 XCTest 的临时键盘接入链不同。日志还记录了 Pasteboard 的零字节返回；目前无法确定授权处理、空数据读取与 App 关闭动作之间更细的因果关系。可确认的是：系统弹窗出现、确认后面板关闭且新文本未写入；不能将其笼统写成又一次硬件键盘问题。

### 纯剪贴板流程的复现

在忽略目录编译诊断工具 `ClipboardStage.swift`，复用 `NativeTextPasteboard` / `AppleTextPasteboardIO`，只连接 `com.apple.coredevice.pasteboardservice`，不准备 HID 服务、不发送 Command-V。该工具不改变生产 CLI。它备份原剪贴板至内存，写入测试文本并检查所有权；截图核对完成后显式 `finish`，仅在仍拥有测试内容时恢复原剪贴板。三轮恢复均返回 `pasteboardRestoreAcknowledged=true`；恢复协议不是原子的。

操作顺序：

1. 打开评论框，以截图确认空草稿或准确的追加位置。
2. 向独立工具发送 `{"command":"stage","text":"待输入文本"}`，确认 `staged=true`、`ownershipConfirmed=true`。
3. 在最新截图上长按输入区域，观察出现的菜单，再触摸可见的 Paste。每次依据截图定位，不固定复用菜单坐标。
4. 核对正文、换行、原文保留和面板仍在；工具回执 `unknown` 不代替这一步，也不自动重放。
5. 向工具发送 `{"command":"finish"}`，确认剪贴板恢复；最后用 `quit` 结束工具和隧道。

三轮预期及截图逐字核对结果：

| 轮次 | 输入 | 场景 | 截图证据 |
| --- | --- | --- | --- |
| 3 | `稳定输入验证三：中文 English 123。` | 清空后的空框 | `28-pure-paste-three-screen.png` |
| 4 | `稳定输入验证四：光与空间的关系。` | 清空、收起、重新打开的空框 | `33-pure-paste-four-screen.png` |
| 5 | 换行 + `验证五：追加中文和 English，保留前文。` | 追加到第 4 轮正文末尾 | `35-pure-paste-five-screen.png` |

三次均没有系统授权弹窗，软件键盘和评论面板保留。第 5 轮截图正确显示两行，前文没有丢失。这里的验证是人工读取截图；standard 不提供 AX，因此不能声称本轮做了 AX 字符串比较。

全轮捕获的 627309 行日志中，`Hardware keyboard attached`、`hardwareKeyboardAttached = YES`、`Setting keyboard minimized = 1`、`Defaulting to generic keyboard sender` 均为 0 条；三轮纯流程各自的时间窗也无结束输入会话记录。采集器另输出过 `unexpected packet data` 警告，因此日志零命中仅指捕获内容，不能承诺系统层绝对没有漏报。无键盘按键的工具实现、连续截图和日志共同支持此替代路径。

### 额外限制与实现建议

- 本轮 Command-A 未按预期全选。`replace` + 空字符串只删除了光标前一个字符；另一轮 replace 粘贴失败后仍保留旧文。不能依赖该快捷键在此编辑器实现替换。清理改用在末尾长按软件键盘删除键，并截图确认空框。
- Native 触摸回执常为 `native_input_unacknowledged` / `unknown`，表示报告已排队但无输入确认；本轮据后续截图判定真实结果，没有把 unknown 自动当成成功或失败，也没有自动重放。
- 已验证方案为“剪贴板 stage → 触摸菜单 Paste → 验证 → 恢复”，不是现有 `type --method paste` 的直接成功。现有公共 CLI 仍会发粘贴快捷键，尚未提供独立 stage 命令。
- 若产品化，优先拆出不发送键盘事件的剪贴板事务入口，沿用原内容保护、所有权校验、显式完成和不重放约束；由调用者观察实际菜单再触摸 Paste。不要偷偷切换后端或给所有 App 硬编码菜单坐标。replace 还需独立验证 UI 选择行为。
- 三次纯流程构成当前设备、当前评论框的可重复方案，尚不代表所有 App/iOS 版本的通用保证，也未验证与 Runner 同时存活的混合后端实现。

### 证据和清理

本机目录 `.local/rednote-native-20261017/`：

- `09-paste-one-confirmed*`、`15-paste-two*`：两次快捷键输入后的授权弹窗；`11-reopen-paste*`、`17-reopen-two*` 核对新文本未写入。
- `13-menu-paste*`、`20-menu-paste-two*`：两次恢复性触摸粘贴成功。
- `27-*` 至 `35-*`：三轮纯流程前后截图；`ClipboardStage.swift` 和 `clipboard-stage` 为诊断工具；`clipboard-transactions.json` 保存三轮 stage/恢复回执，不含原剪贴板内容。
- `device.log`、`native-timeline.txt`：设备日志和计数、时间线。
- `36-final-clear*`：最终草稿为空；`37-final-dismiss*`：面板收起，未发送评论；`38-disconnect.json`：会话清理确认。

测试草稿已通过软件键盘删除，剪贴板全部恢复收到确认。独立工具退出 0、隧道关闭；日志采集已停止；standard disconnect 确认媒体停止、连接和隧道关闭，宿主 PID 35885 随后不存在。本轮没有修改点赞/收藏、没有发送评论；系统备忘录中此前创建的测试笔记保留。生产代码未改动，只更新诊断文档；没有运行宿主测试套件。

## 新增公共 touch-paste 方式的验收

2026-10-17 17:58–18:03，使用本仓库构建的 `.build/debug/iphone-use`，在上述同一设备、同一 rednote 评论框验证新增 `type oN --mode insert --method touch-paste`。它在宿主只连接剪贴板服务，后续长按与菜单点击分别使用 standard 原生触摸、runner XCTest 手势。Runner 沿用已安装的签名包，没有修改手机端协议或重新安装。Homebrew 中的旧 CLI 未更新。

| 模式 | 准备完成截图时间 | 粘贴完成截图时间 | 核验 |
| --- | --- | --- | --- |
| standard | 17:58:52.765852 | 17:59:24.312106 | 截图显示 `Standard 验证：中文 English 123。` 与第二行 `第二行保留。` |
| runner | 18:01:43.558144 | 18:02:11.340091 | 截图与 AX 正文均为 `Runner 验证：中文 English 123。` 与第二行 `第二行保留。`，AX 字符串逐字比较通过 |

两轮准备回执均为 `prepared / awaiting_touch_paste / textInserted=false / inputReportsSent=0`；准备后截图仍为空框。随后观察菜单并触摸 Paste，均未见粘贴授权弹窗，评论框与软件键盘保持打开。验证后 `text-finish` 都确认恢复原剪贴板。每种模式本轮各验证一次，不将这两次结果推广为所有 App 的通用保证。

采集的 211682 行日志中，18:00:51.795869 出现一次 `Defaulting to generic keyboard sender`，18:00:51.821525 出现一次 `Hardware keyboard attached`。它们紧随 Runner 启动阶段的 `Synthesizing button event for page 12 usage 64`，当时前台场景为 Runner PID 2880；早于 18:01:33 评论框打开后的截图。两次粘贴流程期间没有新增上述事件，全日志没有 `hardwareKeyboardAttached = YES` 或 `Setting keyboard minimized = 1`。因此本次保证是新输入路径不调用键盘 API，并非整个 Runner 会话绝无键盘注册。

证据保存在本机 `.local/touch-paste-acceptance/`：`04-*` / `16-*` 为准备回执与空框截图，`06-*` / `18-*` 为输入结果，`07-*` / `19-*` 为恢复确认，`10-*` / `22-*` 为断开清理；`device.log` 与 `verification.json` 保存日志和计数。草稿已清空且未发送评论，两个会话均正常断开，Runner 退出与剪贴板连接关闭均有回执，宿主 PID 43721、44686 已不存在。

自动验证：完整 Swift 测试 500 项、2 项跳过、0 失败；Python 61 项通过；相关 Node 测试 46 项通过、1 项跳过。最后修正了“剪贴板写入不确定且截图也失败时，应保留原始 staging 错误”的分支，增加回归测试后重跑相关 Swift 测试 69 项全部通过；插件技能同步检查通过。

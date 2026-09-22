# 设备动作与引用校验

当前提供按引用或明确坐标的画面校验点击/滑动，以及按输入框引用的光标插入、整段替换和独立 Return；文本可从参数或 stdin 读取。用户或调用 agent 负责选择动作并观察结果；iPhone-use 不解释自然语言任务。

## 实验性原生文字输入

推荐先执行 `iphone-use --session "$SESSION" text-prepare`：显式注册本会话的自有键盘，使旧观察失效并附带新截图。该操作不要求输入框引用、不聚焦、不发送按键、不访问剪贴板。检查新图后，再点击目标字段并用新观察确认焦点。已准备的键盘不会重复创建；每次显式 prepare 仍返回新图。原有 type 的按需准备行为保留，未显式准备时仍可能因软键盘收起而拒绝旧截图。

`text-prepare` 的 `keyboardPrepared` 和 `inputReportsSent=0` 描述服务准备事实，不证明焦点；截图失败时命令返回非零并保留准备结果，需要另行 observe。注册结果不确定时保留键盘状态和清理要求，不自动重复注册。仅适用于 apple-native，旧宿主拒绝未知命令。

原生 `press oN --key return --field-rect x,y,width,height --observe` 现支持向已确认焦点发送独立 Return。完整字段、当前 observationID、全屏保护、方向、30 秒有效期及有界光标例外与 type 相同；省略字段矩形时保护整个屏幕。不聚焦、不访问剪贴板、不自动完成待恢复的粘贴事务。调用方先核对输入结果并 text-finish，再决定是否发送 Return。Return 由 App 解释，可能搜索、完成、换行或提交；`keyReportQueued` 仅是本地发送事实，`keyEffectConfirmed=false`，结果仍为 unknown，必须检查新图。原生 type 的 auto/paste 正文允许 LF/CR 换行，作为文本一次粘贴，不转换或隐式附加 Return；keys 及其他控制字符仍拒绝。XCTest 仍使用原有 `press oN:eN --key return`。

`apple-native` 使用 `type oN --mode insert|replace|append --text 'Ab7!?'`，绑定当前截图而非 AX 节点。所有模式都要求先在受控页面观察、点击输入框，再用新截图确认焦点。`insert` 使用当前光标/选区；`replace` 先发送 Command-A 全选；`append` 先发送 Command-Down 请求移动到全文末尾。后两者不读取或重构原文，也不声明已经确认选区或末尾定位。ASCII 路径接受 1–64 个可打印字符，使用 US HID 映射。包含非 ASCII 字符或 LF/CR 换行的整段文本（如 `中文`、` A7，测🙂`）使用原生剪贴板服务与一次自写 HID Paste，最多 4096 UTF-8 bytes；不拆成拼音，不做候选词判断。不切换设备布局/输入法，不自动聚焦，auto/paste 保留正文中的 LF/CR（包括 CRLF），不规范化换行；其他控制字符仍拒绝。发送 Return 按键必须通过上述独立 press 操作。只有 `replace` 接受空文本，使用全选后 Delete，不读写剪贴板；即使显式指定 paste，空文本也不创建粘贴事务。

全选/末尾定位与后续文本共用一次有界 HID 序列，每个组合键后释放，再发送下一步。`textMode` 记录意图，`editingShortcutQueued` 只证明本地发送队列完成，`editingEffectConfirmed=false` 不宣称设备完成了定位。取消或通道错误即使发生在定位之后、正文之前，也返回可能执行的不确定结果，不自动重放。所有模式沿用完整字段保护，因此新增模式本身不解决光标闪烁拒绝。普通 UIKit 控件的验收不能代替网页、自定义编辑器或其他快捷键处理器的兼容验证。

键盘按需创建且只属于当前连接。首次注册可能收起软键盘，随后屏幕保护会拒绝旧截图并返回 `not_dispatched`；必须重新观察并决定新动作。输入前仍校验设备、会话、30 秒有效期和整屏指纹。每个字符后释放全部按键，Shift 先独立按下；取消或发送失败尝试释放且不重放文本。结果截图由外部 Agent 核对，`charactersQueued` 不代表已输入字符数，`outcome=unknown` 不自动升级为成功。

`textInputMethods.asciiHID` / `unicodePasteboard` 区分当前可尝试的两条路径。`capabilities.text` 表示当前可尝试原生输入，`keyboard.prepared` 表示键盘已完成注册。设备焦点、布局、自动更正仍未由后端确认。关闭时必须按 ID 和唯一名称确认所属键盘，发送移除命令后通过关联枚举确认消失；`keyboardRemoveAcknowledged=false` 时不得宣称完整清理。以下原有节点输入与 Runner 检查描述适用于 XCTest 后端。

此前的软键盘“你好”与 HID 拼音 `zhongwen` 选词测试只证明输入法闭环。本轮另外完成了直接 `type --text '中文'` 和中英/标点/emoji 的 Probe 验证，见[原生 Unicode 输入](apple-native-backend.md#unicode-text-input-2026-09-20)。

Unicode 输入会读取并在内存中备份设备通用剪贴板，写入整段文本，核对内容与变化计数后发送一次 Command-V。原内容保留到会话关闭，期间测试文本继续占用剪贴板，以便系统确认框中的粘贴仍能读取它。调用方必须先处理粘贴确认框、核对结果，再关闭会话；后端不自动允许系统弹窗。`pasteShortcutQueued` 不是文字已提交的证明，API 仍返回 `unknown` 和新截图。

关闭时仅在内容和身份/计数仍匹配时尝试恢复；`pasteboardRestoreAcknowledged=false` 会使整体清理不确认。协议不提供原子比较后恢复，不能与其他剪贴板写入者并发使用；宿主崩溃、断连、写入回包丢失可能导致无法恢复。原剪贴板正文不写入诊断日志或磁盘备份，不能恢复时不得宣称清理成功。

原生 `type` 可指定 `--field-rect x,y,width,height`，由调用方在当前原始截图中选择完整输入框，以屏幕 points 表示。局部基准为零变化限制，全屏仍为 1% 变化限制；省略该参数时仍对整屏实施局部零变化保护。矩形必须在该截图范围内，不自动聚焦、不自动识别输入框，不接受 XCTest/节点引用用法。显式字段允许下述有界光标例外；不符合条件的闪烁仍可能被拒绝。Unicode 路径在剪贴板写入前后各最多采集 3 帧、各最多 8 秒，始终比较原 observation 的指纹，且原观察总有效期仍为 30 秒；全屏超限立即拒绝。这里只重复只读截图，不重试输入，也不刷新比较基准。不得缩小矩形去绕开正文或光标。

原生画面差异拒绝现在返回 `result.screenGuard` 的实际变化比例，并将触发拒绝的原图作为 `observation.phase=pre_input_rejection` 附带。`result.rejectedObservationID` 是该新观察，原引用失效；它不是动作后图，不提供 `afterObservationID`，动作仍为 `not_dispatched`。调用方先检查附图，再决定新动作；捕获失败/无差异比较结果的拒绝不保证带图。缓存仍只保留两个观察，关闭会话时移除，需及时保存证据。

## CLI 形式

下面的会话和引用需要替换为实际返回值，每次派发动作后重新 observe。

```sh
iphone-use --session "$SESSION" tap o4:e10
iphone-use --session "$SESSION" swipe o5:e18 --direction up
iphone-use --session "$SESSION" type o6:e8 --mode insert --text '北京'
iphone-use --session "$SESSION" type o7:e8 --mode replace --text '完整的新内容'
iphone-use --session "$SESSION" type o8:e8 --mode replace --text ''
iphone-use --session "$SESSION" type o9:e8 --mode append --text '追加'
iphone-use --session "$SESSION" type o9:e8 --mode replace --stdin < text.txt
iphone-use --session "$SESSION" press o10:e8 --key return
iphone-use --session "$SESSION" tap o11 --x 100 --y 200
iphone-use --session "$SESSION" swipe o12 --from-x 100 --from-y 420 --to-x 100 --to-y 380
iphone-use --session "$SESSION" tap o13:e10 --protect o13:e20
```

- tap 元素用完整 `oN:eN`。点坐标形式用 `oN --x --y`，单位为屏幕点；不是 PNG 像素，不能同时指定元素引用。点击范围限制在当前已确认的 App 或弹窗内。
- swipe 的 up/down/left/right 描述手指移动方向；宿主根据可见 frame 的 20%/80% 位置生成端点。明确端点形式可控制手指移动距离，两种形式均支持下述速度和停留参数。tap/swipe 先校验画面再执行坐标，不依赖 identifier/label 唯一性；阈值、附加保护区域、限制见 [动作前画面校验](screen-guard.md)。
- insert 直接向指定输入框发送文字，保留已有光标位置，不额外点击字段。它需要现有键盘焦点；需要聚焦时由 agent 先 tap、再 observe。公开 hasFocus 在本设备中不反映键盘焦点，不能据此预检。
- replace 聚焦输入框后发送 Command-A，非空文本直接覆盖选区；空文本通过 `typeText(XCUIKeyboardKey.delete.rawValue)` 删除选区。没有按 AX value 长度连续退格，也没有自动 Return 或点击提交。
- Runner append 读取已校验目标的完整可读原文，将原文和新增文本拼接后走 replace；不依赖当前光标/选区，也不假定 Command-Down 生效。安全字段、无字符串原文、原文与 placeholder 无法区分、拼接后超过 4096 bytes 或含不支持字符时，在输入前拒绝。nil 值不推断为空文本；已有内容的控件处理、格式和 undo 行为仍可能因整段替换改变。宿主验证旧观察，Runner 使用再次核对后的当前快照值构造正文；不从过期 AX 值重建。
- Runner 文本上限为 4096 UTF-8 字节，支持 LF 换行，但只允许用于明确的 text_view；text_field、secure_text_field、search_field 在聚焦/输入前拒绝多行。当前 Probe 实测 XCTest 把 CRLF 写成两个 LF，因此 Runner 明确拒绝 CR/CRLF，既不静默规范化，也不借用原生粘贴通道。其他控制键仍拒绝；insert/append 不接受空字符串，replace 空字符串表示清空。
- `--text` 与 `--stdin` 必须且只能选一个。stdin 读取到 EOF，严格解码 UTF-8，不裁剪首尾空格、不去掉末尾换行、不解释转义或执行文本。可用文件重定向或管道；管道生产者需关闭输出。读取到第 4097 字节就拒绝，不为超长输入继续等待 EOF。`--mode replace --stdin < /dev/null` 表示清空。
- `press oN:eN --key return` 向当前输入框发送独立 Return，要求已有键盘焦点，不额外 tap。需要聚焦时先 tap、再 observe。当前只接受小写 `return`，未提供其他按键或组合键接口。具体界面效果由 App 决定，可能提交、换行或无业务变化；调用方仍需 observe 核对。

## 动作后观察

`open/tap/swipe/type/press` 均接受可选 `--observe`，例如：

```sh
iphone-use --session "$SESSION" open com.example.app --observe
iphone-use --session "$SESSION" tap o1:e10 --observe
iphone-use --session "$SESSION" type o2:e8 --mode replace --text '新内容' --observe
```

每条命令只执行一个已选择的动作，再根据回执调用一次既有 `observe`。返回单行 JSON：

```json
{"session":"example-session","ok":true,"action":{"id":"action-request","session":"example-session","ok":true,"outcome":"completed","result":{}},"observation":{"id":"capture-request","session":"example-session","ok":true,"result":{"observation":"o2","refs":"current","screenshot":"/example/o2/screen.png","text":"observation=o2 refs=current…"}}}
```

- `action` 完整保留原动作回执，包括 `outcome`、错误及可用输入事实；`observation` 独立保留观察回执。CLI 退出码与顶层 `ok` 表示整组是否成功：动作和观察均成功才为 0 / true。
- `completed`、`unknown` 和需要刷新的拒绝均继续观察。`unknown` 即使观察成功也仍退出 1；观察不能追认动作完成。
- 会话匹配、`ok=false`、`outcome=not_dispatched` 且 `requiresObservation` 缺省或为 false 时，不刷新，返回 `observation={"skipped":"not_dispatched"}`。这保留了可纠正参数错误后的当前引用。
- 观察失败时，顶层 `ok=false`，原动作回执不变。依据观察错误恢复，再单独 `observe`；不能重放动作。只有成功的新观察提供新引用，动作自带截图没有 AX 引用。
- 不带 `--observe` 的正常输出保持原形状。语法或会话参数错误仍可在请求前失败；后台执行句柄必须续接到命令结束。若整个 CLI 的响应丢失，输入可能已经发生，应先观察，不能重跑原命令。

这个选项由当前 CLI 顺序调用两次既有宿主协议实现，无需宿主能力协商或 Runner 升级，也不会向旧宿主发送可被忽略的新动作字段。它不将动作与观察变成原子事务：其他已接纳请求、App 自发变化或会话关闭可能发生在两步之间。后续其他客户端也可使返回的新引用失效，原有校验仍生效。

已安装的旧 CLI 不支持新参数；先检查动作 `--help`，必要时使用分开的动作/观察或 skill 回退模板。不要把带 `--observe` 的动作再放入动作加观察的模板中，避免重复采集。

## 可控拖动

`swipe` 的起终点规定手指轨迹，不承诺内容滚动多少点或选中多少格。以下参数控制拖动过程，默认值保留此前实测的 500 / 0 / 0 行为：

| 参数 | 含义 | 范围 | 默认值 |
| --- | --- | --- | --- |
| `--velocity` | 移动速度：XCTest 后端采用 XCTest pixels/s；apple-native 采用原始截图 pixels/s。起终点仍用屏幕 points | 大于 0、至多 10000 | 500 |
| `--press-duration` | 开始移动前按住的秒数；可用于先长按再拖动 | 0–5 | 0 |
| `--hold-duration` | 到达终点后、抬手前停留的秒数 | 0–5 | 0 |

例如以下轨迹只能在当前观察确实提供对应滚轮/事件位置时使用，引用和坐标必须替换为实测值：

```sh
# 滚轮微调：降低速度，到达终点后短暂停留，再抬手。
iphone-use --session "$SESSION" swipe o12 \
  --from-x 98 --from-y 385 --to-x 98 --to-y 337 \
  --velocity 100 --hold-duration 0.2
iphone-use --session "$SESSION" observe

# 已重新观察的事件块：先按住，再慢速移动。
iphone-use --session "$SESSION" swipe o13 \
  --from-x 110 --from-y 536 --to-x 110 --to-y 561 \
  --velocity 100 --press-duration 0.5 --hold-duration 0.2
iphone-use --session "$SESSION" observe
```

上述参数是试验起点，尚未证明能让任意 App 的滚轮恰好移动一格。到达目标附近时优先使用明确端点；方向形式移动可见区域的 60%，可能跨多格，降低速度不会缩短距离。例如可见高度 240 点、行距 48 点的滚轮，方向滑动的手指位移为 144 点，约三个行距。

先读当前选中值，按需 inspect 滚轮与子行的 frame，再根据目标差值和行距选择端点。可见且 enabled 的文字不保证支持点击选值；某次文字点击无效后，同类滚轮优先采用已验证的拖动方式。每步后重新 observe 核对实际值；连续无变化或反向过冲时重新检查选中的字段、几何信息及交互方式，不能只把距离越试越小。分钟回绕不保证小时进位，修改开始时间后也需重新核对结束时间。原生 `picker_wheel` 与自定义 `scroll_view` 不能混为同一种能力。

明确端点使用观察 ID，例如 `swipe o12 --from-x ... --from-y ... --to-x ... --to-y ...`。元素引用与端点混用会返回 `invalid_coordinates / not_dispatched`，错误提示指出冲突及修正形式；可按需追加 `--protect o12:e18` 将该元素作为额外保护区域。未派发且没有其他失效原因时原引用仍可用。

默认保留画面守卫阈值。`--max-screen-change` 比较的是输入前画面相对观察时的变化，不是动作预计造成的滚动或动画幅度；只有理解具体的守卫拒绝原因后才调整策略。

宿主和 Runner 均校验参数及动作预算。以 `起始停留 + 路径屏幕点距离 × 截图倍率 / 速度 + 结束停留` 保守估算，超过 10 秒的请求在派发前返回 `swipe_duration_exceeded`，不消耗当前引用；应缩短路径/停留或加快速度。这个预算用于限制请求的运动过程，不是整个命令的硬超时；XCTest 前后等待及帧检测仍使用现有策略。

成功回执增加 `result.motion`，例如 `{"velocity":100,"pressDuration":0.5,"holdDuration":0.2}`。它表示 Runner 调用 XCTest 时采用的参数，不是从触摸硬件采样出的实测速度。宿主核对它与请求一致；缺失或不一致时保留输入事实及可用结果帧，返回 `unknown` / `missing_swipe_motion_facts`，不重放。`completed` 仍只表示输入结束且画面稳定，目标值必须由调用 agent 核验。

实验性 `apple-native` 后端仅支持基于当前截图 `oN` 的坐标 swipe，要求原始竖屏，不读取 AX 或启动 Runner。它按原始截图比例换算速度，至少用一个 1/60 秒采样间隔完成移动，并返回 `motionVelocityUnit=original_screenshot_pixels_per_second`、计划移动时长及实际排队的 MOVE 数量。采样目标为 60 Hz，发送延迟时跳过过期点；速度是计划值，不是设备实测值。整个输入有 10 秒执行期限（释放清理另有最多 3 秒等待）。按住和末端停留沿用 `--press-duration`、`--hold-duration`；这不等于已验收拖放或长按菜单行为。

原生 CONTACT/MOVE/RELEASE 的发送完成不是设备执行确认，因此始终保留 `outcome=unknown`，附带新的截图供外部 Agent 判断滚动方向和目标状态。取消、媒体失活或发送异常时尝试在最后发送位置释放，撤销该会话后续输入能力，不补发 MOVE，不重放动作；需显式建立新会话并重新观察。

原生回执的 `result.recovery` 区分检查结果截图、重新观察、检查媒体状态和显式重连。`result.controlErrorCode` 给出具体不可用原因，原有顶层 `error.code` 与执行事实保持不变。`automaticReplayAllowed` 始终为 false。截图过期不会要求重连；HID 输入或释放已不确定时，即使结果截图可用也必须先处理旧会话清理，再新建会话观察。IPC 失联只要求检查原会话，不能据此认定宿主已退出。详见[原生恢复契约](apple-native-backend.md#control-diagnostics-and-recovery)。

本地验证覆盖参数拒绝、默认值兼容、两种目标形式的参数传输、Runner 共享模型解码、包含截图倍率及两端停留的预算、旧 Runner 拒绝、回执不一致以及拒绝后引用仍可用。2026-09-06 的 `swift test` 为 73 项通过、0 失败。非默认时长的 Lark 实机验收由用户另开 session 进行，本轮没有创建测试日程。

## 宿主与 Runner 的职责

宿主解析参数、验证会话与当前引用。tap/double-tap/long-press/pinch/swipe 从原快照构造坐标与分区截图指纹；type/press 构造目标路径，包含来源节点和祖先的类型、identifier、label、value、enabled、frame，以及每层在父节点内的位置。不向 Runner 发送面向 agent 的观察 ID 或短引用。

这些检查与动作在同一个宿主串行队列执行。两个并发 CLI 命令即使使用同一份当前引用，第一个动作完成后，第二个在解析目标时仍会因引用失效而被拒绝。

薄 Runner 在发送输入前检查：

1. 对应的目标 App 身份与前台状态；SpringBoard Alert 和 App 内 Alert 的存在与数量必须符合观察时的范围。
2. tap/swipe 检查屏幕/范围/方向/键盘上下文，并重新截图。整屏和各保护区域变化在阈值内才执行坐标；不做 AX 目标路径重采样或名称查找。近似通过不保证业务状态未改变。
3. type/press 仍检查当前 AX 中的目标路径和每层属性；frame 允许最多 0.5 点的浮点变化。随后按 type、identifier、label 精确匹配且要求唯一，不通过选择第一个来消除歧义。
4. type/press 目标仍须启用且 isHittable，并为 text field、secure text field、text view 或 search field。坐标动作不保留这项 live 目标语义保证。

App 内唯一 Alert 现在单独作为 `scope=appAlert` 采集，SpringBoard Alert 使用 `scope=systemAlert`。原来没有弹窗的观察不会被用于点击后来出现的弹窗。

Runner 没有跨请求观察缓存、短引用、续期计时或任务策略。它处理当前请求的验证与 XCTest 调用，并在全部输入步骤结束后采帧判断稳定。它不等待业务状态成功；截图与 AX 的非原子采集限制继续成立。

## 执行结果

进入会话的动作结果均为单行 JSON，并保留请求 ID 和 session。stdin 的读取、编码或字节上限错误在 CLI 创建请求前返回 `session`、`ok=false`、`outcome=not_dispatched` 和 error，此时没有请求 ID；带 `--observe` 时同样跳过采集。文本源选择等语法错误继续由 ArgumentParser 输出到 stderr 并非零退出。

```json
{"id":"example-request","session":"example-session","ok":true,"outcome":"completed","result":{"kind":"tap","execution":{"started":true,"inputCompleted":true,"completed":true},"screenGuard":{"algorithm":"srgb-grid-v1","accepted":true,"screenChange":0,"regionChanges":[0],"maxScreenChange":0.01,"maxRegionChange":0,"pixelTolerance":8},"stability":{"stable":true,"samples":9,"consecutiveFrames":4,"stableForMs":563,"elapsedMs":1700,"observedForMs":1650,"minimumObservationMs":1500,"comparison":{"equivalent":true,"dimensionsMatch":true,"changedPixels":0,"colorTolerance":2.5,"maxChannelDelta":4},"hash":"example-sha256","algorithm":"yiq-local-caret-v1","sampleIntervalMs":200,"requiredStableMs":400,"timeoutMs":5000},"frame":{"screenshot":"/private/tmp/iphone-use-501/example-session/observations/action/screen.png","hash":"example-sha256","capturedAt":1788608247.676,"width":1170,"height":2532},"runnerMs":3634}}
```

| outcome | 判定 | 引用处理 |
| --- | --- | --- |
| completed | 本动作全部输入调用正常返回，且动作后画面达到容差稳定；不等于业务目标达成 | 旧引用失效，agent 再 observe |
| not_dispatched | 参数、引用或设备目标校验在任何输入 API 调用前拒绝 | 无其他失效原因时保留；若已发现目标或上下文变化则失效 |
| unknown | 输入后未达到帧稳定、已进入输入 API 后出错、执行事实缺失/矛盾，或丢失响应 | 旧引用失效；不重发，agent 先 observe |

每次调用可能发送输入的 API 前，Runner 标记 `execution.started`；任一步骤记录 XCTest 错误就停止，不再继续聚焦后的选区/删除/输入等剩余步骤。全部输入调用正常结束时标记 `execution.inputCompleted`，之后才开始检测帧稳定。App 打开继续使用启动/激活的 started/completed 事实，不纳入 act 的帧检测。

采帧间隔约 200ms，至少观察 1500ms，且连续至少 3 帧与同一候选帧等价、跨度至少 400ms 才报告完成。`yiq-local-caret-v1` 在全尺寸 sRGB 像素上允许小幅色差（Y/I/Q 各分量差不超过 2.5，RGB 每通道差不超过 4，alpha 必须相同）；不允许一定比例的明显变化，不降低分辨率，也不自动忽略抗锯齿边缘。单个超限像素也会重置窗口，因此局部文字变化不会被整屏平均分淹没。固定候选帧防止缓慢累计漂移。

在 type/press 已验证的文本目标范围内，允许符合位置、尺寸、蓝色笔画和明暗变化模型的单根光标变化。tap 后若键盘存在，一次有界只读快照中唯一完整可见的输入框也可作为分析范围；多个字段或截断快照不启用此例外，不通过焦点遍历查找字段。光标最外侧像素若与抗锯齿文字重叠，还必须有紧邻且完全未变的中性文字边缘，各通道变化不能超过实测光标相位；不扩张遮罩到相邻文字。无法识别的光标保留正常比较。原始截图始终不变，例外区域写入 `comparison.ignoredCaret`。至少观察 1500ms 用于避免本次记录到的延迟键盘展开前提前判稳，并不保证未来不会出现异步更新；后续动作仍需新观察和输入前检查。

全尺寸原始 sRGB RGBA8 像素和尺寸的 SHA-256 继续绑定最终图片与执行证据，不再用它判断视觉等价。比较/光标识别/哈希的处理时间计入 5 秒预算，但不冒充采样稳定跨度。

5 秒预算到期时返回 `unknown` 和 `frame_stability_timeout`，同时保留 `result.execution.inputCompleted=true`、`result.stability.stable=false` 与最后一帧。该结果确认输入已经完成，只是未获得稳定画面；不能把它解释为没有点击或允许重发。截图/解码失败同样保留可取得的事实；连接丢失且无响应时无法承诺最后一帧可用。预算在截图和处理之间检查，无法中断正在阻塞的 XCTest 截图 API，因此它不是整个 act 的硬超时。

正常结果返回最终原始 PNG 的路径和采集时间；超时还返回最后一次比较的候选原图与差异图路径。差异图标出所有原始像素变化（包括已容忍的光标和色差），不是观察，也不能用于选坐标。不向 agent 输出逐帧图片或 base64。宿主核对图片 hash 与稳定证据后，保存在 `observations/action/screen.png`；下一次带帧的动作覆盖它，disconnect/空闲回收时删除。需要保留时由调用 agent 复制。动作帧不创建观察 ID，不附带旧 AX；后续按引用操作仍需 observe。

Runner 在每个输入原语调用期间，将 XCTest application-state 等待上限设为 1 秒并在结束后恢复原值。这通过运行时能力检查后的 `_XCTApplicationStateTimeout` / `_XCTSetApplicationStateTimeout` 符号实现，没有引入 WDA。连接时能力缺失返回 `unsupported_xctest_runtime`；该内部 API 的兼容性仅在本次工具链/设备上验证，1 秒也不是整个动作的耗时上限。

XCTest 的命令错误经 Runner 转成响应；不再把已经返回给调用方的正常运行时错误一并算作 Runner 整个持续会话的 XCTest 失败。会话外的测试断言和异常结束仍由 XCTest 记录。

无焦点的 typeText 本轮确实发生了 XCTest 内部重试，最终没有写入文字。iPhone-use 的宿主与 Runner 不重新调用结果未知的动作，但单次调用不构成 Apple 内部严格只发送一次底层事件的保证。请求 ID 同样不是去重承诺。

## 兼容性与验证边界

当前设备协议为 `actionVersion=7`、`observationVersion=2`、`screenGuardVersion=1`、`frameStabilityVersion=2`。发布用户安装配套版本并重新 setup；源码开发者重新 build-runner，并使用新路径 connect。旧 Runner 不会静默忽略速度与停留参数或接受尚不支持的新文本模式和手势。

本地测试覆盖输入校验、引用失效、执行事实、画面校验和帧稳定；真机兼容性以 [README 中的实测环境](../README.zh-CN.md#前置条件)为限。历史操作记录、截图和诊断日志仅保留在本地，不作为公开运行依赖。执行前检查不构成与 App 自行变化原子隔离的事务。

Runner append 与 LF 多行的实现取舍、宿主测试和 Probe 精确字节验收见 [文本能力验证](runner-text-parity.md)。

## 原生文本方式与显式完成

仅 `apple-native` 支持 `type oN --mode insert|replace|append --method auto|keys|paste`。省略方式使用 auto；`keys` 为最多 64 个 ASCII 的 US 键码，结果受活动输入法影响；`paste` 允许最多 4096 UTF-8 字节的整段文本，包括纯 ASCII。auto 遇到 LF/CR 即选择整段粘贴，即使正文全为 ASCII；keys 拒绝换行。LF/CR/CRLF 不裁剪或规范化，其他控制字符仍拒绝。不会在方式失败后静默改用另一通道。此处的 --method 和原生快捷键语义不适用于 Runner；Runner append 的原文拼接与替换行为见上文。

粘贴回执中的 `result.pasteboard.transactionID` 标识当前剪贴板事务。外部 Agent 检查动作后截图并处理完粘贴确认框后，可执行 `text-finish oN --transaction ID`，核对所有权后恢复原剪贴板，保留媒体和键盘会话。要求当前、同设备/会话且在输入尝试结束后采集的截图（最长 30 秒）。完成结果的 `caller_confirmed` 仅记录调用方确认；`completed` 只表示剪贴板恢复并回读成功，不将原本未知的 HID 输入改写成设备确认。失败不重放恢复写入，未知结果需检查后关闭会话。

详细的原生事实字段、旧宿主兼容保护和限制见[原生后端](apple-native-backend.md#explicit-text-methods-and-clipboard-completion)。

原生显式字段的光标例外 `source-blue-caret-fade-v1` 只从原 observation 的 PNG 定位一个可见蓝色竖线，要求宽 1–3 points、高 8–40 points、周围背景均匀。新图仅允许该固定位置整体明暗变化；完整字段的其他像素按原分辨率逐通道检查，仍使用原 8/255 噪声容差。正文、选区、位置或背景变化不属于例外，全屏 1%、设备/会话、方向、30 秒时效和截止时间检查保留。普通差异比例仍输出；例外通过时额外记录 `screenGuard.caretBlinkException`，不能把非零 `regionChanges` 解释成阈值被调大。

原图光标不可见、颜色不支持、多个候选、邻近文字干扰或背景不均匀时回到原严格检查；不自动等待光标、不重新绑定基准、不重放输入。截图无法区分外观完全相同的蓝色文字竖线与光标，也无法仅凭光标消失证明焦点未丢失；这是像素启发式，不是焦点保证。`focusConfirmed=false` 和外部 Agent 的焦点确认、输入后核对责任不变。tap/swipe、XCTest 和未指定完整字段的 type 不使用该例外。


## 原生编辑按键与横屏文字

`apple-native` 的 `press oN --key KEY` 支持 `return`、`backspace`、`left`、`right`、`up`、`down`、`tab`、`shift-tab`、`escape`。使用当前截图确认焦点，可通过 `--field-rect x,y,width,height` 保护完整输入框。每次只发送一个按键或明确的 Shift+Tab 组合，包含释放；没有重复次数、任意快捷键或自动补发。Runner 的元素引用 `press oN:eN` 仍只接受 `return`。按键与 Unicode 粘贴共用最多三次只读预检：始终比较原 observation，沿用每阶段 8 秒及原观察 30 秒截止时间，方向变化立即拒绝；只重取截图，不重发按键。

这些名称表示 HID 键盘操作，不承诺业务效果：Backspace 的删除单位、方向键的光标位置、Tab 的焦点切换、Escape 的取消行为均由前台 App/IME 决定。回执保留 `key`、`keyReportQueued`、`keyboardReleaseQueued`、`keyEffectConfirmed=false`；本地发送完成仍是 unknown，需检查结果截图。Shift+Tab 先单独按下 Shift，再按 Tab，最后释放全部按键；取消或失败沿用同通道释放和不重放契约。

原生 `type` 和 `press` 可用于原生竖屏显示器的竖屏及左右横屏。无需旋转按键 usage；坐标输入框使用当前截图的屏幕点。文字模式、剪贴板所有权与恢复、设备/会话/30秒观察绑定、方向和截图保护保持不变。先使用 `text-prepare` 建立键盘，再观察并确认焦点；旋转后必须重新观察。具体真机验收范围见[原生后端记录](apple-native-backend.md)。


## Runner 长按与拖放

`long-press oN --x X --y Y --duration 0.8 --observe` 先核对当前截图，再通过 XCTest 坐标 press 执行按住和释放；时长范围 0.5–5 秒。宿主核对回执中的 duration，缺失或不匹配视为 unknown。长按菜单是否出现须检查新图。

长按后拖动复用 `swipe oN --from-x X --from-y Y --to-x X2 --to-y Y2 --press-duration 0.5 --hold-duration 0.2 --observe`，整条轨迹属于同一动作；不要把 long-press 和 swipe 两次调用视为连续按住。

Runner 新手势均使用截图坐标，不增加元素引用形式；沿用触点/路径局部保护、全屏保护和动作后判稳。验证范围见 [Runner 手势](runner-gestures.md)。

## 双击

`iphone-use --session SESSION double-tap oN --x X --y Y --observe` 在当前截图的一点执行两次按下/释放，适用于 standard 和 runner。坐标为原 PNG 对应的屏幕点，支持竖屏和左右横屏；沿用 tap 的触点邻域、全屏检查及观察/设备/会话绑定。没有元素双击、任意连点次数或间隔配置。Runner 使用 XCTest 坐标 doubleTap，由 XCTest 控制双击节奏；下述毫秒时序和 HID 事实字段仅适用于原生后端。

整个序列属于一个动作，发送前做一次截图预检，两次点击之间不采集截图。每次按下后保持至少 60ms、第一次释放后等待至少 100ms；第二次按下必须在动作起始 300ms 内开始，整个序列受 600ms 执行期限约束。宿主调度和传输可能增加间隔；错过窗口就停止，不把迟到的第二次点击补发成独立点击。持续检查取消和媒体健康，失败时沿用同通道触点释放。

一旦尝试发送第一次触控，后续错误都可能已产生单击或双击效果，返回 unknown，不能自动重放。`contactsAttempted`、`tapPairsQueued`、`hostDownUptimes` 只表示宿主发送事实，不确认设备识别。成功排队也仍需视觉检查新截图。双击选词、缩放等语义由 App 决定。

## 双指缩放

```sh
iphone-use --session "$SESSION" pinch oN --x 195 --y 350 \
  --from-distance 80 --to-distance 200 --duration 0.5 --observe
```

`pinch` 使用 standard 或 runner 的当前截图引用。`x/y` 是截图屏幕 points 中的固定中心，两指沿该图的水平方向对称移动。`from-distance`、`to-distance` 是两指间的完整距离：终值较大表示张开，较小表示收拢；两者至少 20 points 且相差至少 1 point，运动时长为 0.1–5 秒，默认 0.5 秒。输入距离比不保证 App 实际缩放比例。示例坐标仅为格式说明，必须从当前原图选择。

两条轨迹的起终点均须在当前观察范围内；不裁剪越界触点，不添加旋转或双指平移。原生支持 native-portrait 显示器的竖屏及左右横屏，复用当前方向映射、设备/会话绑定、30 秒有效期、全屏检查，并分别保护两条轨迹及按下邻域。参数不合法在发送前拒绝。

原生执行时每帧包含两个固定身份触点，不串行执行两个 swipe。起始和末端各保持至少 60ms，运动按目标 60Hz 采样，慢发送时跳过过期采样；整个执行期限 6 秒。取消、媒体失活或发送失败时，尝试在原通道以最后尝试位置同时释放两指，释放失败保留不确定状态。任何可能已发送的动作都不自动重放。

`contactCount`、`moveReportsQueued`、`hidStart/hidEnd` 和时序仅表示发送事实，成功排队仍为 `outcome=unknown`。必须检查新图确认 App 是否缩放；`status.capabilities.pinch` 表示控制路径可用，不是效果保证。真机证据范围见 [原生后端记录](apple-native-backend.md#native-pinch-2026-09-21)。


Runner 捏合使用自写 Objective-C 桥接 Apple XCTest 的事件合成对象，在一个事件中提交两条完整路径。方法签名在运行时核对；不兼容时输入前拒绝。事件标记 App 的 interfaceOrientation，路径在执行边界转换为原生竖屏坐标，不能使用手机 face-up 等物理朝向；此转换不适用于公开 XCTest 坐标点击 API。起末各保持 60ms，两指同时移动并释放；不把距离参数近似转换成元素 pinch 的比例。

Runner 收到完成回执后仍须通过动作后判稳，宿主核对 pinch 距离、时长和坐标单位。提交后异常或等待超时为 unknown，阻止该 Runner 会话后续动作输入；可以 observe 后关闭自己的会话，不补发手势。完整抬手事件交给 XCTest 执行，不通过原生 HID 或全局清理关闭其他客户端。断线期间是否执行完毕不能仅凭宿主回执推断。

## 原生 App 生命周期

```bash
iphone-use --session "$SESSION" terminate com.example.probe --observe
iphone-use --session "$SESSION" relaunch com.example.probe --observe
```

仅适用于 `apple-native`，bundle ID 来自 `apps`；不是坐标动作，无需引用旧截图。操作串行执行，使先前观察失效；成功或可能执行后，在同一设备工作队列内附加新截图。`--observe` 沿用动作与截图分开的响应，截图失败不丢失进程事实、不重放命令。现有 `open` 保留启动/激活语义，XCTest 拒绝新增命令。

`terminate` 将安装列表的精确 App 目录与进程可执行文件的直接父目录匹配；不按名称、子串匹配，不递归结束扩展或进程树。主进程候选必须唯一，PID/路径在发信号前再次核对。只发送一次 Apple 默认 SIGTERM，再有界查询确认旧进程消失；不升级 SIGKILL。已停止时返回 `alreadyStopped=true`、`terminationRequested=false`，不会发信号。未安装、身份不完整或匹配歧义在派发前拒绝。

`relaunch` 完成上述退出确认后，再核对无目标进程、安装目录未改变，调用一次 Apple `launch --activate`，随后要求进程列表出现与启动回执一致的新 PID。各阶段的 `terminationRequested`、`terminationAcknowledged`、`oldProcessAbsentConfirmed`、`launchRequested`、`launchAcknowledged`、`newProcessObserved`、`previousPID`、`newPID` 独立记录。`completed` 表示这些进程检查完成；`foregroundConfirmed=false`，仍由调用方看图判断是否前台就绪。冷启动不清除 App 磁盘数据，App 自己可能恢复持久化状态；未保存的内存状态可能丢失。

外部进程替换或 App 重装会中止后续步骤并要求新观察。超时、取消、读回失败或丢失回执发生在终止/启动尝试后，返回 unknown，保留部分事实，绝不自动重试或启动。读取使用短超时和整体期限；取消也传播到运行中的 Apple CLI 子进程。有待恢复的粘贴事务时，先看图并 `text-finish`，再执行生命周期命令；这里不会隐式恢复或丢弃剪贴板。

Apple 终止接口只接受 PID，进程列表没有进程出生令牌，因此最后一次核对与发信号之间不能提供原子身份保证。功能保留这一限制，不宣称完全排除 PID 复用竞态。受控真机验收及边界见 [原生后端记录](apple-native-backend.md#native-app-lifecycle-2026-09-21)。

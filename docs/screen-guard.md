# 动作前画面校验与坐标执行

画面校验覆盖 tap/swipe：宿主根据原观察准备坐标和画面指纹，Runner 重新截图并校验，通过后执行坐标手势。type/press 的 AX 目标解析、动作后的容差帧稳定检测、每次派发后重新 observe、unknown 不重发均保持不变。

上述 Runner 路径之外，实验性 apple-native 的 `type oN` 和 `press oN --key return` 都从当前截图生成完整字段保护，并在输入前重新截图校验；完整字段使用原分辨率局部比较与颜色无关的有界光标排除，不读取 AX 或自动聚焦。`text-prepare` 只准备自有键盘，随后使旧引用失效并返回新图。具体约束见[原生文字输入](actions.md#实验性原生文字输入)。

这是启发式的动作前置条件，不是页面 ID、目标身份保证、业务正确性或事务隔离。每次 observe 仍产生新引用；相似画面不恢复失效引用，也不合并观察。

### 标准模式的观察时间与动作前复核

原生坐标 tap、double-tap、long-press、pinch、swipe 只接受本会话的当前 observation，不再因选坐标耗时超过 30 秒而直接拒绝。开始处理动作时建立 30 秒总派发预算，方向/连接准备和最多一次自有媒体恢复计入总预算。方向验证完成、即将请求 Apple PNG 时才建立 8 秒最终校验期限，必须在总期限及最终期限内完成截图、后置状态检查、与原观察比较并进入输入。准备耗时不提前消耗这 8 秒；同一阶段不能重置期限或循环截图，原比较基准不变。预算不包含随后手势本身的执行时长。

新截图完成后，即使像素匹配，若检查已超出预算，坐标手势与文字校验均返回 `input_preflight_timeout`；若已拿到有效截图，附 `preInputDeadlineExceeded=true` 和实际拒绝帧。若 Apple 查询被预算中断且尚无完整有效图，则保留失败阶段，不把未完成截图当作新观察。发生方向恢复时，`orientationRecovery` 记录首次失败检查、恢复、重采集的分段耗时及媒体状态；`captureTimingsMs.total` 包含整个恢复过程，`successfulAttemptTotal` 仅是最终成功截图的内部耗时，不能将两者相加。`orientationRecovery.trigger` 区分静默流、帧交付延迟、方向冲突及连接不可用；分类不替代新鲜方向证据。`preparationMs` / `validationAndCheckMs` 分别记录本阶段准备和最终校验耗时。Apple 查询等待期间检查剩余预算，超时会终止并回收该查询进程，进程清理可有少量额外耗时。

设备和会话绑定、来源、显示器、方向、图像尺寸、整屏和目标/路径保护、取消及媒体健康检查均保留；非法或未来的捕获时间仍拒绝。新观察取代旧观察、动作已派发、连接重建后，旧引用依然无效。结果的 `inputTiming` 记录采用的策略和受理时原观察年龄；它不是页面身份或目标仍存在的确认。

原生文字和按键也以当前观察为比较基准，从请求受理开始设立 30 秒输入派发预算；剪贴板处理前后各自从 Apple PNG 请求起最多 8 秒复核（方向准备仍计入同一个 30 秒总预算），最后阶段的期限同时约束所有权检查和派发。`text-finish` 要求当前、动作后截图及匹配事务，不以截图年龄拒绝恢复；所有权仍在恢复前重新读取。Home、录屏沿用各自现有期限；Runner 时序不变。看到相同画面仍不能排除页面曾变化后恢复，尤其无法保证框外业务状态没有变化；调用方仍需按任务核对重要信息。

## 调用方式

```sh
iphone-use --session "$SESSION" tap o1:e10
iphone-use --session "$SESSION" tap o2 --x 195 --y 380
iphone-use --session "$SESSION" swipe o3:e50 --direction up
iphone-use --session "$SESSION" swipe o4 --from-x 97 --from-y 405 --to-x 97 --to-y 365
iphone-use --session "$SESSION" tap o5:e10 --protect o5:e20 --protect o5:e21
iphone-use --session "$SESSION" tap o6:e10 --max-screen-change 0.01 --max-region-change 0
```

上面的引用、坐标均为示例，不能直接用于当前设备。`--protect` 可重复最多三次，引用必须属于这次动作的同一观察；适合显式保护要保存的日期、数量、对象名称等。默认不会推断哪些业务字段重要。

- 元素 tap 使用捕获 frame 与当前观察 scope 相交部分的中心点。元素 swipe 使用该区域轴向 80%→20%（up/left）或 20%→80%（down/right）的端点。空 identifier/label 不影响坐标解析。禁止自动滚动寻找离屏元素。
- 坐标 swipe 必须同时提供四个端点参数，以观察 ID 为引用，不能混用元素引用或 `--direction`。单位是屏幕点，不是 PNG 像素；起终点必须在原 scope 内且至少相距 1 点。
- Runner 使用 XCTest 坐标 tap，或带 `withVelocity` / `thenHoldForDuration` 的 `press(forDuration:thenDragTo:)` 重载。拖动速度、起始按住和结束停留由已校验的 motion 参数指定；这仍是 XCTest 坐标原语，不承诺内容位移或底层 HID 的精确时序。参数见 [可控拖动](actions.md#可控拖动)。
- `--max-screen-change` 和 `--max-region-change` 满足 `0 <= region <= screen <= 1`。修改阈值是调用方明确选择，Runner 不会自动放宽阈值、重试或修正坐标。设置为 1 会使对应相似度限制失去拦截能力，上下文检查仍有效。

## 算法及责任边界

### 页面中的自动播放视频

对当前截图中明确可见、与动作无关的视频或动画，可在**一次坐标动作或原生文字/按键动作**上指定 `--ignore-rect x,y,width,height`，单位是截图的屏幕点。原生 `type` / `press` 必须同时提供完整 `--field-rect`，视频区域不得与字段重叠；Runner 元素输入不使用此参数。例如：

```sh
iphone-use --session "$SESSION" swipe o7 --from-x 315 --from-y 685 --to-x 315 --to-y 280 \
  --ignore-rect 70,385,228,171 --observe
```

此处坐标只演示语法，必须根据当前观察重新选择。Agent 负责视觉识别视频，后端不会自动将画面变化分类为视频，也不把该区域存入会话偏好。每次动作都绑定原 observationID，换页、滚动或获得新观察后不能沿用旧位置。

支持截图坐标的 tap、double-tap、long-press、pinch、swipe，以及指定完整字段的原生 type/press。只允许一个矩形，必须完全位于屏幕内、面积不超过屏幕的 25%，并与全部保护区域不相交：触点周围、滑动走廊、双指路径、完整输入框及额外 `--protect` 都不能被排除。25% 是首版范围限制，不是正确率保证。如果视频挡住了滑动走廊，应基于新图选择视频外路径，不能让后端移除路径保护。

未指定时仍使用原 `srgb-grid-v1`。指定时使用 `srgb-area-excluded-rect-v2`：将矩形外画面分成最多四个互不重叠的矩形，各自先裁剪，再对每个网格单元覆盖的全部原生 sRGB 像素取整数平均，按原 32×64 全局网格密度向上取整分配行列；以剩余画面面积加权计算变化比例，分母不含排除区域。网格单元按原生像素整数边界分区，余数像素也被计入；每个裁剪区域最多处理 1600 万像素，超出时拒绝比较。旧版高质量插值会把极窄的残留动画边缘放大成整格变化，新版不会自动扩大排除框。完整整屏比较仍记录为 `rawScreenChange`，实际接纳使用排除后的 `screenChange`。保护区域仍使用原始图及 48×48 网格，默认整屏 0.01、局部 0、颜色容差 8 不变。

结果同时记录 `ignoredRect`、`rawScreenChange` 和 `exclusionScope=global_comparison_only`。标准与新版 Runner 共用此实现；宿主核对 Runner 的算法、矩形及排除范围回执。旧 Runner 不认识新的算法名，会在输入前拒绝，使用此参数前需构建配套 Runner，不能把旧 Runner 的拒绝当作动作执行。未使用参数的旧路径保持兼容。额外指纹仍受原报文预算约束，过大请求明确拒绝。

此选项只排除动画内容，不保证区域内发生的变化无业务意义，也不能识别视觉上相同的页面替换。不要圈住身份、价格、确认对象等决定动作含义的信息；对这些信息应继续保护。局部媒体噪声采用下述独立比较，不据视频样本放宽局部阈值。动作后的 Runner 判稳不因该选项改变，不能据动作前通过保证视频页面在动作后会被判稳。

### 默认比较

共享的 `ScreenGuard.swift` 是宿主与 Runner 编译使用的无状态比较模块，不拥有 AX 查询、短 ID、缓存或任务策略。

1. 宿主从观察中读取截图、screen/scope frame、设备 orientation、键盘数量，将元素引用解析为坐标，并生成基准指纹。
2. 指纹算法 `srgb-grid-v1` 将截图按图片方向归一化，以固定屏幕坐标裁剪，再采样到 sRGB RGB 网格。整屏为 32×64，保护区域为 48×48；保留颜色，不做平移对齐、旋转容差或语义嵌入。
3. 每个网格单元任意颜色通道的差值大于 8/255 即算变化。变化比例是变化单元数除以总单元数，不是原始像素面积比例，更不是“页面相同的概率”。
4. 自动保护触摸起点周围 64×64 点；swipe 另保护起终点包围框向外扩展 16 点的区域。保护区域裁剪到屏幕，额外 `--protect` 使用引用可见部分。最多五块局部区域，完整命令受已有 60 KB 宿主预算/64 KiB Runner 请求限制约束。
5. Runner 保留前台 App 和 App/System Alert 范围检查；屏幕和 scope 的 frame 最多容忍 0.5 点差异，orientation、键盘数量和截图像素尺寸必须一致。不相符则在输入前拒绝。AX 的完整重采样和 type/identifier/label 查询不再进入 tap/swipe 路径；这些动作的 XCTest 内部行为不在此保证内。
6. Runner 采集一张新截图，与命令携带的原始基准比较。整屏和每一块保护区域都通过各自阈值后，才进入标记 `execution.started` 的输入调用。Runner 不用历史截图代替本次采集；文本操作另保留观察对应的 AX 身份用于校验。

默认整屏阈值 0.01、局部阈值 0，属于保守工程初值，不是经过多 App 校准的安全值。局部 0 仍允许颜色噪声底限内的变化和降采样无法分辨的变化。

### 标准模式的固定截图来源

标准模式观察、文字准备、动作前校验和动作后观察统一使用 Apple CoreDevice PNG，`captureSource=coredevice_screenshot`、`captureSourcePolicy.strategy=coredevice_only`。没有媒体像素后备来源；Apple 截图失败即报告失败，不改用视频帧。每次动作仍比较原 observationID 绑定的截图，真实变化或期限超限返回拒绝及可用的新观察，不自动重放输入。

原生媒体手势专用的 `native-gesture-edge-v1`、`regionAppearanceMatches` 和相关诊断已移除。坐标手势仍要求整屏及每一块保护区域通过上述网格规则；像素底限、全局/局部阈值、显式视频排除范围没有扩大。文字输入保留完整字段和显式观察绑定的光标区域校验，Apple PNG 不会消除实际光标或动画变化。

标准观察和 HID 输入不依赖常驻媒体流；自有媒体只为显式预览或录屏启动，并保留录屏期间的几何校验。方向改变后拒绝旧坐标，录屏方向证据失效时结束片段、确认自有流停止后重取 Apple PNG。详见 [原生后端](apple-native-backend.md#screenshots-and-input)。

现有归一化像素 SHA-256 保留，用于精确帧身份和动作后稳定证据校验；相似度网格是额外的参考特征，不通过 SHA-256 字符差异衡量画面变化，Runner 动作后可返回尚未稳定的动态观察，见[Runner 执行结果](actions.md#执行结果)；标准模式使用独立的[15 秒有界判稳](actions.md#动作后观察)。

## 结果与失败

动作结果附带 `result.screenGuard`：algorithm、accepted、screenChange、regionChanges、阈值、区域边界和采集时间。不会把基准 RGB/base64 输出给调用 agent。宿主对成功的坐标动作核对校验分数、阈值与通过事实；缺失或矛盾的成功证据转成 unknown。

- 超阈值：`screen_changed`、`not_dispatched`、`requiresObservation=true`，已知没有发送输入；原引用失效。
- 上下文变化或采样/指纹不可用：同样在输入前拒绝，返回具体 reason 并要求重新 observe；缺失证据不是零变化。
- 参数、坐标、保护引用不合法：宿主或 Runner 拒绝，不发送输入。
- 输入后的执行失败、丢失响应或无法取得足够观察：沿用 unknown 和不重发规则，不把动作前的通过证据当成动作完成。

CLI 与 Runner 在连接时协商协议和能力。不兼容时返回 runner_needs_rebuild；发布包用户安装配套版本并 setup，源码开发者重新 build-runner 并显式安装新 App。不静默忽略新参数或回退到无校验坐标输入。

## 验证边界与剩余风险

本地验证覆盖：完全相同/仅编码元数据不同、小范围无关刷新、小范围目标变化、操作区不变但整屏大变、按钮不变但额外日期区改变、颜色变化、左上角坐标方向、阈值边界与噪声底限、方向/键盘/范围/尺寸变化、缺失指纹、手势保护区域不可省略、空名称滚轮的坐标映射、最大报文预算、失败事实与引用失效、旧协议拒绝。

本地测试数据是固定合成像素和已记录 AX；通过这些测试不证明任意 App 的误放行率或真机性能。还需扩大真实刷新/遮挡/重排样本来校准阈值。后续证据与未验证项应明确区分，不通过调高阈值掩盖失败。

降采样可能遗漏细小文字或局部变化；大区域内的小变化也可能被稀释。不可访问的遮挡、无可见变化的 enabled/focus 更新、相同画面背后的业务状态变化不能仅靠截图保证。坐标 tap 不再承诺旧 AX 路径的 live enabled/isHittable 检查。需要精确命中时使用明确坐标，重要上下文由调用方保护并在动作后检查。

AX 与截图的 observe 采集不是原子的，动作前采样与触摸也不是原子的。此校验不会冻结 App，也不承诺检测所有输入前变化。若后续要为动作后稳定检测加入相似容差，需要独立的固定窗口基准规则，不能把相邻帧小幅变化误判成停止运动。

frameStabilityVersion=2 使用动作后的容差判稳（色差、受限光标例外与最短观察窗口）；输入前 screenGuardVersion=1 的规则不变。见 [执行结果](actions.md#执行结果)。

## 全屏动态画面的覆盖控件

两种模式新增显式坐标 tap 的 `--dynamic-target` 与 `--dynamic-anchor`，采用 `bounded-overlay-contrast-v1` 校验原位置的目标形状和独立页面锚点。该分支不要求视频背景不变；默认整屏规则、其他动作与文字校验不变。具体用法及边界如下。

默认整屏校验保留。需要点击视频上的返回、暂停等可见控件时，两种模式新增显式、有限范围的校验：

```sh
"$IPHONE_USE_CLI" --session "$SESSION" tap oN --x X --y Y \
  --dynamic-target TARGET_X,TARGET_Y,TARGET_W,TARGET_H \
  --dynamic-anchor ANCHOR_X,ANCHOR_Y,ANCHOR_W,ANCHOR_H --observe
```

坐标来自当前原图，单位是 `screen_points`。目标框完整包住图标或文字，最大 96×96；另选一个能辨认页面的标签或控件作为锚点，最大 256×96；两框不能重叠，点击必须在目标框内。只支持坐标单击，不支持元素引用、滑动、双击，也不能与 ignore/protect 或放宽阈值组合。

`bounded-overlay-contrast-v1` 比较原坐标处两个局部形状，去除局部平均亮度以容忍视频明暗和半透明控件；不搜索其他位置，不自动扩大范围。`screenChange` 仍报告实际整屏变化，但此模式的接受依据是两个局部匹配，`validationScope=explicit_target_and_anchor`，不是整屏不变。

这不是语义识别或 App 身份证明。控件消失、移动、遮挡、低对比度、文字变化和强背景纹理仍可拒绝；应检查新画面后作决定，不自动重放。不要用无关状态栏图标充当页面锚点，也不要用于提交、支付或破坏性操作。旋转后重新观察并选框。无法选出可靠控件和锚点时应停止，不能靠杀 App 恢复。

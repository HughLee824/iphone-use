# Runner 编辑按键

2026-09-23：Runner 的 `press` 增加退格、四个方向键、Tab 和 Shift+Tab，保留 Return。需要配套 `actionVersion=9` Runner；旧 Runner 在连接时要求重新构建。标准模式的键盘和原生媒体路径不变。

```sh
iphone-use --session "$SESSION" press o1:e23 --key backspace --observe
iphone-use --session "$SESSION" press o2:e23 --key left --observe
iphone-use --session "$SESSION" press o3:e23 --key tab --observe
```

示例引用必须替换为刚观察到的输入框。操作要求已有键盘焦点，不额外点击或搜索焦点。Tab 后应检查新图，再选择新的输入框引用。名称区分大小写；没有任意组合键、重复次数或自动补发。

| key | Runner 路径 | 完成后应观察什么 |
| --- | --- | --- |
| return | `typeText(XCUIKeyboardKey.return)`，沿用已有实现 | 换行、提交或 App 定义行为 |
| backspace | `typeText(XCUIKeyboardKey.delete)` | 字符或选区被删除 |
| left / right / up / down | `typeKey` 与 Apple 对应方向键常量，无修饰键 | 光标/选区或 App 定义行为 |
| tab / shift-tab | `typeKey(Tab)`，仅 Shift+Tab 携带 Shift | 焦点切换或 App 定义行为 |
| escape | **Runner 不支持**；`unsupported_key`，派发前拒绝 | 标准模式仍保留自己的 Escape 实现；不自动切换模式 |

## 执行与保护

仍验证会话、当前 observation、来源 AX 目标及完整祖先路径、观察期 AX 身份与精确绑定、enabled/isHittable 和输入框角色。成功回执增加 `key` 与 `keyModifiers`；宿主必须核对它们与请求一致，否则返回 unknown。输入调用前后和判稳后的执行事实分开记录。completed 表示 XCTest 输入调用正常返回且达到既有画面稳定条件，不等于 App 业务效果被确认。

Tab/Shift+Tab 可以把焦点移出来源字段。它们执行后读取一次快照，遍历 XCTest 返回的完整快照，最多允许 8 个完整位于当前范围内的输入框参与光标检查；字段数超限或键盘状态不适用时不启用光标例外。只有候选字段中识别出唯一符合既有模型的蓝色光标，才允许该笔画闪烁。其余字段和全屏仍进行像素比较。没有焦点遍历、滚动、整字段遮罩或阈值放宽，也不把像素识别当作焦点证明。

普通 type/press 仍使用来源输入框；tap 仍仅对唯一完整可见输入框启用光标例外。判稳超时保持 `inputCompleted=true`、`outcome=unknown`，观察实际结果，不自动重发。当前光标模型仍可能在特定相位、字形邻接处拒绝合法闪烁。

## 真机验证与限制

重新检查环境：macOS 27.0 (26A428)、Xcode 27.0 (27A266a)、iPhone 12 Pro / iOS 27.0 (24A437)。设备通过 Apple CLI 动态发现，未硬编码标识。只操作普通 iPhone-use Probe 的双输入框页面，检查截图及 Probe 展示的文本、UTF-16 选区、焦点和快捷键计数；没有修改设置、访问聊天或剪贴板。

| 检查 | 实际观察 |
| --- | --- |
| Backspace | 初版 `typeKey(Delete)` 返回但没有删除；改为 `typeText(Delete)` 后，“头🙂尾”变为“头尾”，选区从 3,0 变为 1,0，编辑计数仅加 1；判稳完成 |
| Left / Right | 光标从 emoji 后的 3,0 移到 1,0，再回到 3,0；正文不变。Left 完成；Right 实际移动，但该次判稳超时 |
| Up / Down | 多行“头🙂尾\\nABCD\\n1234”中，位置从第二行的 7,0 上移到 1,0，再下移到 7,0，正文不变。Up 完成；Down 的该次判稳超时 |
| Tab | 焦点从字段 1 移到字段 2，Tab 计数加 1。初版判稳只覆盖来源字段而超时；修复后识别目的字段光标并完成 |
| Shift+Tab | 焦点回到字段 1，ShiftTab 计数加 1。第一轮完成；另一轮实际切换后判稳超时。随后插入小写 x 得到“头x尾”，但 typeText 本身会清除修饰键，不能独立证明修饰键释放 |
| Escape | `typeKey(Escape)` 和 `typeText(Escape)` 均返回，但没有触发 Probe Escape 计数或收起键盘。最终版本不广告支持，不把调用返回当成功 |

这些是指定工具链和 Probe 的验收结果，不代表所有第三方 App 都采用相同快捷键语义。未对真实按键派发过程中断连/取消做故障注入。保留首轮失败和后续独立新动作的记录，没有重放 unknown 原请求。

宿主最终 `swift test`：291 项，290 通过、1 项既有 opt-in 测试跳过、0 失败。覆盖参数/目标准入、Escape 拒绝、错误或缺失按键回执、光标候选唯一性、其他字段变化不能忽略，以及原有保护。CLI 动作/观察测试 16 项、模式测试 6 项通过。宿主测试不能代替上表的实际按键效果。

最终签名 Runner 连接成功，`support.pressKeys` 仅包含上述 8 项（含 Return，不含 Escape）。额外 Return 真机回归因自动锁屏而未执行；不是通过记录。四次自身测试会话均收到 shutdown 确认，xcodebuild 正常退出，观察缓存移除。Release CLI 和最终签名 Runner 构建成功；一次构建启动被信号中止且无结果，在宿主重新链接结束后独立构建成功。

本地原始回执、截图与构建日志：`.local/research/runner-keys-20260923/`。该目录不是运行依赖；没有新增第三方设备工具。

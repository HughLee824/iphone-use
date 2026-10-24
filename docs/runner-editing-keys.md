# Runner 编辑按键

Runner 支持 Return、退格、四个方向键、Tab 和 Shift+Tab。CLI 与 Runner 必须通过当前能力协商；支持列表以会话返回值为准。

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

仍验证会话、当前 observation、来源 AX 目标及完整祖先路径、观察期 AX 身份与精确绑定、enabled/isHittable 和输入框角色。成功回执增加 `key` 与 `keyModifiers`；宿主必须核对它们与请求一致，否则返回 unknown。输入调用前后和判稳后的执行事实分开记录。completed 表示输入流程完成；附带的稳定性事实仍需单独读取，不等于 App 业务效果被确认。

Tab/Shift+Tab 可以把焦点移出来源字段。它们执行后读取一次快照，遍历 XCTest 返回的完整快照，最多允许 8 个完整位于当前范围内的输入框参与光标检查；字段数超限或键盘状态不适用时不启用光标例外。只有候选字段中识别出唯一符合既有模型的蓝色光标，才允许该笔画闪烁。其余字段和全屏仍进行像素比较。没有焦点遍历、滚动、整字段遮罩或阈值放宽，也不把像素识别当作焦点证明。

普通 type/press 仍使用来源输入框；tap 仍仅对唯一完整可见输入框启用光标例外。输入后的错误保留已执行事实；若返回 `unknown`，观察实际结果，不自动重发。动态画面的 `stable=false` 本身不等于输入失败。当前光标模型仍可能在特定相位、字形邻接处拒绝合法闪烁。

验证流程与边界见[测试指南](testing.md)。

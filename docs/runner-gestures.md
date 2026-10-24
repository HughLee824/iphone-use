# Runner 手势

Runner 模式现支持截图坐标 `long-press`、`double-tap` 和 `pinch`；长按拖放复用带 `--press-duration` 的 `swipe`。标准模式仍使用原生截图/HID，不会为这些动作启动 Runner。CLI 与 Runner 必须通过当前能力协商；不兼容版本在连接阶段拒绝。

## 使用与执行边界

先在当前会话 observe，检查截图，再替换下例的观察 ID 和坐标。每条动作之后获取新观察，不能复用示例中的旧引用。

```sh
iphone-use --session "$SESSION" long-press o1 --x 195 --y 171 --duration 0.8 --observe
iphone-use --session "$SESSION" swipe o2 --from-x 195 --from-y 299 \
  --to-x 195 --to-y 430 --press-duration 0.8 --hold-duration 0.3 --velocity 300 --observe
iphone-use --session "$SESSION" double-tap o3 --x 195 --y 133 --observe
iphone-use --session "$SESSION" pinch o4 --x 170 --y 350 \
  --from-distance 80 --to-distance 180 --duration 0.5 --observe
```

长按、双击使用公开 XCTest 坐标 API。捏合需要保留调用方选择的中心、两指距离和时长，使用自写 `RunnerPinchEvent.m` 桥接 Apple 的 `XCPointerEventPath`、`XCSynthesizedEventRecord` 与 `XCTRunnerDaemonSession`。这是 Runner 内的私有运行时边界，不是公开 SDK 兼容承诺，也不建立另一个原生控制会话。

桥接核对 Objective-C 方法签名后才构造事件；不匹配在输入前返回 `unsupported_pinch_runtime`。一次事件包含两条从按下、移动到抬起的完整路径，起末各保持 60ms，移动按 60Hz 采样。完成回调超时或提交异常返回 unknown，禁止该会话后续动作输入；调用方可以观察并关闭自己的会话。迟到回调不会重放，断连或进程终止是否已完成释放不能由宿主测试推断。

所有手势沿用当前观察、目标 App、前台范围、全屏和路径局部保护、动作后判稳。手势执行前确认 App 界面方向有效且未在检查期间变化。宿主额外核对长按时长和捏合几何回执。`completed` 表示输入流程完成；附带稳定性事实需单独读取，App 是否显示菜单、完成拖放或缩放仍由新截图确认。

## 横屏坐标

截图守卫始终使用当前截图对应的屏幕点。底层捏合事件路径需要转换为原生竖屏点，同时单独标记 App 的 `interfaceOrientation`。不能使用 `UIDevice.orientation`，因为设备可能平放且界面方向不同。

设当前截图点减去屏幕原点后为 `(x,y)`，屏幕点尺寸为 `(w,h)`：

| App interfaceOrientation | 捏合事件坐标 |
| --- | --- |
| 1，竖屏 | `(x,y)` |
| 2，倒竖屏 | `(w-x,h-y)` |
| 3，横屏 | `(h-y,x)` |
| 4，另一横屏 | `(y,w-x)` |

只在捏合的底层事件边界应用此转换。公开 XCTest 坐标点击使用原有 App 相对坐标，不能重复转换。倒竖屏仅有宿主映射测试，不在当前真机验证范围内。

验证流程与边界见[测试指南](testing.md)。

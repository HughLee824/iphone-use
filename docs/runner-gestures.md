# Runner 手势与真机验证

Runner 模式现支持截图坐标 `long-press`、`double-tap` 和 `pinch`；长按拖放复用带 `--press-duration` 的 `swipe`。标准模式仍使用原生截图/HID，不会为这些动作启动 Runner。需要重新构建配套 Runner（`actionVersion=7`）；旧 Runner 在连接阶段拒绝，不静默忽略新手势。

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

所有手势沿用当前观察、目标 App、前台范围、全屏和路径局部保护、动作后判稳。手势执行前确认 App 界面方向有效且未在检查期间变化。宿主额外核对长按时长和捏合几何回执。`completed` 表示输入流程结束且判稳通过，App 是否显示菜单、完成拖放或缩放仍由新截图确认。

## 横屏坐标

截图守卫始终使用当前截图对应的屏幕点。底层捏合事件路径需要转换为原生竖屏点，同时单独标记 App 的 `interfaceOrientation`。不能使用 `UIDevice.orientation`，因为设备可能平放且界面方向不同。

设当前截图点减去屏幕原点后为 `(x,y)`，屏幕点尺寸为 `(w,h)`：

| App interfaceOrientation | 捏合事件坐标 |
| --- | --- |
| 1，竖屏 | `(x,y)` |
| 2，倒竖屏 | `(w-x,h-y)` |
| 3，横屏 | `(h-y,x)` |
| 4，另一横屏 | `(y,w-x)` |

只在捏合的底层事件边界应用此转换。公开 XCTest 坐标点击使用原有 App 相对坐标，不能重复转换。倒竖屏仅有宿主映射测试，本轮 Probe 不支持该界面方向，未做真机验证。

## 2026-09-22 至 23 日验证

实际环境：macOS 27.0 (26A428)、Xcode 27.0 (27A266a)、iPhone 12 Pro / iOS 27.0 (24A437)。通过 Apple devicectl 重新发现物理设备，没有在实现中硬编码设备标识。仅操作签名安装的普通 iPhone-use Probe；曾使用 Apple 启动命令重启 Probe 清理遗留键盘，属于测试准备，不是后端自动回退。

| 验收 | Probe 实际结果 | 证据位置（本机忽略目录内） |
| --- | --- | --- |
| 长按 0.8s | 菜单出现；点击确认后 Menu choices=1 | `device-final/long-press.out`、`menu-confirm.out` |
| 长按拖放 | Received: SOMA；Drag starts=1、ends=1、Drops=1 | `device-final/drag.out` |
| 双击 | Double=1、Single=0 | `device-final/double-tap.out` |
| 竖屏向外/向内捏合 | Zoom 1→2→1.051；两次 began/ended，active=0 | `device-final/pinch-out.out`、`pinch-in.out` |
| 修复后的左横屏捏合 | Zoom 1→1.711；中心 299,235→300,235；peak=2、ended=1、active=0 | `device-mapping/pinch-left.out` |
| 修复后的右横屏捏合 | Zoom 1→1.711；中心 299,235→300,235；peak=2、ended=1、active=0 | `device-trace/pinch-right.out` |
| 公开 XCTest 横屏点击 | 请求 300,235；Probe 显示 Tap 300,235，返回竖屏按钮生效 | `device-trace/trace-tap.out`、`portrait.out` |

捏合中心在 UIKit 识别开始时有 1 点差异，末端匹配请求。App 的实际缩放比例不保证等于手指距离比。所有表中效果均检查了新截图，而非仅根据命令退出码或完成回执。

初版左横屏虽然返回完成且发生缩放，但偏心位置错误，因此不计通过。修复后新增 Probe 可见中心读数直接验证，避免把缩放成功误认为坐标准确。

另有独立现象：从 Probe 左横屏直接请求 Right 后，点击位置 513,21 和 Request Right 回调均得到确认，但最终 UIKit 方向仍为 4；原因未进一步确定，不能宣称该直接旋转通过。经 Portrait 分别进入两种横屏成功。这个现象不证明点击偏移，也不阻塞上述左右横屏捏合验收。

Probe 的被动点击跟踪在手势回调内刷新，单击后一次读数保留了 recognizer 当时的 active=1；后续布局刷新为 0。该诊断标签不是持续硬件触点监视器。捏合自身的结束回调另有延迟刷新，表中捏合 active=0 来自该刷新后的观察。

两次进入工作页前因画面变化超过 1% 被守卫拒绝，均为 `not_dispatched`；检查返回新图后另选新动作，没有重放未知动作或放宽阈值。三次测试会话均仅关闭自身，收到 shutdown 确认、xcodebuild 正常退出且观察缓存移除；相关宿主和 xcodebuild PID 已核对退出。

## 宿主验证与复现

`swift test`：执行 283 项，282 通过、1 项既有 opt-in 测试跳过、0 失败。覆盖动作准入、守卫、序列化、回执不一致保留 unknown、四方向映射。CLI 模式回归另外 6 项通过，仅使用隔离临时目录，不连接设备。Release CLI、签名 Runner 和普通 Probe 均构建成功。本轮没有运行远端 CI 或复测其他 iOS/Xcode 版本。

ObjC 桥接测试使用宿主运行时替身，不加载真实 XCTest，也不访问设备；覆盖完整双指路径、方向、抬起、失败、超时、迟到完成与禁止再次提交。已加入 CI，可在仓库根目录运行：

```sh
mkdir -p .build
xcrun clang -fobjc-arc -framework Foundation -framework CoreGraphics \
  Runner/RunnerPinchEvent.m Tests/RunnerRuntime/PinchEventTests.m \
  -o .build/runner-pinch-runtime-tests
.build/runner-pinch-runtime-tests
```

原始回执、截图、构建日志及失败样本保存在 `.local/research/runner-gestures-20260922/`。本轮未对真实进程中断或断连期间的双指释放做故障注入，未验收任意第三方 App 的手势语义，也不表示两种模式的全部功能已经对齐。

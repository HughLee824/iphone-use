# 两种模式的原生媒体录屏

录屏传输与控制模式分开：Runner 的截图、元素、点击和输入仍由 XCTest 执行；显式 `record-start` 或 `preview` 按需创建自有 CoreDevice displayservice 媒体连接，使用与标准模式相同的 HEVC/RTP 接收、MP4 写入和完整解码验证。不会建立 HID 或剪贴板服务。

```sh
iphone-use connect --mode runner --device "$DEVICE" --xctestrun "$XCTESTRUN"
iphone-use --session "$SESSION" record-start --duration 60
# 重新 observe，再按新截图/元素引用执行 Runner 动作。
iphone-use --session "$SESSION" record-stop "$RECORDING_ID"
```

- 复用同一组命令、1–300 秒时长、录制 ID 和 `recordings/<UUID>/screen.mp4` 文件契约。
- 连接 Runner 时不创建原生媒体会话；`recordingSupport.availability=not_checked` 不是可录制的证明。显式开始时再检查 macOS/iOS 27、配对、解锁、方向、媒体互斥、协议及 RTP 时钟。
- 未开启预览时，每个新录制使用独立的自有媒体流；预览已开启时，新录制订阅已有解码器，不重启共享流。停止只作用于自有资源；旧 ID 重复停止不会影响后续录制，未知 ID 被拒绝。未知开始/清理结果不重放，按返回的恢复要求显式处理。
- `record-stop` 在同一 Runner 会话内完成文件写入与完整解码；预览仍开启时保留媒体，报告 `mediaRetainedForPreview`，否则清理媒体。不等待 XCTest 结束，也不重建 Runner。清理未确认时保留文件事实并返回 unknown。
- 时长到达由现有录制队列自动结束文件；若无预览消费者，随后的 status、观察、动作或 disconnect 回收媒体。会话 idle/signal 清理也先结束文件，再关闭媒体和 Runner。
- status、观察和动作边界检查显示状态；预览开启时还有串行后台检查。发现方向/锁屏变化时结束本段；不承诺连续旋转录制。每个视频帧都不是 observation，录制或预览开始/停止后需要重新 observe。
- 当前源码独立后台启动已安装 Runner，经 USB 本地通信控制，不再创建 IDE 驱动测试会话或改写 `.xctestrun` 副本。原始签名产物及调用者清单不改动。已有预览帧时，先准备录屏编码器再订阅共享像素，录屏时长从准备完成后开始。

启动返回成功不代表整段录制成功。务必检查该 recording ID 的最终 `error`、`stopReason`、`writtenFrames`、`fileValidated` 和文件内容；资源受限时可能提前出现 `recording_backpressure`，即使浏览器画面仍正常刷新。


## 时间轴、验证与限制

正常手动/定时停止可保留末帧到停止时间的显示时长；它不证明静止期间持续收到新画面。每个片段的方向固定，方向变化结束片段。共享预览时的静态源恢复会记录 `sourceRefreshes`，同一文件内仍可能有采集空档。详细恢复与共存行为见[预览指南](local-preview.md#预览与录屏共存)。

文件验证完整解码并核对时间戳与真实写入帧数。MP4 明确声明的空白编辑段单列为 `emptyEditFrames`，不通过放宽计数容差接受缺帧。`fileValidated=true` 证明文件检查通过，不证明视频内容满足任务，也不承诺稳定 30 fps。没有音频。

## 为什么不使用 XCTest 附件录屏

XCTest 附件通道能在测试结束后导出视频，但此前研究未建立会话存续期间即时取回本次文件的路径。当前 `record-stop` 需要保持控制会话可用，因此采用共享原生媒体通道。过时的附件录屏探针已删除；历史实现可从 Git 提交 `4e31f6c` 检索。它不是产品依赖或当前验收工具。

可复现的输入、录屏、清理验证及证据要求见[测试指南](testing.md)。

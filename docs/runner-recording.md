# Runner 原生媒体录屏

2026-10-12 当前源码还支持[本地浏览器预览](local-preview-prototype.md)：两种模式共用自有媒体流，预览开启后启动录屏可共享已解码像素。稳定 30 fps 未通过验收，方向恢复可能延迟；逐轮成功和失败结果见[预览验收历史](local-preview-validation.md)。以下当前契约已更新为包含预览的行为，旧验收只适用于各自标明的版本。

2026-10-01 候选的 [Runner 共存验收](runner-candidate-acceptance.md)已补充当前 VRA 解码路径的真机证据：双击计数经截图及视频确认，22.183 秒 / 689 帧，停止录屏后同一 Runner 单击仍可用。下文保留实现契约与此前版本的历史验证。

本次实现将控制模式与录屏传输分开：Runner 的截图、元素、点击和输入仍由 XCTest 执行；显式 `record-start` 或 `preview` 按需创建自有 CoreDevice displayservice 媒体连接，使用与标准模式相同的 HEVC/RTP 接收、MP4 写入和完整解码验证。不会建立 HID 或剪贴板服务。真机共存验收结果见下方，不能把旧的 XCTest 附件探针结果当成本实现的验收。

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
- 会话使用独立 `.xctestrun` 副本，将本次测试自动诊断捕获设为截图。原始签名产物及调用者的清单不改动。

启动返回成功不代表整段录制成功。务必检查该 recording ID 的最终 `error`、`stopReason`、`writtenFrames`、`fileValidated` 和文件内容；资源受限时可能提前出现 `recording_backpressure`，即使浏览器画面仍正常刷新。

## 共享媒体实现的验证

宿主完整测试 296 项、1 项既有跳过、0 失败；CLI 测试 22 项通过。Release CLI 已构建。

2026-09-26 真机进度：首次连接在 iOS 的“为 XCTest 输入密码以启用 UI 自动化”页面超时，媒体尚未创建。用户完成系统授权后，Runner 成功连接、打开普通 Probe，并通过点击进入 Rotation workflow；截图已目视确认。会话清单也确认使用 `PreferredScreenCaptureFormat=screenshots`。

首个生产 `record-start` 被 `native_media_busy` 拒绝，尚未创建媒体流或录制文件；同时观察到本机 Device Hub 进程，但仅凭进程不能证明冲突流的所有者。自有媒体、隧道及 Runner 均已确认清理，没有关闭其他客户端。用户结束 Device Hub 的测试设备连接后，显式重连成功，以下生产命令共存验收通过。

环境：macOS 27.0 (26A428)、Xcode 27.0 (27A266a)、iPhone 12 Pro / iOS 27.0 (24A437)。设备来自 Apple 发现结果。三个录制均在同一 Runner 会话内依次开始、手动停止，每次开始后重新观察再点击；没有重启 Runner，没有创建原生 HID 控制连接。

| 录制方向 | 实际 MP4 时长 | 完整解码帧数 | 播放尺寸 | 截图和视频确认的结果 |
|---|---:|---:|---|---|
| 竖屏 `rot0` | 35.422 秒 | 1458 | 1184×2576 | A 从 0 变为 1 |
| 左横屏 `rot90` | 50.918 秒 | 1342 | 2576×1184 | C 从 0 变为 1 |
| 右横屏 `rot270` | 42.742 秒 | 1175 | 2576×1184 | D 从 0 变为 1 |

三个 MP4 都在 Runner 存续期间完成写入和完整解码，精确时间抽帧已目视确认 Probe、计数变化及正向播放。每次停止都确认本次媒体 UUID 的停止、接收器关闭和隧道释放。竖屏停止后，原 Runner 继续点击 B，计数从 0 变为 1；最终 status 的 Runner 会话标识及 PID 与连接时一致。结束时恢复 Probe 竖屏，disconnect 确认 Runner、媒体及隧道清理，无强制终止。

这是固定方向下的点击共存验收，不是全部手势、连续旋转、长时间录制或断连/取消注入的真机验收。媒体时间戳时长不等于宿主录制耗时（本次分别约 39.724、50.916、45.716 秒），静态末段没有补帧延长到停止时间；不承诺固定帧率或逐帧覆盖全部墙钟时间。三段各有 1 个启动阶段丢弃的 access unit，均无后续 discontinuity 或 malformed packet。

后续共享写入器已支持正常结束时保留静态末帧的显示时长，见[原生录屏时间轴修复](native-recording-timeline.md)。上述 Runner 数据属于修复前验收。随后[干净候选包双模式验收](dual-mode-package-acceptance.md)补充了修复后的 Runner 真机证据：同一 Runner 会话内点击 A 从 10 变为 11，宿主录制 73.309 秒、视频 73.300 秒，末帧保持 4.964 秒；视频第 1、55、72 秒抽帧确认点击及静态尾段。该补充为固定竖屏验收，没有重新覆盖左右横屏。

原始证据保存在 `.local/research/runner-shared-recording-20260926/`：`coexist-*-start/stop.json`、动作及观察、前后视频抽帧、三个 MP4、最终 status 和 disconnect，以及保留的首次占用拒绝。生产实现无需因本次验收修改；本轮仅更新验收文档，不重复运行已经通过的宿主测试。

## 旧路线：XCTest 附件录屏探针

以下保留 2026-09-26 早先的独立 XCTest 附件通道研究记录。该探针当时没有接入生产 Runner；它不再是当前录屏的实现路线。

## 已获得的真机证据

环境为 macOS 27.0 (26A428)、Xcode 27.0 (27A266a)、iPhone 12 Pro / iOS 27.0 (24A437)。设备由 Apple CLI 动态选择。先通过现有 Runner 观察并查看普通 iPhone-use Probe 截图，再关闭自身控制会话，运行独立测试；没有进入聊天、修改设置或访问剪贴板。

1. 安装的 XCTest 运行时有独立的 `_XCT_startScreenRecordingWithRequest:withReply:` 与 `_XCT_stopScreenRecordingWithUUID:withReply:`。请求返回本次附件的 UUID 与元数据。使用 Apple H.264 编码，三秒后仅停止该 UUID。
2. 默认 `.xctestrun` 的 `PreferredScreenCaptureFormat=screenRecording` 会让 XCTest 自动诊断录屏先占用通道。自有开始请求返回 `Already recording, there can only be one screen recording at a time`。这次没有成功录制，尽管最早的探索性测试进程返回了 0。
3. 仅将独立测试清单的捕获方式改为 `screenshots` 后，自有开始及停止成功。没有关闭其他客户端的录制，也没有停止全部媒体会话。
4. 文件在 XCTest 守护进程的 `InternalDaemon/.../tmp/Attachments/<本次 UUID>` 下。Runner 对本次文件的直接读取返回 `NSCocoaErrorDomain 257`，底层为 `EPERM`。没有尝试其他容器、路径穿越或放宽沙盒权限。
5. 将自有视频登记为 `XCTAttachmentFuture`，设置 `keepAlways`，通过 XCTest 附件通道传回。登记必须在主线程；探索时后台回调登记引发断言，该失败已保存，后续探针修正了线程调度。
6. 停止录制后继续保持测试运行 45 秒。在此期间，`xcresulttool export attachments` 返回 64：结果包尚无 `Info.plist`，不能创建读取器。对应的会话文件清单和 Apple 日志已保存；没有伪造结果包元数据或解析临时数据库来宣称导出成功。
7. 测试结束后，同一结果包可导出 MP4。首个导出文件为 110,047 字节、约 3.977 秒、1170×2532；复用生产 `NativeRecordingValidation` 完整解码得到 4 个样本，时间戳有效。抽帧已目视确认是 Probe。静态画面下该样本数不构成 30 fps 或连续动画录制能力的证明。

以上证明“可录制、可按所有权停止、可在测试结束后导出”，**不证明会话存续期间可即时导出**，也不证明所有合法 XCTest 导出方式都不可行。当前直接读文件及 `xcresulttool` 两条路径不足以满足现有命令契约。

## 可复现代码

代码位于 `scripts/runner-recording-probe/`，只在新的本地工作目录复制、扩展 Runner，不修改生产 target 或公共接口。需要已有 Apple 签名团队、已配对解锁设备及已安装的普通 Probe；结束自己已有的控制会话，并目视确认 Probe 后运行。不要对未知屏幕直接开始录制。

```sh
python3 scripts/runner-recording-probe/prepare.py .local/recording-probe/workspace
iphone-use build-runner --source-root .local/recording-probe/workspace --team "$TEAM"

# DEVICE 来自 iphone-use devices；XCTESTRUN 使用上一命令返回的实际路径。
python3 scripts/runner-recording-probe/run.py \
  --device "$DEVICE" --xctestrun "$XCTESTRUN" \
  --output .local/recording-probe/run
```

工作目录和证据目录必须尚不存在，脚本不覆盖先前结果。测试还要求显式 opt-in 环境变量，由脚本传入；仅在 Probe 已处于前台时发送一次开始请求。没有自动重放；三秒定时停止绑定开始回复返回的 UUID。未知结果不会触发新录制。

脚本保存锁屏状态、xcodebuild 日志、事件流、运行中导出失败、会话结束后附件清单、完整解码结果及 `frame.png`。开始/停止失败会让最终测试失败，不能仅凭 xcodebuild 的退出状态判定录屏成功。`report.json` 明确标记 `productionRecordingImplemented=false`。

这是限定工具链的研究探针，不是生产状态机：未完成通用运行时签名兼容校验、取消/断连/晚回复生命周期、重复 stop、横屏与手势共存等生产验收。不要把探针桥接器直接接入产品并广告支持。

Apple 工具可能需要宿主的系统服务访问权限：本次 `xcresulttool` 在受限宿主环境中不能写其 TestReport 临时目录，AVFoundation 解码也曾失败；允许宿主工具正常使用系统服务后，导出和解码成功。这与 iOS 内部容器的 `EPERM` 是两个问题，后者仍然存在，不是用户尚未批准工具命令。

原始证据：`.local/research/runner-recording-20260925/`，包括首轮失败与修复后验证，不作为产品依赖。没有引入第三方设备工具。

## 验证范围

- 宿主：`swift test --filter NativeRecordingTests`，6 项通过、0 失败；Python 脚本语法检查通过。
- 构建：整理后的独立 Probe 已签名构建成功，共享的五个 Swift 文件与生产源码逐一核对一致。
- 真机：前述探索性探针完成启动、停止、测试结束后导出及完整视频解码；抽帧已查看。
- 整理后的脚本第一次复跑在锁屏预检处明确拒绝，没有启动测试或录屏。因此不能将前面的探索验证等同于最终脚本的端到端复跑通过。
- 此历史附件探针阶段未运行生产录屏命令、横屏、手势共存、取消/断连注入；当前共享媒体生产实现的验收见上方，不能归因于此附件探针。

## 后续实现边界

若未来继续此附件路线，需要找到可在现有 XCTest 会话内取回**本次录制文件**的合法传输通道。当前共享原生媒体路线已绕开这项附件导出依赖。不得把结束/重建 Runner 会话藏在 `record-stop` 中，也不能将停止确认当成 `fileValidated=true`。

Runner 截图采样后编码 MP4 是另一种可研究的实现，但帧率、控制延迟和连续动画保真度有明显不同；历史附件探针没有将它当成原录屏通道的等价替代，也没有建立原生媒体会话。当前产品使用上方明确声明的共享原生媒体通道，完整生产故障场景仍未验证。

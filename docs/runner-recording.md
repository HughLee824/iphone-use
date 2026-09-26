# Runner 原生媒体录屏

本次实现将控制模式与录屏传输分开：Runner 的截图、元素、点击和输入仍由 XCTest 执行；显式 `record-start` 创建自有 CoreDevice displayservice 媒体连接，使用与标准模式相同的 HEVC/RTP 接收、MP4 写入和完整解码验证。不会建立 HID 或剪贴板服务。真机共存验收结果见下方，不能把旧的 XCTest 附件探针结果当成本实现的验收。

```sh
iphone-use connect --mode runner --device "$DEVICE" --xctestrun "$XCTESTRUN"
iphone-use --session "$SESSION" record-start --duration 60
# 重新 observe，再按新截图/元素引用执行 Runner 动作。
iphone-use --session "$SESSION" record-stop "$RECORDING_ID"
```

- 复用同一组命令、1–300 秒时长、录制 ID 和 `recordings/<UUID>/screen.mp4` 文件契约。
- 连接 Runner 时不创建原生媒体会话；`recordingSupport.availability=not_checked` 不是可录制的证明。显式开始时再检查 macOS/iOS 27、配对、解锁、方向、媒体互斥、协议及 RTP 时钟。
- 每个新录制创建独立媒体流，停止只作用于其自有 UUID。旧 ID 重复停止不会影响后续录制；未知 ID 被拒绝。开始或清理失败后不重放，要求显式重连。
- `record-stop` 在同一 Runner 会话内完成文件写入、完整解码和媒体清理；不等待 XCTest 结束，也不重建 Runner。清理未确认时保留文件事实并返回 unknown。
- 时长到达由现有录制队列自动结束文件；随后的 status、观察、动作或 disconnect 回收媒体。会话 idle/signal 清理也先结束文件，再关闭媒体和 Runner。
- status、观察和动作边界检查显示状态。发现方向/锁屏变化时结束本段；不承诺连续旋转录制。每个视频帧都不是 observation，录制开始/停止会使旧 observation 失效。
- 会话使用独立 `.xctestrun` 副本，将本次测试自动诊断捕获设为截图。原始签名产物及调用者的清单不改动。

## 共享媒体实现的验证

宿主完整测试 296 项、1 项既有跳过、0 失败；CLI 测试 22 项通过。Release CLI 已构建。首次真机连接在 iOS 的“为 XCTest 输入密码以启用 UI 自动化”页面超时，媒体尚未创建。当前等待系统授权后的实际共存验收。

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
- 未运行：生产录屏命令、横屏、手势共存、取消/断连注入；生产命令尚未实现，不存在这些检查的通过结论。

## 后续实现边界

若未来继续此附件路线，需要找到可在现有 XCTest 会话内取回**本次录制文件**的合法传输通道。当前共享原生媒体路线已绕开这项附件导出依赖。不得把结束/重建 Runner 会话藏在 `record-stop` 中，也不能将停止确认当成 `fileValidated=true`。

Runner 截图采样后编码 MP4 是另一种可研究的实现，但帧率、控制延迟和连续动画保真度有明显不同；本次没有将它当成原录屏通道的等价替代，也没有偷偷建立原生媒体会话。横屏、控制共存和完整生产故障场景仍未验证。

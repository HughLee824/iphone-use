# Runner 录屏：可执行验证与当前阻塞

2026-09-26。**尚未完成 Runner `record-start` / `record-stop` 功能对齐。** 当前交付是可构建、签名和运行的独立 Probe，验证真实录制、UUID 停止、附件导出及视频完整解码。生产 Runner、SessionHost 和模式能力表没有改动，Runner 仍明确拒绝录屏，不切换到标准模式。

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

继续实现前，需要找到可在现有 XCTest 会话内取回**本次录制文件**的合法传输通道，再接入已有录制 ID、时长、状态及验证契约。不得把结束/重建 Runner 会话藏在 `record-stop` 中，也不能将停止确认当成 `fileValidated=true`。

Runner 截图采样后编码 MP4 是另一种可研究的实现，但帧率、控制延迟和连续动画保真度有明显不同；本次没有将它当成原录屏通道的等价替代，也没有偷偷建立原生媒体会话。横屏、控制共存和完整生产故障场景仍未验证。

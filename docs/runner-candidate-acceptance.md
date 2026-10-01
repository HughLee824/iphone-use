# 媒体优先候选包 Runner 验收

2026-10-01。**同一搬移候选包的 Runner 中文多行 replace / append / insert、点击、长按菜单、拖放、双击、双向捏合及共享原生录屏验收通过。** 与[标准模式真实 App 验收](media-candidate-acceptance.md)合并，当前候选已有两种模式的真机证据；两轮场景不同，不代表所有功能或所有 App 完全等价。

## 候选与连接

- 版本：`0.1.0-dev.media.20261001.1`，macOS arm64。
- 产品源提交：`6a652660fd160212ede88ac7f58018d067986db8`，`sourceDirty=false`。
- 归档 SHA-256：`14604ccdf95af276c5f14ac30d1e20ab7bac384b648c5a556ba4e1bb9b0e3bee`。
- Runner 摘要：`c50a7d9dc8930320716ec1c02261813713f3b230bec8cef68c71d2677cb571e6`。

沿用上一轮解压到源码外含空格目录的包内 CLI、工作目录及隔离配置，没有重新构建或调用源码 `.build`。候选 CLI 为 ad-hoc 签名、未公证。`setup` 从包内载荷准备合法开发签名，返回 `compiled:false`、`reused:false`，验证连接、观察采集和断开。显式 `connect --mode runner` 使用 `native-coredevice` 传输连接 XCTest；不是标准模式隐式回退。

设备来自 Apple 动态发现的有线 iPhone 12 Pro / iOS 27.0，确认解锁后才操作。全部动作在普通 `com.iphone-use.native-text-probe` 内完成；本轮没有进入备忘录、访问剪贴板、修改设置或发送消息。Runner 观察使用 XCTest 截图及可用元素，1170×2532 pixels、390×844 points；不将这些截图标记为 `native_media`。

## 文本与手势事实

输入通过 `--stdin` 传递受控 UTF-8 文件，在操作后的截图及 `text_view` 值上核对。下表的 `\n` 表示 LF，`\u0301` 表示独立组合重音，不进行 Unicode 归一化。

| 操作 | 输入及实际结果 |
| --- | --- |
| replace | ` 首🙂行\n\n尾e\u0301 \n` 原样写入；21 UTF-8 bytes、11 scalars，保留首尾空格、空行、emoji、组合字符和末尾换行；Probe 显示 EXACT UTF-8 MATCH |
| append | 追加 `\n追加中文🌱\n第二行`；实际值与原值加追加文件逐字节相等，48 bytes、21 scalars，原多行内容保留 |
| insert | Probe 将 `头🙂尾` 的 emoji 选中，UTF-16 范围 `(1,2)`；插入 `插入\n中文` 后实际为 `头插入\n中文尾`，19 bytes、7 scalars |
| 长按与菜单选择 | 长按打开实际上下文菜单，选择后 `Menu choices: 1` |
| 拖放 | 按住源 token 并拖到目标；实际显示 `Received: SOMA`，drag starts / ends / drops 均为 1 |
| 向外、向内捏合 | Zoom 从 1.000 到 2.030，再到 0.955；began / ended 均累计为 2，peak touches 为 2，active 与 cancelled 为 0 |
| 录屏中的双击 | `Double 0 / Single 0` 变为 `Double 1 / Single 0` |
| 停止录屏后的单击 | 同一 Runner 继续执行，变为 `Double 1 / Single 1` |

append / insert 使用额外的自定义多行文本，Probe 的固定样例期望值没有随之改变，因此页内固定样例比较显示 NOT MATCHED。实际结果按本轮输入计算期望值，并与 AX 字符串逐字节比对及截图核对；不把不同测试夹具的比较标签误判为输入失败。

共保留 23 个观察。两次请求因 `screen_changed` 明确 `not_dispatched`：一次在初始页面变化后，另一次伴随无关系统通知出现。没有点击通知；核对新截图、等待通知消失后，基于新观察重新选择动作。其余实际发送的操作均完成，没有 unknown 输入自动重放，也没有放宽保护阈值。

## Runner 与原生媒体录屏共存

显式开始录屏后重新观察，再执行双击，按本次录制 ID 手动停止。MP4 为 HEVC、1184×2576、753,324 bytes，时长 **22.183 秒**；宿主录制耗时 22.191 秒。写入与完整解码均为 **689 帧**。动态尺寸省略、畸形包、时间线不连续均为 0；有 1 个记录在案的启动阶段丢弃单元。编码路径为 `apple_vra_decode_then_hevc_encode`。

自写 Apple AVFoundation 抽帧器提取普通 MP4。实际第 0 秒画面显示 `Double 0 / Single 0`，第 22.133 秒显示 `Double 1 / Single 0`，已目视确认正向 Probe 画面和计数变化。中间抽帧请求 11.092 秒，返回样本时间为 6.820 秒，报告保留实际时间，不声称精确抽到了请求时刻。视频保留右侧/底部编码填充，不能直接使用视频像素发送坐标动作。

录制前后 Runner PID、Runner 会话标识和 xcodebuild PID 相同。停止只清理自有媒体 UUID，确认媒体停止、接收器关闭和隧道释放；`mediaConnectionOpen=false`。`hidServiceOpened=false`，录屏没有建立原生 HID 执行链路。停止后截图及单击成功，证明同一 Runner 仍可继续控制。

## 清理与范围

disconnect 返回 Runner shutdown 确认、xcodebuild 退出码 0、`forced:false`。独立检查会话宿主、xcodebuild 和 setup 验证宿主已退出，socket 与观察缓存已删除；没有额外独立查询设备端 Runner 进程退出状态。没有调用 `stopAll` 或关闭其他客户端。

包内文件逐一对比摘要未变化。隔离配置仍为 `standard` / `configuration` / `saved:true`，本次显式 Runner 选择没有改写默认模式。

本轮未改产品源码、未重跑宿主测试；上一轮该候选的打包测试 18 项通过，产品源提交完整宿主测试 338 项、337 通过、1 项既有跳过，详见[候选包报告](media-candidate-acceptance.md)及[填充修复报告](native-media-padding-repair.md)。本轮仅补充候选包真机验证和文档，不发布或推送。

覆盖范围为当前设备、固定竖屏、普通 Probe 的上述操作。未新增横屏、其他 App、CR/CRLF、密码字段、全新 Mac 配对或公开分发验证。Runner 与标准模式仍有元素引用、文本读取和输入通道等契约差异，不能据此宣称完全互换。

私有证据位于 `.local/research/runner-candidate-20261001/`：输入文件、23 份截图/元素快照、动作结果、前后 status、`recording-stop.mp4`、抽帧及实际时间、退出事实、配置和包摘要、`summary.json` 与 `hashes.json`。原图和设备标识不提交仓库。

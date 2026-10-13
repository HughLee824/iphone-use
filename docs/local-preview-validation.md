# 本地预览验收记录

截至 2026-10-13。实现与使用方式见[本地浏览器预览](local-preview-prototype.md)。本页保留与当前实现有关的验收结论、失败及复现方式；逐轮过程日志、设备标识、会话 URL、截图、MP4 和原始采样不提交，保存在被忽略的 `.local/`。

## 环境与范围

- 真机：USB 连接的 iPhone 12 Pro，iOS 27.0.1；主机：Apple Silicon Mac、16 GiB RAM、Xcode 27。
- standard 与 runner 使用同一离线 Probe，检查计数输入、旋转、60 Hz 动效、UIKit 转场及本地 30 fps H.264 视频。
- 浏览器帧率通过 JPEG 序号去重，在 `image.onload` 后的 requestAnimationFrame 回调采样。这是浏览器绘制机会，不是物理呈现时间或手机到电脑的端到端延迟。
- 其他机型只有素材、参数与浏览器几何验证，不能作为逐台真机验收。

## 共享视频流与录屏

两种模式均验证过预览、控制及录屏共存：先预览再录屏、先录屏再预览、先停录屏及先停预览。控制计数变化在观察截图、浏览器和录屏抽帧中交叉确认。停止一个使用者不会主动关闭另一个仍在使用的媒体连接。

录屏改为订阅已解码帧后，开始录屏不再强制重建预览流，也不需要等待新关键帧。早期 runner 启动录屏时曾出现约 2.7 秒停顿；共享解码方案消除了该强制刷新路径，但不能据此保证任何负载下无停顿。录屏仍逐帧完整解码校验，旋转结束当前片段，之后需显式开始新录屏。

保留的媒体实现候选各完成八分钟动态窗口，包含 300 秒和 60 秒录屏及完整文件校验：

| 指标 | standard | runner |
| --- | ---: | ---: |
| 浏览器观察时长 | 约 500 秒 | 约 503 秒 |
| 平均新帧率 | 29.88 fps | 29.27 fps |
| 最大新帧间隔 | 167 ms | 701 ms |
| 大于 250 ms 次数 | 0 | 12 |
| 长 / 短录屏校验帧数 | 17,675 / 3,541 | 17,941 / 3,588 |
| 两次启动窗口最大间隔 | 50 / 68 ms | 42 / 71 ms |

standard 的两个文件校验窗口最大间隔为 134 / 117 ms。runner 短文件校验窗口达到 350 ms，长文件校验原始浏览器样本存在缺口，不能给出完整上界。两种模式的有效录屏均通过完整解码检查。

**稳定 30 fps 验收未通过。** runner 平均接近目标帧率，但偶发卡顿仍存在。后续未保留的 CPU 旋转探测实验没有证明收益，还出现方向问题，已撤回；当前保留接收/解码 QoS、分段计时、两槽有界 JPEG 转换及过期结果丢弃。

独立低负载计时进程也曾出现约 299 ms 调度停顿，主机报告内存压力级别 2，支持主机资源压力参与长尾，但不能证明它是唯一原因。按项目决定停止进一步性能定位，不将不同负载窗口作为严格 A/B，也不删除失败结论。后续外框和页面更新没有重做这一性能窗口。

## 方向、连接与输入限制

- standard / runner 均观察到竖屏及左右横屏最终显示正确。旋转会重新绑定媒体，存在短暂停顿和方向滞后。
- 一次 standard 左横屏切右横屏后未自动恢复，显式停止再启动预览才恢复正确方向；后续开孔补验还多次遇到 `CoreDevice process was cancelled or exceeded the host deadline`，因此 standard 的完整连续运行补验未通过。
- runner 在完成设备上的 XCTest 授权后，同一预览连接完成左横屏 → 竖屏 → 右横屏 → 竖屏，无手工重启，最终健康状态为 streaming。期间两次输入已执行但画面稳定检查超时；独立观察确认结果，没有重放输入。此短时通过不撤销此前 standard 失败或 runner 卡顿结论。
- standard 的 `native_input_unacknowledged` 表示无法确认输入，runner 的 `frame_stability_timeout` 也不能自动重放。预览不替代有效 observation 或输入新鲜度检查。
- 锁屏和 XCTest 自动化授权多次阻止连接；不能把解锁等同于授权完成。没有验证数小时运行、跨设备、拔插恢复、在线缓冲、受保护视频或音频。

## 外框与页面

- 23 款官方素材按精确 productType 选择，原始 PNG 与许可随包保留；受新协议限制的素材未加入分发包。32 个精确标识、31 款机型的独立绘制参数见[校准清单](preview-hardware-calibration.md)。未知机型使用通用外框。
- 全部已登记标识完成浏览器竖屏几何检查，12 Pro、13 mini、18 Pro Max 覆盖不同开孔类型的左右横屏；自动化检查全部官方机型在三个窗口尺寸及三个方向的画面尺寸、中心一致性。
- 真机 12 Pro 官方/自绘切换尺寸一致，中心差约 0.008 CSS px，属于浏览器子像素舍入。镜头高光、材质及侧键仍为视觉近似。
- JPEG 右侧灰缝已定位为缩放小数 extent 的边缘透明采样，修复为先裁掉解码填充、延展有效边缘再缩放至整数尺寸；逐边缘像素回归覆盖黑色/绿色内容及三个方向。
- Chrome 完成明暗主题、官方/自绘及三个方向的布局检查。系统设置恢复测试前状态。Codex 内置浏览器曾在 macOS 深色模式下报告浅色，页面遵循宿主报告，不能承诺所有宿主行为一致。
- 机型信息移入顶部栏，移除中间及底部说明，保留临时外观对比按钮；新版 standard 真机预览已确认画面扩大。favicon 使用项目官网同款品牌 PNG，本地提供；接口测试校验字节一致性及随机路径隔离。

### 悬浮玻璃控件改版（2026-10-13）

移除通栏，左上角仅保留机型与变色手机图标；两种模式继续共用同一页面。浏览器 fixture 检查覆盖 1280×720、390×844、740×360 及 320×568，包含竖屏、左右横屏、官方/自绘切换、全屏进出和中英文提示。宽窄布局均无控件遮挡或水平溢出，切换外观的画面中心差约 0.008 CSS px。深色、减少透明及高对比度通过仅存在于本地 fixture 的样式条件检查，不作为操作系统偏好切换的复测。未重做 standard / runner 真机性能或长时间测试；此前性能与旋转限制仍适用。

## 可复现检查

```sh
swift test
python3 -m unittest discover -s scripts/tests -v
node --test scripts/tests/test_agent_templates.mjs scripts/tests/test_preview_metrics.mjs
swift build -c release
```

动态夹具 `scripts/preview-motion-probe.swift` 编入已有 NativeTextProbe，普通启动仍显示原页面。构建安装 Probe 后：

```sh
xcrun devicectl device process launch --device "$UDID" --terminate-existing \
  com.iphone-use.native-text-probe --preview-motion-probe
```

分别连接 standard / runner，启动预览并给 URL 添加 `?diagnostics=1`，保持浏览器前台可见。使用 `scripts/preview-soak.py` 采样宿主状态及资源；参数见使用文档。单独保留录屏开始、结束、文件校验及旋转的时间，不能只比较平均帧率或稳定窗口。`#metrics` 的 `data-samples` 是有界的最近样本，累计统计与完整采样应一并检查。

已有长视频可选回归：

```sh
IPHONE_USE_LONG_RECORDING_FIXTURE=/path/to/recordings/ID/screen.mp4 \
  swift test --filter NativeRecordingTests.testLongDeviceRecordingDecodesEveryWrittenFrame
```

同目录需有对应 `result.json`；未提供本地录屏时该项跳过，不能当作长录屏真机回归通过。验收产生的设备图像与录屏不得随 PR 提交。

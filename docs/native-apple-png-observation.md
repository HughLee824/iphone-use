# 标准模式统一使用 Apple PNG

标准模式的观察、文字准备、动作前校验、动作后观察及 text-finish 后续观察统一使用 Apple CoreDevice PNG。Runner 的截图来源和执行路线不变，不新增选源配置。

## 截图与校验

`AppleDeviceCLI.capture` 只读取本次 Apple 截图命令的输出；方向校验回调只返回几何事实。Apple 截图失败、无效、全黑或尺寸不匹配时报告失败，不使用视频帧、缓存图片或 Runner 补齐。

- `captureSource: coredevice_screenshot`。
- `captureSourcePolicy.strategy: coredevice_only`。
- `displayGeometry` 保存方向校验事实，`captureTimingsMs` 和 `captureCommands` 保存采集阶段耗时。
- 文字输入前每个校验阶段只取一张新 PNG，并比较原 observationID 绑定的截图。显式光标排除见[光标契约](native-text-phase-matching.md)。
- 动作后使用[有界判稳](native-post-action-stability.md)，返回最后一张有效原图；独立 observe 保留单次采集语义。

媒体手势专用容差、媒体文字启动基线选择和视频帧导出观察 PNG 的实现已移除。PNG 不会消除真实的光标闪烁、视频或动画变化；动态区域仍须由调用方从当前截图明确指定。

## 媒体按需启停

标准观察和 HID 输入不需要常驻媒体流。普通截图使用当前 Apple 显示元数据，触控与键盘独立检查 HID 状态；派发前读取媒体所有权，发现其他客户端会话时拒绝输入，不关闭它们。

自有媒体仅在显式录屏时启动。录屏期间保留媒体几何校验，发现方向证据失效时结束当前片段并确认自有流停止，再读取显示信息、重取 Apple PNG；不自动开始新录屏。录屏完成后的清理在宿主设备队列中执行，只处理匹配的 recording ID 和媒体 UUID。停止未确认时报告清理失败，不假定流已释放。

## 保留的保护

设备和会话身份、observationID、来源一致性、方向/尺寸、坐标映射、锁屏/背光、全局与局部保护、显式动画排除、输入预算、取消释放和未知结果不重放规则仍然生效。真实变化或期限超限返回拒绝及可用的新观察，不在执行动作时替换基准。历史媒体观察不能通过跨来源校验，应使用当前程序建立自有新会话。

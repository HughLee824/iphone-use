# AgentSoma：基于 Apple 工具链的 iOS 27 真机观察与控制方案

**状态：修订工程方案；普通第三方 App 采用截图观察 + HID 执行，AX 不进入首版必需链路。纯原生 HID 工程实现仍待交付。**

**修订日期：2026-09-19；原版日期：2026-09-17。**

**证据范围：截至本次修订的本地工具链、原始协议记录、真机截图、受控 App 对照及人工确认。区分历史第三方实验、自写 Apple 原生客户端实验和 macOS 27 升级后复测；本次修订没有新增真机测试或联网调研。**

> 本文件是后续原生后端的设计方案，不代表当前产品已切换后端。当前实现见 [现有架构](../architecture.md)，新任务从 [实现交接](apple-native-device-control-implementation.md) 开始。设备标识为占位符，命令示例中的 `DEVICE_ID` 应使用实际发现的设备。第 11 节的 `.local/research` 链接指向未入 Git 的本机证据，新 checkout 可能没有这些文件；不得因此在产品构建或测试中依赖它们。

## 1. 执行结论

目标保持为 **自研 macOS 控制端 + Apple CLI 观察层 + Apple 设备侧媒体/HID 服务适配层**，面向已配对的 iOS 27 真机和普通第三方 App。首版采用：

> 获取当前截图 → Agent 识别目标 → 根据该截图映射坐标 → HID 执行 → 获取新截图 → 确认预期结果。

本次修订确定以下边界：

- 截图 + HID 是首版主路径；不默认启动 XCTest Runner，也不以 Runner 能力作为原生后端的隐式依赖。
- AX 只保留为可选研究能力。当前没有满足“不移动页面、只获取当前屏幕完整 AX 信息”的通用采集入口，普通 App 的已测 Activate 也没有可靠成功证据。
- Apple Vision OCR 是后续可评估的本地文字辅助，不是 AX。只有测量证明能改善成功率、延迟或 token 成本，才接入默认观察流程。
- Apple `devicectl` 截图已反复实测；直接 HID 点击、滑动和简单英文输入有历史实验成功证据，但该 HID 实验使用第三方协议实现。**不用 Runner，不等于没有第三方运行依赖。**
- 后续自写 Objective-C 客户端已完成 Apple 原生 AX 连接、读取及受控 Probe 操作，但不能据此宣布纯原生 HID 客户端已经完成。独立传输、媒体会话和 HID 的工程交付仍是主要门槛。
- 本方案不承诺覆盖所有 App 或跨版本稳定。现有 Runner 后端的保留、迁移或删除属于独立集成决策；新原生后端不静默回退到它。

### 三个概念必须分开

| 概念 | 本方案含义 |
|---|---|
| 不依赖第三方开源项目 | 产品源码、构建和运行不引入第三方设备客户端、协议库或二进制；后续研究同样遵守用户约束，第三方项目仅参考原理 |
| 使用 Apple 自带能力 | 使用 Apple CLI、系统/Xcode 框架、配对开发连接和设备侧服务，加上自写客户端 |
| 仅使用 Apple 公开接口 | 所有调用均有公开、受支持接口；当前完整真机输入路线尚不满足此条件 |

前两项是实现约束；第三项不能标记为已经满足。历史第三方实验仅作为机制证据，不是后续继续执行这些工具或随产品分发其源码的授权。

## 2. 环境与证据适用范围

| 项目 | 已确认信息 |
|---|---|
| 设备 | iPhone 12 Pro，physical |
| iOS | 27.0，build 24A437 |
| Xcode | 27.0，build 27A266a，`/Applications/Xcode.app` |
| 当前 macOS | 27.0，build 26A428 |
| 升级前 macOS | 26.6.2，build 25G83；不是所有更早实验都独立记录了宿主 build |
| 连接基线 | 已配对真机；历史直接输入在 wired 环境验证；其他传输条件需单独验收 |
| Developer Mode | 当前及历史验证为 Enabled；关闭状态未验证。首版把开启作为支持前提，不声称已经证明所有 HID 路径必须依赖它 |
| UDID | `<device-udid>`，仅为实验设备标识 |
| CoreDevice Identifier | `<coredevice-identifier>`，不作为跨主机/重新配对稳定标识硬编码 |
| 截图 | 当前竖屏 PNG 为 1170 × 2532 pixels；尺寸与方向每次读取，不固定除以缩放倍数 |
| 历史 CoreDevice framework | 原方案记录 current version 642.16.0；不据此推断升级后所有组件相同 |

**按环境区分验收记录：**

- 历史直接 HID 点击、滑动、英文输入、Device Hub 退出后的冷启动成功，不自动等同于 macOS 27 上已经复测通过。
- Probe 签名 A/B/A、原生/Web 控件和 Lark 主要实验采集于 Mac 升级前。
- 升级后已复测 Inspector 连接、remoteAXService 访问、微信 AX/Activate、四个 Tab 和严格不移动焦点的读取。
- macOS 27 + Xcode 27 + iOS 27 是接下来的完整工程验收环境，不是已完成全部 HID 能力验收的兼容性声明。

## 3. 能力与证据状态矩阵

| 能力/路径 | 当前状态 | 限制与证据归属 |
|---|---|---|
| `devicectl` 设备发现、截图 | 已实测，包括 macOS 27 | 截图成功不证明输入能力或前台 App 正确 |
| 启动已有 App | 可用；已打开微信/Lark | launch 成功回包不总等于前台已经切换；必须核对实际页面 |
| `devicectl` MP4 录屏 | CLI 帮助已确认 | 尚未归档成功录制验收；不等于实时帧接口 |
| 官方 MCP 真机 Device Interaction | 当前 Xcode build 的已查入口受限 | 已定位默认设备池的模拟器筛选与内部条件；不作为首版真机后端，不尝试绕过 |
| 直接 HID 点击、滑动 | 历史端到端成功 | 使用过第三方实验客户端；含 Device Hub 退出后的输入与冷启动证据；纯原生实现和当前宿主完整复测待做 |
| 简单英文 HID 输入 | 历史输入 `Lark` 成功 | 第三方实验；组合键清空失败；中文、输入法和通用文字写入未验证 |
| 纯原生 HID 客户端 | 尚未完成工程交付 | 不能用 AX 客户端成功或符号存在替代 |
| 自写原生 Inspector 连接 | 已实测，macOS 27 仍成功 | 私有框架/DTX 路径，不是公开稳定的自动化 API |
| 开发 Probe 的原生 AX | 较丰富层级、按钮/开关/焦点及一次下滚成功 | 有 `get-task-allow`；不代表所有控件或所有 AX 信息完整 |
| Probe 的 Web AX | 可读部分控件和状态 | 按钮、复选框 Activate 无预期效果；链接/输入实验另有证据边界；Value 写入未暴露 |
| Probe 签名 A/B/A | 相同代码 true→absent→true | 移除 `get-task-allow` 后层级缩减且按钮无效，恢复后成功；不是完整 App Store 签名对照 |
| Lark AX | 框架、工具按钮等可读，聊天正文缺失 | 可见消息定点对照仍无正文；已测展开按钮 Activate 无效果，输入占位节点不是已确认的编辑框 |
| 微信首页 AX | 会话名、摘要、时间、未读/静音等可读 | 部分 Label 截断；有界遍历会自动滚动，不能称为静态整屏树 |
| 微信 AX Activate | Shortcut 与四个 Tab 已测试 | Contacts/Discover/Me 均未切换；Chats 原已选中，结果不能证明成功；回复均正常 |
| 不滚动的当前屏幕 AX | 未通过完整树验收 | 无焦点/导航读取只得 Search、Me 局部节点；frame/父子接口空，6 次 hit-test 空；10 张截图内容区一致 |
| CoreDevice remoteAXService | 自写客户端仍被拒绝 | macOS 27 有明确权限拒绝日志；Device Hub/Inspector 尚未取得可用手机子树；不同于已连通的旧 Inspector 通道 |
| 长按、拖拽、多指、硬件键 | 未完成独立原生验收 | 不用 capability、符号或简单 tap 成功替代 |
| 独立实时视频帧 | 未完成 | 会话成立不等于解码、时间戳、持续帧率或重连完成 |

以上是已测对象与路径的结论，不能归纳为“自研 App 全部支持、App Store App 全部不支持”。所有动作都分别记录请求回复、实际界面变化与预期目标是否实现。

## 4. Apple 自带命令：保留的直接可用部分

### 4.1 设备发现

```bash
xcrun devicectl list devices
```

产品内部应使用本机帮助支持的 JSON 输出选项，不解析面向人的表格。设备列表字段与 JSON 结构要针对实际安装版本编写适配和验证；本次没有提供完整 JSON schema。

### 4.2 真机截图——已经实测成功

```bash
xcrun devicectl device capture screenshot \
  --device "$DEVICE_ID" \
  --destination /tmp/iphone.png
```

本次成功输出：

```text
Screenshot saved to: /tmp/iphone.png
Dimensions: 1170x2532 pixels
```

该图像不是对 Mac 上投屏窗口的截取。产品应使用独立临时路径，并在返回前确认进程退出状态、文件存在性、图像解码和尺寸，避免误用旧文件。

### 4.3 启动已有 App

```bash
xcrun devicectl device process launch \
  --device "$DEVICE_ID" \
  --activate com.tencent.xin
```

本轮已使用该原生命令打开微信；不加 `--terminate-existing` 强制重启。成功回包不保证页面已经切换，须另行核对；解锁/亮屏和前台状态不满足时明确提示，不循环重启 App。

### 4.4 真机录屏——语法来自本机帮助，尚待实际验收

```bash
xcrun devicectl device capture screen-record \
  --device "$DEVICE_ID" \
  --destination /tmp/iphone.mp4 \
  --codec h264 \
  --duration 10
```

已知帮助说明：目标文件必须为 `.mp4`；codec 可选 `h264` / `hevc`；未指定 duration 时通过 Ctrl+C 停止并保存；未指定 display 时捕获主显示屏。

这是文件录制接口，不能当作已经公开的 raw-frame/stdout/live-stream API。产品包装必须区分正常停止与强制杀进程，并验证输出文件是否完整。

## 5. HID 机制证据与纯原生实现缺口

历史成功路径为：

```text
历史实验客户端（存在第三方运行依赖）
  → 配对设备连接 / RSD / RemoteXPC
  → Apple display/media 服务建立会话
  → Apple universalhidservice 发送触控或键盘报告
  → 真机界面产生已核对的变化
```

原文 go-ios 中心点 tap 的用户确认仍保留为历史证据。后续直接输入实验使用过 pymobiledevice3 协议实现，补充了非中心点点击、连续滑动、英文输入、Device Hub 退出和媒体关闭后的新进程冷启动对照。**这些扩大了机制可行性的证据，但没有交付纯原生 HID 后端。**

自写原生产品必须独立实现服务连接、协议收发、媒体生命周期、报告构造与清理。优先复用已确认可调用的 Apple C/ObjC 接口；确需实现私有协议子集时按独立设计和实验验证推进，不复制第三方设备库进入产品或重新依赖它们运行。

### 5.1 已发现的具体工程问题

1. 历史 RemoteXPC 客户端重复执行需回复请求时，设备出现 reply-channel 断言和守护进程重启。新连接规避后有成功结果，但根因未修复。纯原生实现必须验证消息编号、回复关联和同连接多请求，不能把“每次换连接”直接认定为协议已正确。
2. 关闭连接或 EOF 不等于正常停止；历史 EOF 也伴随过服务异常。
3. 实验使用过 `stopAll=true` 并获得空会话确认。这会停止全部流，不能作为与 Device Hub 等客户端并存时的生产关闭方式。生产必须识别和关闭自己的会话；若做不到，应明确不支持并存，而不是停止他人会话。
4. 媒体保活尚未生产验证。历史仅接收 RTP 的流曾停止，补充 RTCP 后有冷启动成功记录，但长时间运行、丢包、断连恢复未完成。
5. 键盘仅验证简单英文；Cmd+A 后退格两次未达到清空效果，不得标记通用键盘能力可用。

### 5.2 媒体与输入会话

已验证成功路径包含媒体会话。首版保持其生命周期，不因为单次截图或服务列表成功就认定控制已准备好。没有媒体时一定不能输入、必须依赖 Device Hub GUI 等判断均不能从现有证据直接推导。

Device Hub GUI 已被历史隔离实验排除为输入调用的必要环节；纯原生客户端仍须重新记录实际 Apple 组件、权限和服务依赖。不得通过关闭系统保护、伪造 entitlement 或 Apple 进程身份满足设计。

## 6. 推荐架构与模块职责

```text
AgentSoma Runtime
  └── AppleDeviceBackend（自研）
        ├── AppleDeviceCLI：发现 / 详情 / 启动 App / 截图；录屏后续独立验收
        ├── ScreenObservation：截图身份、方向、尺寸、裁剪变换、有效性
        │     └── 可选 LocalTextObservation（Apple Vision，评估后再接入）
        ├── NativeControlSession
        │     ├── AppleServiceTransport
        │     ├── MediaSession
        │     ├── NativeHIDAdapter
        │     └── GestureScheduler
        ├── CoordinateMapper
        ├── ActionVerification：新截图与预期结果核对
        └── ArtifactAndEventRecorder

独立研究模块：AXSemanticProbe（不进入首版默认调用链）
```

### 6.1 实现语言与边界

Swift 为宿主语言，必要时使用少量自写 C/Objective-C 桥接已确认的 ABI。优先 Apple Foundation、Dispatch、ImageIO、CoreGraphics 等能力。构建和运行不引入第三方设备协议库、Go module、Python package 或手机辅助 App。测试 Fixture 仅用于受控实验，不是普通 App 控制的运行前提。

Swift 语言或 Foundation 并不自动提供 RemoteXPC 客户端。动态符号、服务 capability 和反射结果只是入口线索，不是生产可调用性证明。

### 6.2 AppleDeviceCLI 与 ScreenObservation

用参数数组启动工具进程，解析本机支持的 JSON；处理超时、取消和退出状态。每次截图使用独立路径，确认文件存在、可解码、尺寸和方向；黑屏或不可用采集不能变成有效空屏幕。启动 App 后通过实际截图/已验证可用的前台信息核对结果，不只相信 launch 回包。

每次观测记录 `observationID`、deviceID、会话代次、截图时间、图像尺寸、方向、裁剪/缩放变换与原图引用。截图与动作必须关联到同一设备和仍有效的观测。观测时间是宿主采集时间范围，不冒充设备精确呈现时间。

先提供按需 PNG，不预先建设实时视频。只有测量表明 CLI 耗时不满足需求，才考虑常驻截图或媒体解码。

### 6.3 AppleServiceTransport

优先确认 Apple 配对连接、服务发现和端点获取的可调用方式；若需要自写 RemoteXPC 子集，独立实现必要编解码和生命周期。不要把普通 TCP 或 Network.framework 当作已完成设备协议。

验收必须覆盖：目标设备/服务识别、请求编号、回复关联、同连接多请求、超时与取消、断连重连、版本不支持、明确的权限拒绝。不能预先承诺无 sudo、无额外授权或无需特定 Apple 进程。失败应明确上报，不绕过授权检查。

### 6.4 MediaSession

一段工作流复用会话，记录本客户端创建的 session 与资源所有权。验证协商、接收循环、保活、异常清理和正常停止确认。输入有效不等于媒体流健康。

首阶段可不解码视频，但不能省略协议必需的接收/保活。禁止用无归属的 `stopAll` 清理共享设备；若目前只能独占，明确列为支持限制。服务存在、start 回包、EOF 和进程退出分别记录，不能互相冒充。

### 6.5 NativeHIDAdapter 与 GestureScheduler

封装服务、surface 选择、二进制报告和调度，避免上层业务操作私有字段。已观察服务为：

```text
com.apple.coredevice.hid.universalhidservice
com.apple.coredevice.feature.remote.universalhidservice
```

历史触屏 surface ID 为 257；同机还枚举过 keyboard、mainScreenButtons 等表面。按当前服务描述选择与验证，不能跨设备固定推断。capability 存在不代表已实现相应能力。

手势规范见第 7 节。每设备串行执行，触摸接触和键盘按下状态均需清理；结果不确定时不自动重放。

### 6.6 CoordinateMapper 与 ActionVerification

坐标来源必须标明原截图、缩放截图或局部裁剪。将模型输出经逆裁剪、逆缩放和方向映射还原，再转成设备归一化坐标；转换参数来自该次观测。

执行前检查 observation/device/session 是否匹配、方向和尺寸是否仍适用、是否发生已知页面或键盘变化。失效则返回 `stale_observation` 并重新截图定位。时间阈值通过实测设置，不凭一个 TTL 保证动态页面绝对未变化。

执行后获取新观测，按任务预期验证，例如目标 Tab 选中、输入内容出现、滚动内容变化；截图差异只能证明变化，不能自动证明目标完成。保持无变化与结果不确定两个不同状态。

### 6.7 AXSemanticProbe：暂停常规扩展，保留研究入口

默认不采集 AX、不执行 AX Activate。重启研究须有新 Apple 原生接口、明确调用修正或相关工具链更新，而不是继续换 App 重复同类实验。

若未来接入，必须满足：

- 不通过 SetFocus、前后导航或 Scroll 采集，也不先遍历滚动再过滤。
- 有可靠的视口归属/可见性证据；元素存在、首末位置、角色或手工截图对照都不能自动证明完整当前屏幕树。
- 与截图的设备、状态和采集时间关联，明确部分覆盖、不可用和内容缺失。
- AX 错误、空回包与 `viewport_tree_unverified` 不解释为空页面；不阻塞主视觉路径。
- 未验证的 AX frame 不用于 HID 定位；动作列表不冒充已验证可执行能力。

开发 Probe 的 AX 正对照可作为研究工具，不是普通第三方 App 的生产保证。

### 6.8 不默认依赖 Swift 私有 ABI shim

不以声明同名类型后 `dlsym/unsafeBitCast` 调用未知 Swift ABI 为生产默认实现。模块可见性、泛型、异步调用约定、值类型布局、对象生命周期和权限仍需验证。既有符号分析保留为研究资产，不因存在符号就认定 SDK 可用。

## 7. 单指手势规范

### 7.1 统一事件模型

基于历史 tap/滑动实验和接触序列模型设计；下面不是纯原生实现已完成的声明：

```text
tap:
  CONTACT(P) → 短暂保持 → RELEASE(P)

longPress:
  CONTACT(P) → 保持指定时间 → RELEASE(P)

swipe:
  CONTACT(P0) → CONTACT(P1) → … → CONTACT(Pn) → RELEASE(Pn)

drag:
  CONTACT(P0) → 起点保持 → CONTACT(P1) → … → CONTACT(Pn) → RELEASE(Pn)
```

移动阶段保持同一触点身份，不能通过重复 tap 模拟 swipe。长按和拖拽是否被目标 App 识别，仍取决于手势参数和应用状态，需要真机验收。

原方案记录的历史 Tap 没有显式 hold 延迟，也已成功。产品可以把 tap 的按下时长作为可配置值，但其默认值是工程选择，不是本次实验测得的设备要求。

### 7.2 报告布局：原方案保留的历史实验样本，不是完整公开规范

| 字节偏移 | 本次实验代码使用的内容 |
|---|---|
| 0 | report ID `0x09` |
| 1–2 | `0x01 0x05` |
| 3 | CONTACT=`0xC2`；RELEASE=`0x02` |
| 4–5 | X，UInt16，小端 |
| 6–7 | Y，UInt16，小端 |
| 8–39 | 32 字节零 |
| 40–43 | `0x02 0x00 0x00 0x00` |
| 44–49 | 6 字节时间戳字段 |
| 50–57 | 8 字节零 |
| 总长度 | 58 bytes |

以上布局与成功 tap 的实验实现相符，但不能推导其所有字段语义、全部合法取值或多指能力。

特别注意时间戳：此前 Go 示例的 `monotonicTimestamp()` 使用 `time.Now().UnixNano()` 截断，名字不代表其真正单调。本机 tap 成功不证明该时间戳在长手势、时钟调整和所有系统版本中都正确。自研实现应区分“宿主调度时钟”与“协议事件时间戳”，对后者的单位、来源、截断和回绕单独确认，不把纳秒与 Mach tick 直接当成同一概念。

### 7.3 坐标规范

建议 AgentSoma 上层统一使用 `[0,1]` 归一化坐标，由后端映射：

```text
hidX = round(clamp(x, 0, 1) × 65535)
hidY = round(clamp(y, 0, 1) × 65535)
```

原版文档的样例只验证了 `(32768,32768)` 中心点；历史直接输入实验另有非中心点击和滑动成功。但纯原生新客户端仍须重新验收原点方向、多位置、边缘、裁剪和旋转映射，不能继承其他客户端的正确性结论。

若定位来自 PNG 像素坐标，应先应用截图裁剪/方向的逆变换，再做归一化。不要把 1170 × 2532 像素直接当成 UIKit points，也不要不经验证地固定除以 3。整数像素索引如何映射到连续坐标，应在适配器中采用明确、一致的约定并覆盖边界测试。

### 7.4 调度、取消与清理

建议使用单调时间基准和绝对发送期限，避免逐帧 `sleep(frameDuration)` 将计算、网络和调度耗时不断累积。首版可以使用可配置采样率；例如 0.3 秒、18 个移动段只是约 60 Hz 的设计起点，不是设备保证。

每台设备同一时刻只允许一条单指手势执行。接触开始后记录“可能仍按下”的状态和最近坐标；成功、错误、超时、取消均进入清理路径，尽力发送 RELEASE，再按所有权关闭本客户端媒体和服务连接。断连时无法保证释放送达，应上报状态不确定，重连后执行明确的状态恢复，而不是自动重放旧手势。

原版实验扩展缺少完整取消和统一释放处理，且采用逐步等待；历史后续探针有补充清理，但仍未形成纯原生生产实现。不能把任何实验版本直接作为产品版本。

## 8. 对外接口与结果语义

以下为自研接口草案，不是已交付工具或 Apple 命令：

```text
session.open(deviceID) → sessionID / capabilities
session.close(sessionID) → cleanupResult
app.activate(deviceID, bundleID) → activationResult（仍需页面核对）

screen.capture(deviceID) → observation
screen.record(deviceID, duration, codec) → videoArtifact（独立验收后提供）

touch.tap(sessionID, observationID, x, y, holdMs)
touch.longPress(sessionID, observationID, x, y, durationMs)
touch.swipe(sessionID, observationID, from, to, durationMs)
touch.drag(sessionID, observationID, from, to, holdMs, moveMs)
```

`observation` 至少包含：

```text
observationID, deviceID, sessionGeneration
captureStartedAt, captureCompletedAt
imageArtifact, imageSize, orientation
coordinateSpace, cropTransform, resizeTransform
validity: valid / capture_unavailable / invalid_image
```

动作必须指定坐标空间。默认可约定为原设备截图的归一化空间；局部图片输出必须先由映射层还原，不能在没有转换信息时直接提交。

动作结果至少区分：

```text
actionID, sourceObservationID, afterObservationID
transportStatus: not_sent / sent / acknowledged / failed / uncertain
verificationStatus:
  not_checked / observed_change / expected_result_confirmed
  / no_observed_effect / uncertain
reason: stale_observation / unsupported / target_mismatch / timeout / ...
```

回包成功只影响 transportStatus。相同页面截图、不同像素、AX status=0 都不能单独生成 expected_result_confirmed。相同已选中 Tab 的再激活没有鉴别力，不计作导航成功。

遇到超时或断连，保留 actionID 并重新观察；如果无法判断是否已生效，返回 uncertain，不自动重放。每设备互斥，禁止异步截图与其他控制者的操作被错误关联为同一观测。

记录输入参数、发送时序、最近触点、清理结果和前后观测。日志说明的是本客户端注入的动作，不是用户物理触摸的全量监听；宿主发送时间不等于设备处理时间。

文字输入接口在独立验收后再定义并发布。不要用未验证的 AX Value 写入、剪贴板技巧或组合键填补 capability 声明。

## 9. 首版范围与成本策略

### 9.1 最小交付范围

一台已配对、开启 Developer Mode 的 iOS 27 真机，优先原有 wired 环境。先交付设备发现、App 激活后的页面核对、有效截图、会话生命周期、tap 和操作后验证，再逐项扩展滑动、长按、拖拽。支持列表只声明已经通过的能力。

如果首版定位为导航与触摸控制，明确不承诺完整消息编写任务。如果产品要执行微信/Lark 等文字工作流，中文与输入法必须成为该版本的独立发布门槛，不能以英文 Lark 样例代替。

### 9.2 截图成本优化

建立未优化的截图闭环基线，测量任务成功率、定位/点击错误、延迟及模型实际图像和文本 token。再分别评估：

- 按需截图和动作后验证，避免无意义的固定频率采集。
- 保留最近有效画面与必要局部细节，旧图转为简短状态记录；减少历史不等于降低单张图像计费。
- 适度降低分辨率与按需局部高清图；所有裁剪必须携带可逆坐标变换。
- Apple Vision 本地 OCR 的文本、置信度与边界框；显式标注来源，保留视觉定位确认。

不按 PNG/JPEG 文件字节数推导 token，不预先承诺固定节省比例。压缩原始 AX JSON 的字节数也不能冒充相对截图的 token 收益。OCR 不能提供按钮角色或通用可执行语义，不替代完整视觉理解。

### 9.3 不作首版承诺

完整 AX 树/命中点、普通 App 通用 AX 操作、多指、未验收键盘与硬件键、固定实时帧率、任意 App 完全兼容、关闭 Developer Mode 的可用性、免 Xcode 安装、私有接口跨版本稳定。

不自动解锁口令设备或跳过信任/授权，不绕过 MCP 内部门槛，不用关闭系统保护达成兼容。Mac 升级不自动意味着新权限入口可用。视频录制与持续流解码分别验收。

## 10. 工程阶段与验收门槛

| 阶段 | 工作内容 | 完成标准 |
|---|---|---|
| M0：证据与环境基线 | 固化版本、来源、支持范围及历史/当前结果 | 第三方历史实验与原生实现分开；旧宿主结果不冒充 macOS 27 复测；AX 常规扩展暂停 |
| M1：原生观察层 | 设备、App 激活、截图、观测元数据 | 可重复获取正确设备/页面；黑屏、无文件、旧文件、锁屏等不生成有效空观测；录屏不阻塞截图闭环 |
| M2：纯原生传输与媒体 | Apple 连接/必要协议、媒体所有权和清理 | 无第三方客户端即可冷启动；多请求/回复关联正确；保活、断连、取消可解释；只关闭自己的会话，明确并存限制 |
| M3：纯原生 tap 闭环 | 观测关联、坐标映射、触控报告、操作后确认 | 同机新环境完成多位置点击、边缘/方向对照；按目标行为验收；Device Hub GUI 非必需性重新核对；超时不盲重放 |
| M4：手势与恢复 | swipe / longPress / drag、手势中取消/断连 | 每项独立真机通过，触点释放与不确定状态正确；不以 tap 推定其他手势可用 |
| M5：文字输入（按产品范围） | 焦点、英文/中文、输入法、删除、必要按键 | 每项文本回读正确；未验收功能明确 unsupported；消息工作流发布前必须完成所需项 |
| M6：产品集成与成本 | 设备互斥、常驻会话、观测失效、产物管理、截图/OCR 策略 | 端到端任务可重复；重连不重放旧动作；测量成功率/延迟/token，证明优化收益；无隐式 Runner 或第三方工具回退 |

录屏是独立能力：输出文件可解码、时长合理、停止/取消后完整，不能与实时媒体帧输出混为一谈。实时解码只有测量需要时进入后续阶段。

M2–M3 是当前首要工程门槛。AX 不是里程碑阻塞项，不再投入常规重复按钮测试。若未来重启 AX，先通过不滚动、视口归属和实际收益验收，再讨论集成。

宿主单元测试使用自写 fake transport 覆盖协议字节、坐标变换、关联回复、过期观测、取消与清理；真机在受控页面验证行为并抽样普通 App。宿主测试不要求在手机安装 XCTest Runner。

每项记录通过次数/总次数、版本、设备、运行条件和失败证据；未经测量不承诺成功率或延迟指标。发生失败后先定位新的证据，不重复无区分力实验。保留既有生产后端直到迁移验收，但不得将它的执行结果记到新原生后端名下。

## 11. 本地证据索引

以下均为本地研究产物；原版 2026-09-17 文档中的 CLI 帮助、外部客户端日志、符号和 report 布局证据保留在原机本地备份，未随本仓库发布。本次修订没有重新运行第三方工具。

- [直接输入历史实验：点击、滑动、英文输入、媒体/RPC 问题](../../.local/research/ios27-physical-20260915/direct-input/RESULT.md)
- [官方 MCP 真机入口根因](../../.local/research/ios27-physical-20260915/mcp-diagnosis/ROOT-CAUSE.md)
- [原生 Probe AX 点击成功](../../.local/research/ios27-physical-20260919/apple-native-ax/agentsoma-probe/AX_CLICK_RESULT.md)
- [原生控件、输入焦点、滚动与引用](../../.local/research/ios27-physical-20260919/apple-native-ax/agentsoma-probe/native-matrix/RESULT.md)
- [Web 控件矩阵及证据限制](../../.local/research/ios27-physical-20260919/apple-native-ax/agentsoma-probe/web-matrix/RESULT.md)
- [Probe 签名 true→absent→true 对照](../../.local/research/ios27-physical-20260919/apple-native-ax/agentsoma-probe/signing-comparison/RESULT.md)
- [Lark 消息完整可见时的层级与正文缺失](../../.local/research/ios27-physical-20260919/apple-native-ax/lark-hierarchy/RESULT.md)
- [Lark 历史动作矩阵及输入占位节点限定](../../.local/research/ios27-physical-20260919/action-matrix/RESULT.md)
- [macOS 27 升级后连接、权限与 Device Hub 对照](../../.local/research/ios27-physical-20260919/apple-native-ax/agentsoma-probe/macos27-retest/RESULT.md)
- [微信首页 AX 与 Shortcut 激活](../../.local/research/ios27-physical-20260919/apple-native-ax/wechat-macos27/RESULT.md)
- [微信四个 Tab 激活与 Selected 状态](../../.local/research/ios27-physical-20260919/apple-native-ax/wechat-tabs/RESULT.md)
- [严格无焦点/无导航的当前屏幕读取](../../.local/research/ios27-physical-20260919/apple-native-ax/viewport-read/RESULT.md)
- [该实验的原始 AX 可读数据](../../.local/research/ios27-physical-20260919/apple-native-ax/viewport-read/wechat-2/reads-readable.json)
- [该实验的像素与协议核对](../../.local/research/ios27-physical-20260919/apple-native-ax/viewport-read/verification.json)

路径包含本机内部截图、设备信息与会话数据；作为工程证据本地引用，不直接随产品或公开测试 fixture 分发。

## 12. 修订决策

采用 **截图作为主观察、HID 作为主执行、操作后新截图作为结果验证** 的纯原生 macOS 后端。通过观测身份与坐标变换减少位置错误，通过按需截图和经过实测的本地文字辅助控制成本。

当前 Inspector AX 路径不进入首版默认观察或执行链路；它已提供有价值的能力边界证据，但未满足普通 App 的完整视口采集和可靠操作要求。没有新的入口或明确修正前，暂停常规 AX 扩展实验。

下一步落实 M2–M3：独立完成 Apple 服务传输、媒体会话和 tap 闭环，解决已知回复关联、所有权和清理问题。纯原生 AX 实验成功不替代这项 HID 工程工作。技术机制已有证据，零第三方依赖的通用真机控制产品尚未交付。

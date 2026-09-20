# Apple 原生文本输入通道：调研结论

日期：2026-09-20。对应实现：`0cb93d8`，直接 Unicode HID 调研：`7bcec8c`。

## 决策

**保留“设备原生剪贴板服务 + 自写 HID Paste”作为当前原生后端的 Unicode 主路线。它是当前约束下已验证、最适合继续工程化的方案；不能称为所有 Apple 通道中的绝对最优，也不能称为当前实现已经完善。**

这里的目标是：普通第三方 App 的当前输入框、准确插入指定文本、不启动 Runner/XCTest、不引入第三方设备客户端、不伪造 Apple 身份或关闭系统保护。当前部署沿用配对开发连接；额外安装并启用自写键盘扩展是另一种部署方案，并非原则上禁止。

当前方案已在受控 Probe 验证 `中文` 和 ` A7，测🙂`。这只证明已测字符和控件的效果，不承诺所有 App、安全输入框、超长文本或所有 Unicode 序列。发送成功、按键队列排空和截图变化都不是文本消费确认。

## 候选通道比较

| 通道 | 查到的能力与证据 | 当前判断 |
| --- | --- | --- |
| CoreDevice 原生剪贴板 + HID Paste | 自写客户端已完成 Probe 中文/混合文本输入、原内容恢复和独立回读 | 推荐主路线；有权限提示、剪贴板占用及恢复竞争窗口 |
| HID 物理键 + 系统输入法 | 现有 US usage 映射；已有拼音/视觉选词记录 | 可用于真实按键和输入法交互，但受布局、候选与组合状态影响，不是通用精确字符串接口 |
| 直接 Unicode HID | Apple 有 Unicode 事件类型；已查当前 UniversalHID 报告和 DDI 适配器未发现对应传输 | 未找到可用实现，不能把事件类型编号当作报告编号发送 |
| RemoteTextInput / Rapport | 本机运行时确认字符串操作和文本会话类存在 | 尚缺普通客户端取得目标 iPhone 输入会话的授权端点与协议证据；不是已完成通道，也不是已证实的权限拒绝 |
| iPhone Mirroring | Apple 支持 Mac 键盘输入；phone-harness 的字符串路径默认仍用剪贴板 | 改变连接和运行条件，未得到更好的独立 Unicode 客户端；不替换当前后端 |
| 自写键盘扩展 | Apple 正式支持 `textDocumentProxy.insertText` | 有条件的无剪贴板候选；需要安装、启用、切换及宿主文本交付，覆盖范围更窄 |
| XCTest / WDA / DeviceKit | 已查字符串输入经测试 Runner | 不符合本原生后端约束；现有发布后端继续独立保留 |

## 直接 Unicode 与 RTI 的证据边界

[Apple IOHIDEvent 源码](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDEvent.cpp)包含带 payload/encoding 的 `unicodeEvent`。因此，“HID 从根本上只能输入 ASCII”是不准确的。真正缺口在于当前远程服务是否有相应报告、接收适配器及授权派发路径。

此前匹配本机版本的 DDI 调研确认 `dtuhidd` 按报告 ID 选择适配器；已检查的 20 个导出报告 ID、适配器构造与导入没有 Unicode 入口。设备 capability 清单也没有独立文本插入能力。这是当前已查范围的负面证据，不是对所有私有路径的穷尽证明。详情见[后端记录](../apple-native-backend.md#direct-unicode-hid-investigation-2026-09-20)。

本轮另编译自写 Objective-C 元数据探针，仅加载本机 Apple 框架并枚举类和方法，没有实例化输入客户端或建立输入会话：

- `RTITextOperations` 有 `insertText:replacementRange:` 和 `initWithTargetSessionUUID:`。
- `RTIInputSystemClient` 有 Mach 名称/endpoint 连接接口、活动会话和 `performTextOperations:resultHandler:`。
- Rapport 的 `RPTextInputSession` 有 `rtiSession`、`messenger`、文本开始/停止处理和文档请求接口。
- RemoteHID 的已查类有设备/端点/报告操作；未据此取得面向当前配对 iPhone 的字符串服务。

这些证明 Apple 存在独立于物理键码的文本机制，但方法名、可加载框架和序列化对象不能提供目标设备的有效会话。尚未验证普通开发客户端怎样合法取得该会话、绑定前台输入框并确认提交。本轮没有调用这些操作，不能报告“调用被拒绝”或“真机可用”。

## Mirroring 与自写键盘扩展

[Apple Mirroring 文档](https://support.apple.com/en-au/120421)要求同一 Apple Account、双重认证、Wi-Fi/Bluetooth 和附近锁定的 iPhone。它支持键盘操作，但不是当前解锁真机上的 CoreDevice 会话。只读签名检查发现本机 Apple 应用持有多个私有 entitlement；这不证明某个文本方法必需其中哪一项，也不授权复制这些身份。

phone-harness 的默认输入实际经过 Mac 剪贴板和 Command-V；其代码称 Mirroring 忽略 CGEvent 的 Unicode 字符串负载。后一句仅是上游实现说明，本机没有独立复测，不能扩展为所有 Mirroring 文本机制都不可用。

[Apple 自定义键盘文档](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)提供 `textDocumentProxy.insertText`。这条路线可避免剪贴板，但用户必须启用并选择扩展；安全字段、电话键盘字段和拒绝键盘扩展的 App 不受覆盖。宿主向扩展交付任意文本还需要设计传输和生命周期；网络/共享容器方案涉及开放访问能力。尚未实现或真机验证。

因此，如果未来接受“安装自写键盘 + 用户主动启用 + 仅覆盖支持扩展的输入框”，它值得单独做最小原型。不能仅因为它能调用 `insertText` 就认定它在本项目的覆盖率、部署成本和可靠性上优于现有方案。

## 三个开源项目的核对

只读审查固定版本，没有安装或执行其设备工具：

- go-ios `c584042907dee35bf80377284ae3aac85990b4d7`：[文字分派](https://github.com/danielpaulus/go-ios/blob/c584042907dee35bf80377284ae3aac85990b4d7/cmd_ui.go#L201-L208)进入 WDA 或 DeviceKit；[启动代码](https://github.com/danielpaulus/go-ios/blob/c584042907dee35bf80377284ae3aac85990b4d7/cmd_device_ui_run.go#L26-L73)两者都使用 `.xctest` Runner。
- pymobiledevice3 `68b444e054ceb456d3215dbfb7ead7db4c507801`：[原生 type](https://github.com/doronz88/pymobiledevice3/blob/68b444e054ceb456d3215dbfb7ead7db4c507801/pymobiledevice3/cli/developer/core_device.py#L754-L789)按 ASCII 映射为键码；查看器另同步剪贴板并发送粘贴键，不是任意 Unicode HID 报告。
- phone-harness `efab26a0d89836b0d8ac19197894cfdc888686b5`：[Mirroring 输入](https://github.com/ShawnPana/phone-harness/blob/efab26a0d89836b0d8ac19197894cfdc888686b5/src/phone_harness/mirror.py#L535-L681)默认粘贴，可选 US 实体键码。默认保留剪贴板文本，避免异步消费时过早恢复。

未发现这三个项目提供“普通配对开发连接 + 无 Runner + 无剪贴板 + 任意 Unicode”的已实现路线。

## 决策时发现的改进点

1. **文本意图与按键意图还混在一起。** `NativeTextInput` 按是否含非 ASCII 字符选择路径。纯 ASCII 强制走 US 键码且限 64 字符，混合文本则走最多 4096 UTF-8 字节的粘贴。活动输入法可能改变 ASCII 的最终结果。下一步应明确区分“精确插入文本”和“发送物理键”，让纯 ASCII 也能显式选择现有粘贴通道；迁移默认行为要有契约和回归验收，不能静默改变。
2. **剪贴板占用期可以缩短，但不能猜测消费完成。** 当前原内容保存在内存，直到会话关闭才恢复。可增加外部 Agent 核对新截图后的显式结束/恢复动作，绑定本次文本事务，恢复前继续检查所有权，保持设备控制会话可用。不要用固定延时或 HID 回包当作消费确认。断连/崩溃可能遗留内容，协议没有原子 compare-and-set，不能承诺完全无竞争。
3. **接受度仍需补齐。** 已测 Probe 不代表其他控件。后续优先覆盖长文本、连续插入、组合字符、拒绝粘贴、焦点变化和恢复失败；保留未知结果不重放。系统粘贴菜单也可作为可见、单独验证的交互方式，但不是免权限保证。Apple 的 [UIPasteControl 说明](https://developer.apple.com/videos/play/wwdc2022/10068/)涉及目标 App 的系统粘贴 UI，不能通过给 Probe 增加专用控件来宣称普通 App 已被覆盖。

### 后续实现进展

随后工作区已实现显式 `type --method auto|keys|paste` 和 `text-finish oN --transaction ID`，对应前两项改进。默认行为保持不变，恢复要求当前操作后截图及最新事务 ID；旧宿主拒绝新的显式方式请求。运行契约与最终验收范围见[后端说明](../apple-native-backend.md#explicit-text-methods-and-clipboard-completion)，不能把功能代码已存在等同于新增真机验收通过。

## 调研停止条件与验证范围

本轮收敛于上述工程决策，不继续仅凭字符串/符号猜测服务或向设备发送未知包。只有拿到合法可获得的目标端点、会话来源和接收端协议证据，才重新打开直接文本通道研究；或明确选择键盘扩展的新部署范围后再验证该路线。

本轮重新核对宿主为 macOS 27.0 (26A428)、Xcode 27.0 (27A266a)。自写宿主元数据探针编译、运行成功。**没有新设备连接、输入、剪贴板读写、设置变更或真机验收；没有重跑产品测试。** 已有真机成功和测试结果归属于原来的验收记录。

私有证据分别在 `.local/research/apple-native-text-decision-20260920/`、`apple-native-keyboard-projects-20260920/`、`apple-native-unicode-event-20260920/` 和 `apple-native-unicode-20260920/`；不作为构建依赖，也不提交原始设备信息。

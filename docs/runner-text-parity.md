# Runner append 与多行文本验证

2026-09-22：Runner 增加 append 和 text_view 的 LF 多行输入，协议升级为 actionVersion=6。标准模式的 HID/粘贴实现保持原有行为。使用新 CLI 时需配套重新构建 Runner；不自动切换模式。

## 实现与限制

append 在宿主检查观察中的原文，并在 Runner 再次校验目标和当前快照后读取原文，拼接新增文本，复用 replace 的聚焦、全选和输入流程。整段结果不得超过 4096 UTF-8 bytes。安全字段、不可读值、无法与 placeholder 区分的值或不支持的字符均在输入前拒绝。nil 不推断为空字符串。原文可读不代表 App 支持无损整段替换，格式化、编辑回调和 undo 行为仍由 App 决定。

LF 使用 XCTest typeText 的文字输入通道，只允许明确的 text_view。单行字段在输入前拒绝多行内容；不会用独立 Return 操作代替文本换行。输入不裁剪空格、空行或末尾 LF。Runner 拒绝 CR/CRLF，不静默规范化或转用原生剪贴板。

原有 observation 引用、目标核对、输入后判稳和 unknown 不重放契约继续适用。`completed` 表示执行和判稳完成，正文是否符合业务预期仍需外部 Agent 核对。

## 真机发现

环境重新检查为 macOS 27.0 (26A428)、Xcode 27.0 (27A266a)、iPhone 12 Pro / iOS 27.0。设备通过 Apple CLI 动态发现。全部输入限定在自写普通 Probe，没有进入其他业务 App 或修改设置。

初版曾用 Command-Down 定位末尾，但在 Probe 选中首字符时，调用成功后选区仍未移到末尾：`头🙂尾` 加入 `追加` 实际得到 `追加🙂尾`。因此删除该方案，改用可读原文拼接与 replace；没有根据 XCTest 成功回执声称追加正确。

CRLF 初次实验得到两个 LF，字节数和 scalar 数虽与原输入相同，实际 UTF-8 不相等。因此最终实现拒绝 CR/CRLF。该结论来自当前 Probe 和工具链，不假定所有系统版本、所有 App 都有相同行为。

## 最终验证

| 项目 | 结果 |
| --- | --- |
| 原文 `头🙂尾`，UTF-16 选区 `0,1`，append `追加` | 精确得到 `头🙂尾追加`；16 bytes、5 scalars；输入后约 2.60 秒判稳 |
| LF replace | 包含首尾空格、emoji、空行、组合字符 `e` + U+0301、末尾 LF 的正文精确匹配；21 bytes、11 scalars |
| 已有 LF 原文再 append 多行后缀 | 最终正文与同一 21-byte 样本逐字节相等；约 2.84 秒判稳 |
| 最终版本提交 CRLF | `invalid_text` / `not_dispatched`；新观察原文未变，Probe 编辑次数仍为 15 |
| 自有会话清理 | 两次会话均收到 shutdown 确认，xcodebuild 正常退出；宿主与 xcodebuild 进程已退出 |

正文核对使用 Probe 的 EXACT UTF-8 MATCH、动作后截图及保存的 AX 字符串与输入文件逐字节比较，不只看进程退出码或字符计数。

宿主 Swift 测试执行 280 项：279 通过、1 项原有 opt-in Apple 框架检查跳过、0 失败。新增覆盖完整拼接的字节上限、不可读/安全字段、placeholder、不支持控制字符、LF 字节保留及单行字段拒绝。Release CLI、签名 Runner 和普通 Probe 均构建成功。没有把宿主测试计为真机验收，也没有对所有 App、所有文本模式组合或异常取消场景做新一轮真机覆盖。

本机原始日志、输入文件、截图、快照和失败实验保存在忽略目录 `.local/research/runner-text-parity-20260922/`。`physical-summary.json` 汇总字节核对和清理结果；这些证据不是运行依赖，也不随仓库发布。

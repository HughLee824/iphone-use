# Runner AX 路径修复与 iPhone 12 Pro 验证

2026-10-24，通用修复已在 iPhone 12 Pro / iOS 27.0.1 验证。普通文本框和小红书搜索框均完成实际 XCTest 输入；未添加 App 名称、bundle ID 或页面特判。下方保留早期失败记录，避免将中间版本结果当作最终结果。

## 最终通用实现

- 每次采集显式请求非模态标准属性快照，避免公开 `root.snapshot()` 的模态过滤；不把 query 的缓存根快照当作当前页面。
- 完整采集与展示预算分离，不固定截断 200 节点。每个节点有观察期内有效的随机身份 token，Runner 保存对应 AX 身份；新观察或动作消费后旧引用失效。
- 执行沿新快照完整路径校验观察时的 AX 身份及属性，再绑定到该快照的确切 AX 身份。不会按 TextView 类型和空名称重新挑选候选。
- 用 `hasKeyboardFocus` 判断键盘焦点。必要时点击一次，然后重新校验；控件替换时停止，不迁移旧命令。
- 光标定位、清空、插入各阶段重新校验。自身文本修改后仅允许目标叶节点的 label/value 变化，路径、身份、类型、identifier、enabled、frame 和祖先属性继续校验。清空结果与替换/追加的最终值必须确认。
- 回执记录阶段、聚焦是否执行、键盘事件尝试次数、插入是否确认。部分执行与不确定结果均不自动重放。

设计细节见 [架构说明](architecture.md#runner-路径定位与完整-ax-采集)，原始问题诊断见 [搜索页 AX 诊断](runner-search-ax-diagnosis.md)。

## 本次真机验收

| 场景 | 实际结果 | 本机证据目录 |
| --- | --- | --- |
| 小红书双无名 TextView | 227 节点；搜索框 e23、摘要 e75。命中顶部搜索框并聚焦；编辑器替换后 `target_changed`，键盘事件 0，原文不变 | `09-xhs-two-textviews`、`10-xhs-replaced-on-focus-stopped` |
| 小红书替换与追加 | `上海周末好去处10月` → `上海展览1024` → `上海展览1024A`，均 completed，无重复；随后恢复原文 | `05-xhs-replace-success`、`07-xhs-append-once`、`08-xhs-restored` |
| 小红书最终版本复验 | 空框 insert `上海展览1024`，append `Z` 得到 `上海展览1024Z`，replace 空串清理，均 completed | `24-xhs-final-empty` 至 `27-xhs-final-cleared` |
| 普通文本框与焦点切换 | 通讯录未保存表单，第一、第二输入框分别收到 `AXFirst1024`、`AXSecond1024`；第二框自动聚焦一次后输入，无串框 | `15-contacts-first-insert`、`16-contacts-second-focus-insert` |
| 普通文本框最终替换、追加 | 第一框 replace `AXReplaced1024`、append `Z` 均 completed；第二框始终保持 `AXSecond1024`，Company 为空 | `19-contacts-first-restaged` 至 `21-contacts-append-once` |
| 过期引用 | 小红书和普通表单均故意使用上一次观察引用；`stale_reference` / not_dispatched，新观察值不变 | `06-xhs-stale-rejected`、`22-contacts-stale-rejected` |
| 当前快照 | 每轮 AX value 与实际截图同步变化；设置搜索页由 412 节点变 111，清空后 371；通讯录表单约 272 节点，丢弃后 86；均未取旧内容或截到 200 | 各目录的 `snapshot.json`、`screen.png` |
| 清理 | 测试联系人丢弃，设置和小红书测试内容清空；自建会话断开，Runner、预览媒体和观察缓存清理确认 | `23-contacts-discarded`、`27-xhs-final-cleared`、`final-cleanup.json` |

证据根目录为本机 `.local/generic-ax-verification/evidence/`，每项同时保存截图、快照和完整回执；`final-cleanup.json` 位于其上一级。它们未加入版本控制。最终签名构建目录为 `.build/runner/6af573bb-801c-4540-89e9-1da3e7d29ee8/`，已安装并真机运行。

## 后续输入事务修复

设置搜索的末尾 unknown 已通过事务内有界只读收敛修复；最终 5 秒版本完成设置插入/追加/清空、普通表单跨框输入/替换及小红书中文输入/追加/清空。最新设计、测试和原始证据索引见 [输入事务收敛验证](runner-text-convergence-verification.md)。下方保留当时的失败记录。

## 保守拒绝与边界

设置搜索框收到一次 `AXProbe1024`，随后搜索结果刷新，末尾目标验证返回 `target_changed` / unknown。最初回执没有标明失败节点；后续独立诊断已确认：20 层路径身份均相同，键盘短暂收起再出现，搜索栏真实移动；末尾校验在 depth 16 容器的 frame 比较处停止。详情与连续截图时间序列见 [设置搜索诊断](runner-settings-search-diagnosis.md)。回执保留 `insertionAcknowledged=true`、`keyboardEventsAttempted=1`、`stage=verifying_result`，截图和新 AX 值均为完整测试串，没有重放。此项验证了部分执行事实与防重复行为，**不记为自动完成通过**。证据：`11-settings-empty`、`12-settings-insert-once`、`13-settings-cleared`。

实现仍严格拒绝路径变化；UI 重排可能要求重新观察。XCTest 的校验与事件不是原子操作，不能据这些测试承诺所有 App、所有竞态下绝不会错选；平台身份复用也不在本次可证明范围。运行时接口缺失、签名变化或异常会明确停止。部分截图的 stability=false 来自状态指示和光标变化；未放宽 guard，也未据此重发输入。

验收中另修正了两项通用行为：`hasFocus` 不等于键盘焦点；普通文本框清空后 label 可以由 placeholder 文本变为空。修正前的停止回执保留在 `02-xhs-focus-guard`、`17-contacts-clear-guard`。

## 最终自动验证

- Swift 全量：580 项，2 项跳过，0 失败；相关子集 39 项通过。
- AX 运行时替身测试通过，包括显式非模态参数、每次重新请求、确切快照绑定、键盘焦点、接口缺失、错误签名及异常。
- Python 88 项通过；Node 73 项通过、1 项跳过；插件同步检查通过。
- 最终签名 Runner 构建、安装和连接通过；`git diff --check` 通过。未安装 SwiftLint，未声称执行。
- 回归覆盖相同属性节点替换/换序、观察 token 消费与失效、当前树与旧树不同、聚焦/清空/插入期间变更、插入后异常不重放、仅允许目标叶节点内容更新，以及 1201 节点宽树、501 层深树和完整缓存/inspect/路径链路。

## 早期阶段记录（最终实现之前）

以下是此前仅完成路径绑定时的结果，文本输入当时尚未端到端通过。

## 旧问题与实现

搜索结果页同时有两个 `TextView`：搜索框和 AI 摘要。二者 type=52、identifier 和 label 均为空；旧实现先验证完整快照路径，随后用这三个属性全局重新查找，得到两个结果并拒绝执行。

新实现保留完整路径的含义：在执行时的新快照中逐级校验，然后将路径命中的快照绑定到其 AX 身份。绑定后复核目标属性、身份和最新完整路径。具体接口和边界见 [架构说明](architecture.md#runner-路径定位与完整-ax-采集)。

真机还暴露了一个不能假设的前提：`XCUIElement.children` 查询并不一定与原始 snapshot.children 一一对应。本次两个窗口外观属性相同，主窗口快照只有一个子节点，而索引绑定和 identity binding 后的子节点查询都返回了两个窗口的容器，子树大小分别为 2 和 220；类型过滤也未解决。最终实现不再把快照子索引直接套到查询结果上，而是使用已校验快照的 AX 身份绑定。诊断用的查询树输出未保留在运行代码中。

## 真机结果

| 检查 | 实际结果 |
| --- | --- |
| 原始采集不再固定截断 200 | 搜索结果页保存 225 个节点，`source_truncated=false` |
| 展示与完整缓存分开 | 默认输出仍精简；`inspect --query Latest` 在 225 个节点中找到 `e204` |
| 双无名 TextView 的目标选择 | 搜索框 `e21` 与摘要 `e73` 并存时，通过路径和身份校验，实际点击顶部搜索框进入编辑页，无 `ambiguous_target` |
| 聚焦后的 XCTest 输入 | 未通过：页面切换后旧 AX 身份消失；Apple 返回 `No matches found for Identity Binding`，动作标记 `unknown`，没有自动重试 |
| 新编辑页的公开快照 | `root.snapshot()` 返回 80 个节点，本地未截断，不含 text_field / secure_text_field / search_field / text_view；截图上搜索框与键盘仍可见。后续查询快照发现了该输入框，见下文更正 |
| 清理 | 已断开本次会话，Runner、预览媒体及观察缓存均确认清理 |

因此，本次修复已验证定位修复和取消本地采集截断；小红书聚焦时替换控件的问题仍然存在。不能用“成功聚焦”代替“成功输入”的结论，也不能将旧路径或 AX 身份自动转移给另一个控件。

后续诊断更正：编辑器并非未暴露给 XCTest。同一个聚焦页面的查询根快照有 179 个节点，包含新的搜索框；公开 `root.snapshot()` 只有 80 个节点。`includingNonModalElements` 未消除差异。只点击、不发送键盘事件也会改变搜索框的 AX 身份。具体对照、接口调用差异及尚未验证的边界见 [搜索页 AX 诊断](runner-search-ax-diagnosis.md)。

## 自动验证

最终实现的 Swift 全量测试：566 项，2 项跳过，0 失败。新增 AX 绑定运行时替身测试通过；带签名的 iPhone Runner 构建、安装和连接通过。Python 88 项与 Node 73 项通过（另 1 项跳过），插件同步检查通过。当前环境未安装 SwiftLint，未声称通过该检查。

## 回归覆盖

- 重复空 identifier/label 的 TextView，跨窗口查询顺序不同仍绑定路径选中的快照。
- 绑定返回另一个属性完全相同的元素时拒绝。
- 路径删除、属性变化、绑定期间的祖先变化和同属性元素替换时拒绝。
- 运行时接口缺失、签名不符、身份为空、结果类型错误和异常均停止，不退回模糊匹配。
- 1201 节点宽树与 501 层深树完整遍历；1201 节点经过解码、缓存、精简输出、inspect 和短 ID 到完整路径解析。

原始截图、AX 树和动作回执仅保存在本机 `/private/tmp/iphone-use-ax-fix/evidence/`，未加入仓库。`identity-binding/` 为聚焦前页面与第 204 个节点的 inspect 结果，`focused-search/` 为实际动作回执及聚焦后页面，`query-binding/` 为开发期间的查询范围差异诊断。

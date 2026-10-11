# 观察、缓存查询与引用

`observe` 采集截图与 AX，宿主生成紧凑文本和会话内引用；`inspect` 读取同一份缓存快照。动作与引用校验见 [动作契约](actions.md)。

## 当前调用

```sh
iphone-use --session "$SESSION" observe
iphone-use --session "$SESSION" inspect o2:e9
iphone-use --session "$SESSION" inspect o2 --query Calendar
iphone-use --session "$SESSION" inspect o2:e9 --query scroll_view
iphone-use --session "$SESSION" inspect o2
iphone-use --session "$SESSION" inspect o2 --offset 20
```

`observe` 成功时直接输出多行文本及 PNG 路径；agent 需要用本地读图能力打开 PNG。`inspect` 成功时输出缓存上下文及按需展开的节点属性。失败仍为单行 JSON，退出码为 1。本地 IPC 保留 JSON 结构，CLI 不把逐节点 JSON 作为默认观察输出。

## 搜索缓存中的目标

`inspect oN --query TEXT` 先搜索该观察的全部已采集节点，再输出最多 20 个匹配项/8 KiB；传元素引用时仅搜索该节点及其已采集子树。查询对原始 label、identifier、value 和 role 做不区分大小写的子串匹配，包含 observe 文本折叠或截短掉的属性。每个来源节点最多匹配一次；同名父子节点和同名控件仍是不同结果，不自动合并或选出唯一目标。

匹配行带有完整 `ref`、`role`、屏幕点 `frame` 和 `parentRef`，并保留源类型、enabled、名称和值。长文本属性显示前 160 个字符并标记 `detail_clipped=true`，匹配本身使用未截短的属性；完整属性可再直接 inspect 返回的元素引用。匹配不意味着元素可见、可点击或仍可操作。

输出头部的 `matched_nodes` 是全部匹配数，`searched_nodes` 是搜索范围内已采集节点数。`--offset` 在查询模式下是**匹配列表**的偏移；继续使用返回的 `more: inspect ... --query ... --offset ...`，该命令保留原始查询。IPC result 同时返回实际采用的 `query`，CLI 核对它；旧宿主若忽略了参数，返回 `inspect_query_unsupported`，需用新 CLI 重新 connect 后 observe，不需要因此重建兼容的 Runner。

- `unexpanded`：默认文本预算未显示完，可以查询或直接展开已知元素。
- `no_matches_in_capture=true`：搜索范围的已缓存数据中没有匹配，不证明界面上没有该目标。
- `source_missing=true`：源采集不完整，查询或 inspect 都无法补取缺失部分；`ax=unavailable` 同样不能支持目标不存在的结论。

查询成功（包括零匹配）沿用 inspect 的续期规则，不请求 Runner、不新增观察 ID、不改变引用资格，也不修改磁盘快照。缓存淘汰后不能继续查询。query 须为 1–256 UTF-8 字节，拒绝控制字符和纯空白，非法值返回 `invalid_inspect_query`；越界偏移返回 `invalid_offset`。未提供 `--query` 时保留原有详细属性和节点分页。

调用方已知引用时应直接 `inspect oN:eN`，不要从整棵树逐页查几何信息；尚未找到目标时用查询。`inspect oN | rg TEXT` 仅搜索那一页输出。若截图已明确显示目标位置，可通过已有的受守卫约束坐标动作继续；不必为找到一个 AX 名称而反复读取无关页。

[完整 CLI 输出样例](examples/observe/observe.cli.example.txt) 来自本次 Calculator 的 o4，未经改写。文件里的临时路径随会话关闭已失效；实验副本在下方证据目录。实际采集的部分正文如下：

```text
[e16] scroll_view "Last Expression"
  [e18] text "‎2‎+‎3"
[e19] scroll_view "Edit field"
  [e22] text "‎5"
[e23] key "Delete"
[e24] key "All Clear"
```

显示为 `[e24]` 的节点，其完整引用是该会话的 `o4:e24`。引用只标识已采集的来源节点，不能据此认定设备目标唯一、可点击或仍在原位置。`refs=current` 只表示它尚未被宿主失效；type/press 执行前校验实时 AX 目标，tap/swipe 执行前校验上下文和分区画面。画面相似不延长引用，见 [动作前画面校验](screen-guard.md)。

## 输出与缓存限制

这些是可调整的工程默认值，沿用已确认的产品语义，不代表用户逐项指定了数值。

- 默认观察最多 60 行、8 KiB；长属性在文本中缩短到 160 个字符并显示 `detail_clipped=true`，原值留在缓存。
- 省略无内容、无状态、无 identifier 的普通容器，折叠重复 WebView 包裹与可确认重复的普通容器表示。保留控件、文字、原始 `ax_value`、禁用状态、命名分组；同名控件不合并，有 identifier 时显示以便区分。
- 不依据控件在屏幕内、enabled 或名字推断可见性/可点击性，不把输入框的 AX value 猜成“已输入内容”。屏幕外的已采集节点仍可能出现在文本中。
- 每个原始节点均有观察内引用，包含默认文本折叠掉的节点；`inspect oN` 可读取它们。引用分配和表示规则都在宿主，Runner 没有观察 ID、短引用或缓存策略。
- 只缓存最近两次成功观察。新观察不会修改旧快照；第三次成功观察删除最早的 PNG 和 JSON。有效会话结束或空闲到期时删除观察缓存，诊断文件保持原有清理策略。
- `inspect` 默认每页最多 20 个节点、8 KiB，`--offset` 是所选已采集子树内的节点偏移，下一页命令随输出返回。单个节点的详细 JSON 超过 4 KiB 时，输出指向完整缓存文件的提示。
- 文本预算未展开的数据标明 `unexpanded`，可继续 inspect。Runner 的源采集仍最多 200 节点；`source_truncated=true` 和 `source_missing=true` 表示原快照没有采集到剩余节点，inspect 不能补取。
- PNG 与保留全部已导出节点属性的 snapshot.json 写入会话目录，文件 0600、目录 0700。JSON 不是完整 XCTest dictionaryRepresentation；缓存文件也不独立证明引用当前有效。

## 引用与生命周期

所有操作在宿主工作队列串行执行。`open` 和通过本地引用解析的设备动作调用后端前先标记当前引用为 pending；正常完成或结果 unknown 后失效。明确未发送且没有其他失效原因的错误恢复此前仍有效的引用，参数检查失败不改变引用；发现目标变化时仍须失效。unknown 不重发。

开始一次新观察会使旧引用失效，即使新采集失败也要求重新 observe；成功后仅最新观察拥有 current 引用。旧快照只要仍在缓存就可 inspect，但不会恢复操作资格。已淘汰的快照返回 `observation_unavailable`；未采集的节点返回 `node_not_captured`；旧 session 无法再 inspect。当前动作已使用这些状态，并从原快照构造设备校验所需的目标描述。

成功的 observe / inspect 完成后续期，失败的 inspect 不续期，status 保持不续期。已接收的操作和关闭仍沿用原有串行化与空闲规则。

## 采集事实与限制

薄 Runner 检查 SpringBoard 是否有唯一 Alert；否则采集已经 open 且确认 runningForeground 的目标 App；前台不能确认时返回截图，AX 标记 unavailable、foreground 标记 null。App 内唯一 Alert 使用独立的 `appAlert` 范围。唯一系统 Alert 的结构属于 SpringBoard，不能把目标 App 当成该系统界面的前台身份。没有独立发现任意前台 App 的能力，也没有自动选择允许/拒绝权限的动作。

AX 开始/结束时间与截图后的时间分别返回；屏幕点坐标框来自采集 App 的 frame，未知时返回 null，PNG 像素尺寸由 Mac 解码图像验证。截图与 AX **不是原子快照，也不保证界面已稳定**。

App 切换动画可能造成截图与 AX 表现不一致，调用 agent 应读取截图并按需重新 observe。通用 App 打开与安装检查见 [设备/App 发现](discovery.md)，签名与协议升级见 [首次接入](onboarding.md)。

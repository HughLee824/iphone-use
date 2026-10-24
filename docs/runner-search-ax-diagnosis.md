# 小红书搜索页 AX 快照与聚焦后身份变化

本文保留修复前的诊断过程。最终通用实现与验收见 [AX 路径验证](runner-ax-path-verification.md)；后续设置搜索收敛问题及三类页面复验见 [输入事务收敛验证](runner-text-convergence-verification.md)。

2026-10-24，iPhone 12 Pro / iOS 27.0.1。使用隔离的诊断 Runner，仅增加快照采集探针，未修改生产输入逻辑。本轮执行返回搜索结果页、点击搜索框的对照；没有发送文字或键盘事件，没有提交搜索。

后续定位已确认遗漏由 `snapshotKeyHonorModalViews` 参数差异决定；并实测区分了“直接读查询缓存”与“重新执行查询”的更新行为。详见本文末尾的第二轮诊断。下文保留第一轮证据及当时的判断边界。

## 已证实的两处问题

### 公开快照漏掉了查询接口能找到的输入框

以下为同一轮观察内依次采集的结果，并非跨页面拼接。探针同时保存截图、完整节点、AX 身份、调用开始与结束时间。两次聚焦页观察均出现相同差异；节点总数因页面内容有 1 个节点的变化。

| 采集接口 | 搜索结果页 | 仅点击搜索框后的编辑页 |
| --- | --- | --- |
| `root.snapshot()`，现有生产采集路径 | 225 节点，2 个 TextView | 80 节点，0 个 TextView |
| `root.query.uniqueMatchingSnapshotWithError:` | 227 节点，2 个 TextView | 179 节点，1 个 TextView |
| `root.query.includingNonModalElements` 的同一底层查询接口 | 227 节点，2 个 TextView | 179 节点，1 个 TextView |
| TextView 查询完成后的 `rootElementSnapshot` | 227 节点 | 179 节点 |
| nonmodal 查询的 `.element.snapshot()`，重新经过公开 API | 225 节点 | 80 节点 |
| 普通 `descendants(matching: .textView)` | 搜索框、摘要共 2 个 | 搜索框 1 个 |

编辑页查询到的 TextView 位于 `(60, 62, 203.67, 22)`，值与截图上的搜索文字相同。其 identifier、label 仍为空。公开快照缺少的是包含输入框的分支，不是宿主精简展示隐藏了短 ID，也不是原来的 200 节点上限导致的截断：查询树总数本身就低于 200。

对比带 AX 身份的 nonmodal 公开快照与查询快照，结果页少 2 个容器；编辑页少 99 个节点，包含查询树索引 18 的搜索框。不能把“完整遍历了 API 返回的树”表述为“取得了 XCTest 能查询到的所有节点”。也不能认定查询树 179 个节点是系统所有 AX 节点的绝对全集。

本机 Xcode 的 XCUIAutomation 二进制进一步显示两条调用链不同：

```text
公开 snapshot()
  snapshotWithError:
  snapshotWithParameters:nil error:
  resolveOrRaiseTestFailure:error:
  standardAttributeNames → axAttributesForSnapshotAttributes:isMacOS:
  query.snapshotForElement:attributes:parameters:timeoutControls:error:
  requestSnapshotForElement:attributes:parameters:error:

查询快照
  query.uniqueMatchingSnapshotWithError:
  _executeWithError:
  matchingElements（唯一匹配时返回该快照）
```

公开 API 传入标准属性集合，进入额外的属性快照请求；该路径的“复用查询缓存”分支要求 attributes 与 parameters 同时为空。第一轮静态实现与真机对照仅确认 API 路径存在差异，当时尚未定位具体参数。第一轮的 `includingNonModalElements` 对照未改变结果，但后续单变量实验确认：查询参数未传入额外的公开快照请求，不能用该对照排除模态过滤。

### 点击搜索框就会更换 AX 身份

从结果页执行一次普通 tap，未发送任何键盘事件：

| 对象 | 点击前 AX 身份后缀 | 点击后 AX 身份后缀 |
| --- | --- | --- |
| 搜索框 TextView | `5862247424.353` | `5948954624.853` |
| 所属页面分支 | `5863155776.337` | `5949713792.863` |

下面为查询快照内的完整路径，`Type[index]` 的 index 是父节点 children 中的零基索引，不是全局同类型序号：

```text
点击前：Application[0]/Window[0]/Other[1]/Other[0]/Other[0]/Other[0]
        /Other[0]/Other[1]/Other[1]/TextView[4]
点击后：Application[0]/Window[0]/Other[1]/Other[0]/Other[0]/Other[0]
        /Other[0]/Other[0]/Other[0]/TextView[4]
```

前面的共同祖先身份保持一致，从页面分支开始替换。即便文字和坐标相同，也不能把点击前的对象当作点击后的对象。该事实无需通过 XCTest 键盘输入触发；不能把本次问题直接归因于此前评论页诊断中的硬件键盘事件。

## 对现有输入流程的影响

`LiveSessionTests+Input.swift` 的 replace/append 流程先解析并绑定目标，再执行 `target.tap()`，随后对同一个 target 调用 `typeKey` / `typeText`。小红书切换编辑页后，该 target 的旧身份已失效，所以先前的 `No matches found for Identity Binding` 与本轮结果一致。完整路径定位解决的是执行开始时的歧义，不会让绑定对象跨页面切换保持有效。

与此同时，后续观察使用公开快照，漏掉新输入框，因此也无法向调用者提供新的输入框短 ID。这两处问题叠加，形成“原目标失效 → 观察又找不到新目标”的阻塞。

## 后续修复方向与未验证项

1. 让观察、执行前路径验证、绑定后的复核使用相同快照来源。先验证查询快照来源的时效性、完整性与兼容性；不能直接将其缓存字段当作新鲜快照。涉及运行时接口时仍需签名检查、错误保留及明确失败。
2. 区分聚焦动作与后续文字输入。聚焦造成页面或目标身份变化时停止使用旧对象，由新观察明确选择新编辑器；不能按相同坐标、名称或 TextView 序号自动迁移目标。
3. 补充“公开快照缺失而查询快照存在”“tap 后身份替换”“来源不同导致路径错位”等回归，并验证已聚焦的新输入框上实际 XCTest 输入的结果。

本轮仅定位，未实现以上后续修改，也未证明新编辑器能完成 XCTest 输入。先前自动化测试结果不等于这两处问题已通过回归。本轮结束后已断开自建连接并确认 Runner、观察缓存、预览媒体清理，已重新安装诊断前的普通 Runner 构建。

原始证据仅保存在本机忽略目录 `.local/xhs-focused-ax-20261024/evidence/`：`02-focused-query-root` 为第一次接口对照，`03-results` 与 `04-focus-tap-only` 为仅点击前后的对照。每份包含 snapshot、截图与原始回执，未将页面私有内容加入仓库。

## 第二轮：模态参数与缓存的受控对照

仍只修改忽略目录中的诊断 Runner。v4 分离属性与参数变量；v5 调整查询顺序，先取得快照对象、再读取节点属性，排除属性延迟加载对缓存实验的干扰。两个签名构建均编译、安装、连接成功。没有运行生产代码回归套件，本轮不是生产修复验收。

### 原因：额外快照请求没有继承查询的模态参数

在运行时读取 App 根查询的 backing query，实际配置为：

```text
snapshotAttributes = []
snapshotParameters = { snapshotKeyHonorModalViews: false }

XCAXClient_iOS.defaultParameters = {
  maxArrayCount: 2147483647,
  maxChildren: 2147483647,
  maxDepth: 2147483647,
  traverseFromParentsToChildren: true
}
```

公开 `snapshotWithError:` 调用 `snapshotWithParameters:nil error:`。该方法先解析元素，再取标准 AX 属性集，调用 `snapshotForElement:attributes:parameters:timeoutControls:error:`，将 nil parameters 继续传给新的请求。静态代码没有从 backing query 取 `snapshotParameters` 传入这一步。查询的 `includingNonModalElements` 设置因此不能单独改变这个额外请求的参数。

保持标准属性集合及页面不变，通过诊断运行时封装调用 `snapshotWithParameters:error:`，只切换一个参数，v5 的编辑页结果如下：

| 参数 | 节点数 | 搜索框 |
| --- | --- | --- |
| nil，公开 `root.snapshot()` 的默认路径 | 80 | 缺失 |
| `{snapshotKeyHonorModalViews: true}` | 80 | 缺失 |
| `{snapshotKeyHonorModalViews: false}` | 179 | 存在，位置和 AX 身份正确 |
| 重新执行 App 根查询 | 179 | 同一搜索框 |

首次打开编辑页时对应数值为 81 / 180，结论相同；返回结果页时为 225 / 227。对三份 v5 证据进行脚本比对，默认树与显式 true 的节点身份、类型、父索引序列完全相同；显式 false 与重新查询的相同序列也完全相同。这不是仅比较节点数量。

另用相同 AX 根身份直接调用 `XCAXClient_iOS.requestSnapshotForElement:attributes:parameters:error:`，绕开查询缓存复用分支：标准属性或空属性配默认参数均返回 80 节点；两种属性配 false 参数均返回 179 节点。空属性直接请求的 frame 为零，标准属性请求则有正确 frame；因此“取得结构”与“取得可用于定位的属性”不能混为一谈。

这些单变量对照将本案例的节点遗漏定位到 **AX 快照请求的模态过滤行为**，而非标准属性集、200 节点限制或旧查询缓存。仍未确定小红书哪一个原生视图或 AX 标记触发了模态范围，不能仅凭截图认定是 “Hold to askDots” 浮层。false 允许采集过滤范围外的节点，不表示这些节点一定可点击或可输入，执行侧仍需目标及页面校验。

### 树 B 的更新：缓存 getter 会过期，重新执行查询在本次切换中更新

v5 保留同一个 `XCUIElementQuery`，在下一次页面切换后按以下顺序执行：

1. 读取旧 `rootElementSnapshot` 对象，但不遍历或读取节点属性。
2. 对保留的同一个 query 调用 `uniqueMatchingSnapshotWithError:`。
3. 立即再次调用该方法，中间不读取节点属性。
4. 读取更新后的 `rootElementSnapshot` 对象。
5. 最后才遍历以上对象，记录节点身份、结构与属性。

| 页面变化 | 直接读取旧缓存 | 同一 query 重新执行 | 立即再次执行 |
| --- | --- | --- | --- |
| 编辑页 → 结果页 | 180 节点，仍含旧编辑框 `…1017` | 227 节点，结果页搜索框 `…353` 和摘要 `…542` | 227，当前页面 |
| 结果页 → 编辑页 | 227 节点，仍含结果页框 `…353` 和摘要 | 179 节点，新编辑框 `…1181` | 179，当前页面 |

直接读缓存耗时约几十微秒，返回前一次查询的对象；重新执行查询约 70–90 ms，得到不同快照对象并更新 query 的缓存。第二次切换中重新执行的 generation 为 10764，立即再次执行为 10765；取得这些对象前没有遍历节点。对象地址与 generation 仅作诊断证据，不作为未来实现中的持久目标身份或新鲜度协议。

保留上一轮返回的快照对象也不会让其树结构自动更新；即便 query 后来执行过，它仍保存旧结构。脚本已验证旧缓存等于前次 finalExecute 的身份/父子结构序列，而重新查询后的序列等于新页面的直接参数化快照。

结论必须限定：**本次双向切换未发现重新执行树 B 查询仍返回旧页面；直接读 `rootElementSnapshot` 和复用旧快照则确实会过期。** 尚未覆盖用户触摸触发的异步变化、查询与发送事件间的竞态或其他系统版本，不能将内部接口描述为绝对无缓存、始终新鲜。快照属性存在延迟取值，也不应假定结构与所有属性永远是同一原子时刻的数据。

### 对后续修复选择的影响

不必仅为补齐本例节点就全面改用树 B。可以优先评估通过受控运行时封装请求“标准属性 + `snapshotKeyHonorModalViews=false`”的显式快照，并在观察和执行校验中保持同一来源与参数；这条路径已在本例恢复与树 B 相同的结构及正确属性。但接口兼容性、模态页面目标可操作性、聚焦后身份替换仍需要单独验证，不能在本轮定位结论中视为已经修复。

第二轮证据位于同一忽略目录下的 `05-deep-focused`、`06-deep-results`、`07-deep-refocused`，以及消除属性读取顺序干扰后的 `08-ordered-focused`、`09-ordered-results`、`10-ordered-refocused`。两次自建会话均已断开，确认 Runner 退出、观察缓存移除、预览媒体释放。

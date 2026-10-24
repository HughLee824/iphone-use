# 设置搜索输入后 unknown 的诊断

2026-10-24，iPhone 12 Pro / iOS 27.0.1。此次仅在 `.local/settings-ax-diagnosis/source/` 的独立 Runner 副本增加诊断，不改变生产代码或成功判定条件。

## 结论

输入已执行一次，末尾验证碰到了真实的键盘与搜索栏布局过渡。路径和 AX 身份没有改变，但搜索栏暂时落到屏幕底部，严格的 frame 比较失败，导致 `target_changed` / `unknown`。连续截图确认键盘短暂消失再出现，因此不能把这次失败归因于单纯 AX 返回旧坐标。

这也不等于已证明 Apple 内部为何收起再恢复键盘：当前实验确定了动作后的实际过渡，以及 Runner 在过渡期过早拒绝的代码路径；没有区分是 XCTest 键盘事件实现还是设置 App 自身响应触发了过渡。

## 可复现证据

两次独立实验分别从空的、已有键盘焦点的设置搜索框插入 `AXProbe1024` 和 `AXProbe1024B`，均复现。每次只发送一次插入，没有在 unknown 后重放。第一次只记录失败节点，第二次在失败处增加截图及三次只读新快照。

第二次回执：

```json
{
  "outcome": "unknown",
  "error": "target_changed",
  "stage": "verifying_result",
  "focusAttempted": false,
  "keyboardEventsAttempted": 1,
  "insertionAttempted": true,
  "insertionAcknowledged": true,
  "automaticReplayAllowed": false
}
```

失败发生在末尾校验的第一次新根快照，尚未进入绑定目标后的叶节点和第二次根快照检查。路径共有 20 层（根为 depth 0），逐层审计显示所有 AX 身份相等、原 childIndex 路径仍有效。最先失败的是 depth 16 的匿名容器；depth 16–19 的 frame 发生变化，目标 leaf 的值按预期变成完整的 `AXProbe1024B`。其他路径属性没有差异。

| 节点 | 输入前 frame (x,y,width,height)，单位 pt | 失败时 frame |
| --- | --- | --- |
| depth 16、17：容器 | (8,485,314,48) | (28,768,274,48) |
| depth 18：容器；19：Search 输入框 | (8,495,314,28) | (28,778,274,28) |

以下时间以失败根快照完成时为零点（Unix 1792810221.012762）。快照与截图顺序采集，非原子同步；表中明确区分其时间。

| 阶段 | 根快照完成 | 输入框 AX frame | 截图完成 | 实际截图 |
| --- | --- | --- | --- | --- |
| 失败快照 / sample 0 | 0 ms | (28,778,274,28) | +141 ms | 键盘不可见，搜索栏位于底部，完整文本已显示 |
| sample 1 | +275 ms | (28,778,274,28) | +436 ms | 键盘仍不可见，搜索栏仍在底部，光标可见 |
| sample 2 | +550 ms | (25.147,737.636,279.705,28) | +681 ms | 过渡中的中间采样，文件保留供检查 |
| sample 3 | +760 ms | (8.082,496.164,314,28) | +876 ms | 键盘已出现，搜索栏回到上方 |
| 后续 observe | +3129 ms | (8,495,314,28) | +3683 ms | 文本完整、键盘显示正常 |

sample 1 的 keyboard AX y=861，超出屏幕高度 844；sample 2、3 的 keyboard y=560。三次后续快照中路径身份仍全部相等，文本仍是 `AXProbe1024B`。这个序列展示了新快照中的中间几何状态，不支持“始终返回同一份过期整树”的解释。它不构成对所有平台缓存行为的保证。

## 代码链路

1. `Sources/IPhoneUseCore/RunnerTextTransaction.swift` 在 `sendText` 返回后设 `insertionAcknowledged=true`，随后立即进入 `verifying_result` 并调用 `validate(true)`。
2. `Runner/LiveSessionTests+Input.swift` 的 `actionTarget` 重新采集完整根快照并逐层验证。允许自身文本修改只影响目标叶节点 label/value；frame 仍逐分量要求误差不超过 0.5 pt。
3. depth 16 身份相同，但 frame 偏差远超阈值，`RunnerAXTree.resolve` 抛出 `target_changed`。异常中止事务，未重新发送文本。
4. `Runner/LiveSessionTests+Commands.swift` 的 `waitForStableFrame()` 位于 `perform(command)` 成功返回之后。末尾验证在 `perform` 内已经抛出，所以这段等待不会执行，也无法帮助本次末尾 AX 验证。
5. 输入已经开始而事务没有完成，因此返回 unknown；`insertionAcknowledged=true` 保留实际执行事实，不能把 unknown 当作“没有输入”。

## 当时的修复方向

后续已实现并完成设置、普通表单和小红书验证，见 [输入事务收敛验证](runner-text-convergence-verification.md)。以下保留诊断时的判断。

把输入后的只读收敛验证放在事务内部，发生在报告最终成功之前。对于身份、路径及关键属性仍一致、仅几何处于过渡的情况，可以在有界时间内重新采集，等待完整校验通过；不重新输入、不重新聚焦、不换目标，也不直接删除 frame 校验。身份消失、路径改变或其他关键属性变化仍停止。超时仍保留部分执行事实并返回不确定结果。

采样三次时最后一个 AX y 仍比基准多 1.164 pt，已经超过现有 0.5 pt 阈值，因此不能依据本次数据随意固定一个很短的等待时间，或宣称某个等待次数必定解决。

## 产物与清理

本机证据：`.local/settings-ax-diagnosis/evidence/`，未加入版本控制。

- `01-settings-empty`、`02-settings-insert-failure`、`03-settings-cleared`：第一次复现。
- `04-timed-baseline`、`05-timed-failure`、`06-timed-cleared`：连续采样实验。`05` 内保存完整 response.json、最终 snapshot.json / screen.png 和 sample-0.png 至 sample-3.png。
- 两次测试文字均通过清除按钮清空；自建连接断开，Runner、媒体及观察缓存清理确认保存在上级 `final-cleanup.json`。
- 诊断结束后重新安装诊断前的生产 Runner 构建 `.build/runner/6af573bb-801c-4540-89e9-1da3e7d29ee8/`，不保留诊断 Runner 作为日常执行版本。

两个诊断版均完成签名构建、安装及真机运行。此次没有生产逻辑变更，不将上一轮全量测试结果冒充为本轮重新执行的结果。

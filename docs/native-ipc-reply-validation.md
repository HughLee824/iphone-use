# 本地回执丢失：原因与验证

2026-10-03，继光标局部排除真机验证之后。原始证据为 `.local/research/caret-mask-device-20261003/append-host.json` 与 `append.receipt.json`：宿主完成一次追加、生成 o5 及事务 ID，客户端却收到 `session_unavailable / POSIXErrorCode 50: Network is down`。后续 o6、o7 截图确认实际全文正确，剪贴板恢复成功。没有重放输入。

## 根因

`JSONServer` 通过 Network.framework 在本机 Unix socket 返回 JSON。旧实现收到发送的 `.contentProcessed` 回调就立刻 `connection.cancel()`；该回调不代表客户端已读完。本机探针用原始追加回执复现了这一关闭时序导致的回执丢失。此复现完全不连接手机，也不需要媒体、HID、Device Hub 或互联网。

每组 30 个独立请求，分别在原始回执上增加 0、4096、65536、262144 字节字符串，结果如下。请求数始终为 120，没有客户端重试：

| 服务端实现 | 原始回执 | +4 KiB | +64 KiB | +256 KiB |
|---|---:|---:|---:|---:|
| 旧版发送回调后立即取消 | 27 次失败 | 27 次失败 | 30 次失败 | 30 次失败 |
| 仅增加 finalMessage，仍立即取消 | 24 次失败 | 28 次失败 | 30 次失败 | 30 次失败 |
| finalMessage，并等待客户端关闭 | 0 次失败 | 0 次失败 | 0 次失败 | 0 次失败 |

所有旧版失败均为同一个 ENETDOWN 文本。正式修复代码再次重放同一矩阵，120 次全部通过。这将问题定位于本地回执连接的提前取消，不能把错误字面解释为手机网络断开。不是通过缩短回执、隐藏诊断或延迟固定毫秒数规避问题。

## 修复

服务端将本条回执标记为最后消息；发送本地处理完成后等待客户端关闭，再释放连接并执行完成回调。现有客户端在收到完整 JSON 行时关闭连接。收尾最多五秒，遇到发送失败、对端关闭或截止时间均只完成一次；期间收到额外数据只丢弃，不执行第二个请求。

客户端请求 ID／session 核对、回执大小限制、请求时限和不重放策略不变。真实超时、丢失回执和错误 ID 仍为不确定结果；正常 HID 回执仍为 `unknown/native_input_unacknowledged`，必须查看截图核对实际输入，不改成虚假的 `completed`。

## 验证状态

新增三个宿主回归已通过：40 次含 Unicode 的大回执完整返回（包括跨 64 KiB 分块与嵌套观察）；客户端不关闭时有界释放且完成回调一次；真正无回复和错误 ID 保持不确定、不重发。完整 Swift 宿主测试共 383 项，1 项既有可选检查跳过，0 失败；其中包含两种模式的宿主动作、断开和清理测试。Release CLI 构建和 `git diff --check` 均通过。本次没有修改设备端 Runner，也未重新安装或启动它。

用户解锁后，使用修复提交 `4cbb31d` 的 Release 构建完成一次标准模式 Probe 真机验证，`controlAvailable=true`、`runnerStarted=false`：

- 只执行一次替换 `回执验证🙂完成`，截图确认输入框和完整回显均正确，Edits 从 6 增至 7；没有重放输入。
- 输入命令含校验、剪贴板暂用和结果截图耗时 3.215 秒。源观察年龄 25.698 秒，三个输入前采样通过像素匹配。这是单次样本，不是延迟分位数或本轮时序光标路径覆盖。
- 客户端完整接收宿主的原始 o3，没有异常后补采 o4；逐项核对请求 ID、完整 result、附带 observation 和 error，均与宿主日志一致。没有 `session_unavailable` 或 ENETDOWN。保留正常的 `unknown/native_input_unacknowledged` 语义，并以实际截图确认输入。
- `text-finish` 正常恢复剪贴板并返回 o4；断开回执正常返回，确认自有媒体停止、键盘移除、连接关闭和缓存清理。另行核实宿主已退出、IPC socket 与观察缓存不存在。

本轮真机回执链路验证通过。原始大回执和跨分块回执的覆盖来自前述本机重放与宿主回归；单次真机验证不代表跨 App、长时间稳定性或新的短上下文验收已完成。未启动新会话任务，未重打候选包。

本地证据：`.local/research/ipc-reply-20261003/`，含独立自写探针、`before.log`、`final-message.log`、`drain.log`、正式修复 `after.log` 和测试构建日志；`device/` 下保存真机截图、原始回执、`reply-verification.json`、`cleanup-verified.json`。没有运行第三方设备工具，没有推送或发布。

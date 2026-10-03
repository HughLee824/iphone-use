# 光标与回执修复 `.9` 候选包

2026-10-03。本地候选包 `0.1.0-dev.firstuse.20261003.9` 已构建并通过宿主归档验证。随后独立短上下文验收完成替换、追加和清理，但首次输入仍有字段保护拒绝，不能宣称误拒绝已消除或效率目标全部达成。未发布、推送、创建 tag、覆盖旧包或更改已安装插件。

## 固定构建

- 源提交 `742afcaf9632900382135079eaeea9db2bc81de6`，构建前后均为干净源码。
- 包含 `439be17` 的光标局部排除及字段媒体噪声比较、`4cbb31d` 的本地回执连接收尾修复。
- 归档 `.local/research/caret-ipc-candidate-20261003/package/iphone-use-0.1.0-dev.firstuse.20261003.9-macos-arm64.tar.gz`。
- SHA-256 `79e5d6eddad24ddee6b0a0e766b381b30ad6a1e341491b4ecf69571aef7f1cdb`。
- Runner 内容版本 `d92545213b0feaf5b53ab84ef1fe44ecc0852523139202ed4d5a9747caac65a0`。
- CLI 为本地 ad-hoc 签名，未公证；包内 Runner 为无签名载荷。

配套 Skill 从同一源码归档，插件版本仍为 `0.1.4`，SHA-256 为 `f725c3f238bf3997376af1529298934923b4c73b264605b0bb784f2f0a09605c`。Skill 内容没有变化，不将重新归档描述成新插件发布。

## 已完成验证

`build-release.py --require-clean` 完成 Release CLI 和隔离无签名 Runner 构建。`verify-release.py --require-clean` 通过 SHA、归档路径、清单、签名、许可证、源码路径泄漏和系统动态依赖检查，并实际运行含空格路径搬移、符号链接和兼容命令入口、版本、帮助及隔离模式配置读写。工具的 `deviceVerified=false` 保留原义。

另外在 `/private/tmp/iphone-use .9 acceptance …/` 保留独立解压的 CLI 与配套 Skill，运行 `preflight.sh --candidate`，确认 `.9` 版本及 `--observe`、`--agent-output`、模式选择能力。验收配置目录与预检查目录分离，待验收偏好未初始化。没有修改用户的默认模式配置。

打包前源码的完整宿主测试 383 项、1 项既有跳过、0 失败；真实失败回执在修复后本机重放 120 次全部通过。源码 Release 的 Probe 替换／追加、剪贴板恢复和回执完整性真机证据分别见[光标验证](native-text-caret-mask-validation.md)与[回执验证](native-ipc-reply-validation.md)。它们不替代本包独立验收，不代表短上下文效率已通过。

## 短上下文验收准备

固定 CLI、工作目录、隔离偏好和配套 Skill 的 `context.json`，以及可直接用于新会话的 `trial-prompt.txt` 已保存在 `.local/research/caret-ipc-candidate-20261003/`。只在普通 Text Probe 中替换为 `第九版短上下文🙂`，追加 `；追加完成✅`；使用每个动作附带的观察，未知结果不重放，临时剪贴板备份失败则停止。该目标不同于当前留存正文，可防止把已有文字误认为本次成功。

验收要求分别记录观察与输入次数、实际派发、视觉结果、剪贴板恢复、资源清理和端到端耗时；不刻意等待，不把单条 CLI 耗时当成 Agent 效率。源图和回执及时保存，避免缓存淘汰。

## 独立验收结果

用户明确授权后创建会话 `01a10099-20b0-72e1-b90e-aac4c8fdfff4`，标题“验收 .9 候选包文字操作效率”。该会话已结束，父会话读取执行记录并独立查看最终 PNG：输入框与 Received 全文均为 `第九版短上下文🙂；追加完成✅`，编辑计数 7→8→9。使用固定搬移包、隔离偏好和 standard，`runnerStarted=false`。

- 返回观察 7 次，键盘准备一次，无额外 observe 命令。type 尝试三次：一次 `not_dispatched`，两次实际派发后为 `unknown/native_input_unacknowledged`。没有重放 unknown，没有提高容差或扩大排除范围。
- 第一次 replace 的源观察仅 15.488 秒；六帧采样后在写剪贴板前拒绝，检查耗时 2.957 秒且 `inTime=true`。全屏变化 0.1003% 低于 1%，字段比较仍失败。既不是 30 秒有效期，也不是前置校验超时。原图 o2 和拒绝图 o3 均保留；可见正文及编辑数未变，但不能仅凭两张最终图断言六帧失败的精确像素原因。
- Agent 复用拒绝观察 o3 作一次新判断，完整字段框 `18,209,354,160`、视频框 `18,89,177,60` 与默认阈值不变，随后 replace 成功。append 的剪贴板写入前实际通过时序光标排除，写入后直接像素匹配。没有回执接收异常或 `session_unavailable`。
- 两次 text-finish 确认恢复，断开确认自有媒体停止、键盘移除、连接释放；父会话检查宿主进程已退出，IPC socket 与观察缓存不存在。

**耗时口径：** 工具提供的完整会话首轮耗时为 275.743 秒（约 4 分 36 秒，含准备、调用间隔及最终报告）。子会话自行记录的开始至断开为 223.392 秒（约 3 分 43 秒），其开始时间晚于工具记录的 turn 开始，不能代替完整会话耗时。工具可见命令耗时合计约 31.965 秒；其中首次沙盒设备发现超时 15.850 秒，一次获准宿主只读发现后恢复。成功 replace／append 命令为 3.385／4.727 秒，首次拒绝 2.955 秒。工具记录存在零毫秒取整，命令合计不是精确性能剖析。

结论：本包已完成一次独立文字工作流，回执错误没有复现，结果与资源清理可核验；首次字段误拒绝样本及 Agent 命令间开销仍需处理。不能以本轮成功掩盖仍存在的保护拒绝，也不能宣称达到 2–3 分钟目标。原始 summary 不改写，父会话补充 `parent-timing.json` 和 `parent-cleanup.json` 保留不同计时口径。

证据目录 `.local/research/caret-ipc-candidate-20261003/`，包含 `build.json`、`verification.json`、`preflight.log`、归档和上述验收材料。计划的独立运行证据目录为 `.local/research/caret-ipc-short-context-20261003/`。

# 原生文字修复 `.6` 候选包验收

2026-10-02。本地候选 `0.1.0-dev.firstuse.20261002.6` 已构建并通过归档及标准模式接入检查。随后独立短上下文会话完成 Probe 文字替换/追加，功能通过；存在一次全屏保护拒绝，整体效率仍不理想。未发布、推送、创建 tag 或替换旧归档。

## 包与构建

- 源提交：`308a0610673321c834bea514e6d2761c73ec6966`，`sourceDirty=false`，包含 `55ebbf9` 的[光标周期匹配修复](native-text-phase-matching.md)。
- 归档：`.local/research/text-phase-candidate-20261002/package-final/iphone-use-0.1.0-dev.firstuse.20261002.6-macos-arm64.tar.gz`。
- SHA-256：`2a36fb3fdeae0bed7dee5b6e29e43ab46749a20a5c2df75bc8990847d43a0ee3`。
- Runner 内容版本：`f9e078fa0b3aeefe60be15dcd3dcb17334bc530160aceb40368da7a79ae0de5d`。
- CLI 为 ad-hoc 签名，未公证；Runner 为包内无签名载荷。

首次打包在 Runner 编译时发现共享 `ScreenGuard.swift` 引用了原生专用 `NativeTextPhaseMatcher`。将适配方法原样搬到原生文件的 extension 后，两条编译路径恢复独立；没有让 Runner 引入原生控制模块。失败日志保留在 `package/`，成功产物另存于 `package-final/`，没有覆盖失败证据。

原功能修复已执行完整宿主套件 362 项、1 项既有跳过、0 失败。本轮适配方法搬移后执行相关 24 项测试，全部通过；打包测试 18 项通过；Release CLI 和无签名 Runner 构建通过。未重复无关完整套件。

`verify-release.py --require-clean` 已实际执行归档与 SHA、带空格目录搬移/符号链接、版本与帮助、隔离配置读写、两种 mode 偏好、链接依赖及签名检查。工具自身 `deviceVerified=false` 保留原义；真机证据单列于下文。

## 包内标准模式接入

在源码目录外的 `/private/tmp/iphone-use .6 acceptance …/` 解压完整归档，使用其中 CLI、独立工作目录及隔离偏好。实际环境重新读取为 macOS 27.0 (26A428)、Xcode 27.0 (27A266a)；Apple 动态发现唯一有线实体 iPhone 12 Pro / iOS 27.0 (24A437)。没有把设备标识写入产品或报告。

`connect --mode standard → observe → disconnect` 通过：`controlAvailable=true`、`runnerStarted=false`；实际打开返回的 PNG，确认前台仍为普通 Text Probe。没有发送手势或文字，也没有访问剪贴板。退出确认自有媒体停止、连接关闭、隧道释放；独立核对宿主退出、socket 与观察缓存删除。本轮没有 Runner 真机验证。

旧 `.5` 归档 SHA-256 仍为 `37a1f041be51019c81033054c1976c189d054eefd52d2cf7a732004bafd6804f`，未覆盖。

## 短上下文验收状态

已准备独立会话提示与包路径配置：`.local/research/text-phase-candidate-20261002/trial-prompt.txt`、`context.json`。目标仅为 Probe 中替换 `短上下文测试🙂`，追加 `；追加成功✅`，核对完整正文，并单列一次 35 秒等待以覆盖旧的观察有效期问题。记录观察数、输入尝试/派发数、拒绝原因、耗时、周期匹配及清理事实。

首次创建独立任务被自动审批拒绝；用户明确授权后，创建了不继承历史的独立会话执行本任务。新会话使用同一搬移包及独立偏好。主会话随后独立查看最终 PNG，确认输入框和 `Received (complete)` 均为 `短上下文测试🙂；追加成功✅`。

- 3 次 type 尝试，2 次实际派发（replace、append），1 次 `not_dispatched`；没有重放 unknown 输入。
- 成功 replace 的来源观察年龄 32.001 秒，append 为 34.115 秒，均通过派发前复核。旧的 30 秒失效循环未复现。
- 首次 replace 的观察年龄 95.038 秒，字段像素匹配，但排除后的全屏变化 1.4946% 超过默认 1%，在剪贴板准备前拒绝。这不是观察过期或光标匹配失败。
- 首次排除框为 `18,80,335,70`；后续使用新观察和 `0,75,390,95` 后成功。后者覆盖整条横带，包含静态控件，不能表述成仅覆盖视频；且比较基准也已改变，不能只凭成功推断首次拒绝的精确根因。默认容差与字段框参数 `18,209,352,161` 保持不变。另经 Probe 布局核对：屏幕宽 390 点、左右各 18 点边距，字段实际宽 354 点；该框右沿少覆盖约 2 点。本轮可以确认输入结果，但不能作为 Agent 已准确选择完整字段范围的验收证据。
- 本轮成功输入均为 `fieldPixelsMatch=true`、`fieldTemporalMatch=false`，没有触发周期重建分支；该分支的真机证据仍来自[此前源码验收](native-text-phase-matching.md)。
- 共 9 张观察截图，包含准备、拒绝时新图、两次输入及恢复后截图。两次 `text-finish` 均确认恢复；退出确认自有键盘移除、媒体停止、连接和隧道关闭。主会话另查宿主已退出、socket 与观察缓存已删除。

**耗时必须区分口径：** 独立会话从开始到最终答复为 737.675 秒（12 分 18 秒）；其首条记录命令至断开为 557 秒（9 分 17 秒），其中刻意等待 35.005 秒。后者扣除等待仍约 8 分 42 秒，不能据此宣称效率问题已解决。两条成功 type 命令各约 3 秒；可记录命令合计约 40 秒，多数时间戳仅精确到秒，一次宿主设备查询只有工具耗时，不能作为精确性能基准。大量时间位于命令之间及记录整理阶段。

准备阶段有无效 `devices --config` 参数、一次沙盒设备查询超时后经授权使用宿主查询；退出时有一次命令路径笔误（未启动进程）后更正成功。还存在多次帮助读取、显式观察和再次 `text-prepare`，说明后续应改善 Agent 调用流程和排除区域的使用体验，而不是继续归因于文字输入的 30 秒有效期。

短上下文原始报告、摘要、最终截图和父会话复核：`.local/research/text-phase-short-context-20261002/`。原始报告保留不改；这里补充独立会话总时长、排除横带范围及因果判断的限制。

证据目录：`.local/research/text-phase-candidate-20261002/`。截图、设备标识及原始回执仅保留本地，不提交仓库。

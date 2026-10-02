# 原生文字修复 `.6` 候选包验收

2026-10-02。本地候选 `0.1.0-dev.firstuse.20261002.6` 已构建并通过归档及标准模式接入检查。短上下文文字替换/追加验收尚未执行，不能把接入通过当作该流程通过。未发布、推送、创建 tag 或替换旧归档。

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

自动审批拒绝创建独立任务，原因是当前“继续”未被视为明确授权跨会话的真机输入与剪贴板操作。已请求明确确认；尚未创建新会话，也未执行这一轮输入。该阻塞不属于 Apple 设备权限或媒体占用。

证据目录：`.local/research/text-phase-candidate-20261002/`。截图、设备标识及原始回执仅保留本地，不提交仓库。

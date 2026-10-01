# 朋友圈截图修复候选包验收

2026-10-01。本地候选 `0.1.0-dev.firstuse.20261001.3` 包含[朋友圈媒体几何修复](wechat-media-geometry-repair.md)。旧 `.2` 归档保留不变；没有发布、推送、创建 tag 或更新插件。

## 固定身份

- 源提交：`d13c51a22a6da900940d2ec17ebae079aada764e`，`sourceDirty=false`。
- 归档：`iphone-use-0.1.0-dev.firstuse.20261001.3-macos-arm64.tar.gz`。
- SHA-256：`53c6312497358f502bdc3dc51b14d9b56383aa0451c5e5fce5fd0a950a9232e0`。
- Runner 摘要：`c50a7d9dc8930320716ec1c02261813713f3b230bec8cef68c71d2677cb571e6`，与 `.2` 相同。
- 位置：`.local/research/wechat-candidate-20261001/package/`。

CLI 为 ad-hoc 签名、未公证；包内 Runner 无开发签名。源码修复的完整宿主测试和 1,216 帧离线回放见上方修复记录，本轮未修改产品代码。

## 归档与接入

`build-release.py --require-clean` 构建 Release CLI 与隔离的 unsigned Runner，构建前后确认干净提交。`verify-release.py --require-clean` 通过校验和、清单、签名、源码路径泄漏、许可证、系统动态依赖、含空格路径搬移、软链接及兼容命令入口、隔离模式读写检查。

另从最终归档解压到源码外 `/private/tmp` 含空格目录，通过软链接执行包内 CLI。隔离配置全新，默认 `standard/default/saved:false`，未写用户偏好。实际 `--version` 为上述 `.3`。Apple 重新发现有线 iPhone 12 Pro / iOS 27.0（24A437），锁屏检查允许继续。

先省略 mode 连接 standard，返回默认标准模式、`controlAvailable=true`、`runnerStarted=false`；有效观察来自 `native_media`，1170×2532、`rot0`，包含新矩形匹配证据。关闭后显式连接 runner，复用包外合法签名准备，无需重新 setup 或传源码 `.xctestrun`，通过原生 CoreDevice 通道取得 XCTest 截图。

这两张图实际分别显示另一款 App 的设置页与套餐页，未处于朋友圈。验收脚本只调用 config、version、connect、observe、status、disconnect，没有触控或导航命令；不对页面变化来源作未经证实的判断，也不据这组截图声称朋友圈故障已经由归档复测。Runner 未绑定目标应用，AX 为 `foreground_app_unknown`，不能把截图成功当作元素读取成功。

两种自有会话均显式关闭。标准模式媒体停止、隧道释放、shutdown 确认；Runner shutdown 确认，xcodebuild 正常退出、`forced:false`。独立检查宿主进程、xcodebuild、socket 与观察缓存清理完成。包内逐文件摘要前后相同。连接后隔离配置为 `standard/configuration/saved:true`，显式 Runner 连接未改变标准模式偏好；未写入用户原有配置。未启动手势、文本、录屏或社交操作。

## 原故障页面的归档复测

用户手动返回朋友圈后，仍使用上述搬移目录中的 `.3` 包、隔离配置和标准模式，连续采集两张媒体观察，再采集独立 Apple PNG。两张均为有效 `native_media`，1170×2532、`rot0`，几何验证为 `frame_native_rectangle_matches_display`。完整 capture 时间分别约 833 ms、768 ms，只代表本次两个样本。

三张图已目视核对，均为同一朋友圈页面，图片、文字及方向一致，未见碎块残影；不声称有损帧与 Apple PNG 逐像素相同。状态快照累计解码 117 帧，解码错误、参考链重置、丢弃、不连续、畸形包、队列溢出及时间戳拒绝均为 0。全程没有点赞、滚动、输入、剪贴板访问或设置变更，原社交任务仍未完成。

本次会话的自有媒体停止、隧道释放和 shutdown 均确认；独立复查宿主进程、socket、观察缓存已消失。复验后的包内散列仍与解压初始值相同。证据保存在 `moments/`，与最初其他 App 的接入截图分开记录；`summary.json` 和 `evidence.sha256` 固定本次验收事实与散列。

下一轮试用固定使用此 `.3` 归档，或其原样解压目录中的 `bin/iphone-use`，不要使用仍含旧校验的 `.2`、系统 PATH 中的未知版本或开发构建路径代替它。标准模式不需要 setup；使用 `--mode standard` 可避免用户已有偏好的影响。

## 私有证据

`.local/research/wechat-candidate-20261001/` 保存归档验证、搬移上下文、两种模式截图与快照、状态、清理事实及包前后散列。设备标识、私人原图和签名资料不提交仓库。归档检查工具的 `deviceVerified:false` 只说明工具本身不执行真机测试，不能替代这里单独保存的设备证据。

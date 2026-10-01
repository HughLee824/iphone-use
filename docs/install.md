# iPhone-use 发布包安装

> 本指南对应尚未发布的 iPhone-use 源码及本地候选包。新仓库、Homebrew 和插件渠道尚未发布；旧 AgentSoma 安装包不会因本说明而获得标准模式。渠道命令仅描述后续目标，见改名说明。


iPhone-use 为外部 agent 提供真实 iPhone 的观察和操作能力。本包同时提供标准模式（截图 + 原生 HID）与 Runner 模式（XCTest）。普通用户先用标准模式，无需 Runner 签名或 setup；配套预编译 iOS Runner 供选择 Runner 模式的开发者在本机重签，不编译源码。

本文也作为候选包内的独立 README；下方包含首次连接与观察步骤。延伸文档位于源码仓库的 `docs/`，未随安装包提供。外部 Agent 插件为可选接入，首次 CLI 操作不依赖插件；接入方法见源码仓库的 `docs/first-task.md` 和 `docs/plugins.md`。

## 前置条件

- 完整 Xcode，已选为当前开发工具链。
- USB 连接且已信任 Mac 的 iPhone，开启 Developer Mode 并保持解锁。
- **标准模式**：当前适配器要求 macOS 27 / iOS 27，已测 Apple Silicon、Xcode 27 和 iPhone 12 Pro；不需要开发签名。
- **仅 Runner 模式**：Keychain 中可用的 Apple Development 证书及对应私钥，以及授权该证书、iPhone 和 Runner bundle ID 的 iOS development profile。

旧名称 AgentSoma 的 `0.1.0` 正式包实测组合为 Apple Silicon / macOS 15.0.1 / Xcode 16.0 / iPhone 12 Pro / iOS 26.6.1，使用已有付费开发团队的签名。免费 Personal Team 的首次配置与续签尚未验收。

## 当前入口：本地候选包

从候选包提供者取得同一版本的 `.tar.gz` 和 `.tar.gz.sha256`，将两者放在一个新的空目录，在该目录运行下面的校验及解压。版本号必须来自实际收到的文件名，不能使用旧 AgentSoma `0.1.0` 推断新包版本：

```sh
IPHONE_USE_VERSION='VERSION_FROM_SUPPLIED_FILENAME'
IPHONE_USE_PACKAGE="iphone-use-${IPHONE_USE_VERSION}-macos-arm64"
(
  set -e
  test ! -e "$IPHONE_USE_PACKAGE"
  shasum -a 256 -c "${IPHONE_USE_PACKAGE}.tar.gz.sha256"
  tar -xzf "${IPHONE_USE_PACKAGE}.tar.gz"
)
```

仅在校验显示 `OK` 且解压成功后继续。校验失败时向提供者重新取得文件，不运行包中的文件。GitHub 自动生成的 Source code 压缩包是源码，不是这里的预编译安装包。

可以将解压后的完整目录放在任意位置，把其中的 `bin` 加入 PATH。下面使用用户目录，安装前确保目标版本目录尚不存在：

```sh
IPHONE_USE_DEST="$HOME/.local/share/iphone-use/releases/$IPHONE_USE_VERSION"
(
  set -e
  test ! -e "$IPHONE_USE_DEST"
  mkdir -p "$HOME/.local/share/iphone-use/releases" "$HOME/.local/bin"
  mv "$IPHONE_USE_PACKAGE" "$IPHONE_USE_DEST"
  ln -sfn "$IPHONE_USE_DEST/bin/iphone-use" "$HOME/.local/bin/iphone-use"
)
export PATH="$HOME/.local/bin:$PATH"
iphone-use --version
```

把 `export PATH="$HOME/.local/bin:$PATH"` 加到 shell 配置（zsh 通常为 `~/.zshrc`），以便新终端使用。切换 Homebrew 与手动安装时，用 `command -v iphone-use` 核对实际入口。必须保留整个包的 `bin` 与 `libexec` 相对位置，不能只复制一个可执行文件。

包内包含项目 MIT 许可证、Swift ArgumentParser 许可证及版本/源码提交信息。当前 Mac CLI 使用 ad-hoc 签名，未做 Developer ID 签名或公证。此前候选的搬移及设备验收见源码仓库的 `docs/media-candidate-acceptance.md` 和 `docs/runner-candidate-acceptance.md`；以报告中的版本和摘要为准。旧 AgentSoma `0.1.0` 的终端下载和 Homebrew 验收不能作为新名称渠道已发布的证据。浏览器下载的系统隔离/首次运行仍未验收，不建议通过删除隔离标记或关闭系统保护绕过它。

源码开发者可在 checkout 中运行 `swift build`，使用 `.build/debug/iphone-use`。标准模式不需要构建 Runner；源码 Runner 流程见源码仓库的 `docs/onboarding.md`“源码开发入口”。

## 连接前检查

```sh
command -v iphone-use
iphone-use --version
iphone-use connect --help
xcode-select -p
xcrun --find devicectl
iphone-use config get mode
iphone-use devices
```

确认当前 CLI 支持 `--mode standard|runner`。完整 Xcode 需完成首次安装并在 Settings → Locations 中选定；独立 Command Line Tools 不够。若当前 shell 设置了 `DEVELOPER_DIR`，它会覆盖默认工具链，需核对是否指向预期 Xcode。上面的查询不启动会话、Runner 或媒体流，`config get mode` 不创建配置。工具和设备列表查询成功也不等于设备已解锁、媒体空闲或控制就绪。

## 首次连接：标准模式

```sh
iphone-use devices
export IOS_UDID='DEVICE_ID_FROM_DEVICES'
iphone-use config get mode
iphone-use connect --device "$IOS_UDID" --mode standard
export SESSION='SESSION_FROM_CONNECT'
iphone-use --session "$SESSION" observe
# 打开返回的 PNG，选择可见按钮；按本次观察的 screen_points 将 PNG 选点换算成屏幕点，不能直接传像素。
iphone-use --session "$SESSION" tap OBSERVATION_ID --x POINT_X --y POINT_Y --observe
# 读取新 PNG，确认预期变化后断开。
iphone-use --session "$SESSION" disconnect
```

示例中的设备、会话、观察 ID 和坐标都必须替换为当前真实值。`--x/--y` 接收屏幕点：`x = screen.x + pixelX × screen.width / imageWidth`，y 同理，尺寸来自本次观察；不能固定除以 3，也不能直接传缩放预览坐标。新用户省略 `--mode` 时默认 standard；旧配置可能保留 runner。单次 `--mode` 不改默认值，需要持久选择时使用 `iphone-use config set mode standard`，保存在 `~/.iphone-use/config.json`。标准模式不安装或启动 Runner，不使用已有签名准备记录，也不隐式切换到 XCTest。

标准模式会拥有自己的设备媒体会话。若提示 `native_media_busy`，自行结束 Device Hub 等其他客户端的控制连接，再显式重连；不要关闭他人的全部媒体会话。解锁、信任和系统授权仍需用户在设备上完成。

连接返回 `ok:true` 仍需检查 `result.controlAvailable=true`；若为 false，读取 `controlErrorCode`、`controlError` 和 `recovery`，关闭本次会话后解决原因，再显式连接。不要通过运行 Runner setup 修复标准模式的媒体占用或设备授权问题。常见情况按下表处理；完整排错说明见源码仓库的 `docs/onboarding.md`。

| 返回结果 | 下一步 |
| --- | --- |
| `xcode_unavailable` / `xcode_license_required` | 选择完整 Xcode、检查 `DEVELOPER_DIR`，自行完成首次安装或许可提示，再查询 `devices`。 |
| `device_not_paired` / `developer_mode_disabled` / `device_locked` | 在 iPhone 完成对应信任、Developer Mode 或解锁步骤，再连接。 |
| `native_device_unavailable` | 检查设备 ID、USB 和授权提示；缺失设备信息不等于权限拒绝。 |
| `native_media_busy` | 自行结束其他客户端对该设备的媒体连接，断开自己的会话后再显式重连。 |
| `runner_start_failed` | 查看返回的日志及手机上的实际 XCTest 授权提示，不能仅凭超时判断原因。 |
| 动作结果 `unknown` | 先观察并检查实际效果，不自动重复输入。 |

## 可选：Runner 签名与连接

```sh
iphone-use setup --device "$IOS_UDID"
iphone-use connect --device "$IOS_UDID" --mode runner
```

`setup` 不更改默认模式。需要默认使用 Runner 时运行 `iphone-use config set mode runner`。Runner 可使用截图及可用元素引用；更多参数见安装仓库的 `docs/onboarding.md` 和 `docs/actions.md`。

setup 自动发现 Xcode 缓存中的有效 development profile。有歧义时使用 `--team` 或 `--identity`（开发证书的 SHA-1）；外部 profile 可用 `--profile /path/to/development.mobileprovision`。默认手机 App bundle ID 为 `com.iphone-use.runner.xctrunner`；需要使用自己的标识时，添加 `--bundle-id com.example.iphone-use.xctrunner`，以后会保存复用。

profile 可按 Apple 的[开发 profile 流程](https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile)准备。setup 不登录 Apple、不创建证书/profile，也不修改账号资源。

准备状态保存在 `~/Library/Application Support/iphone-use`，私钥仍在 Keychain。setup 返回 `compiled:false`，并在设备握手、截图采集与正常退出成功后才保存记录。截图验证不代表业务任务已经通过验收。

## 升级和卸载

下面的 Homebrew 命令仅适用于未来已发布的新 formula；当前本地候选按手动版本目录方式升级。

升级前先断开活跃会话。Homebrew 用户执行：

```sh
brew update
brew upgrade iphone-use
iphone-use --version
```

手动安装用户按上述流程校验新版本、安装到新的版本目录，再切换软链接。保留旧版本目录可以回退；不要将新旧包文件混合。

仅 Runner 模式：若 Runner 内容改变、profile 到期或文件被改动，connect 会明确要求重新 setup。在 Xcode 更新签名资料后重跑 setup；无需寻找 `.xctestrun`。不要将包含个人 provisioning profile 的本机准备目录上传到公开 issue。

卸载前断开会话。Homebrew 用户运行 `brew uninstall iphone-use`；手动安装用户删除自己创建的入口软链接及版本目录。卸载 CLI 会保留 `~/Library/Application Support/iphone-use` 中的设备准备状态和手机上的 Runner；需要完全移除时，再删除该状态目录并在 iPhone 上卸载 iPhone-use Runner。模式偏好单独位于 `~/.iphone-use/config.json`，卸载不会自动删除。标准模式没有 Runner 准备产物。不会删除 Keychain 证书或 Xcode 的签名资料。

## 后续公开渠道（尚未发布）

新 `iphone-use` formula 发布后，目标命令为 `brew install HughLee824/tap/iphone-use`。目前不要将其作为已可用的安装步骤。旧 formula 用户届时先断开会话，并按迁移说明处理 `agentsoma` 兼容命令冲突。Homebrew 安装不编译源码、不执行 setup、不接触 iPhone。

手动下载渠道届时需先在 GitHub Releases 确认实际发布版本，再取得对应的包和校验和；不要预设 `0.1.0` 已存在。首批二进制编译下限为 Apple Silicon / macOS 15，标准模式当前仍要求上述 27 环境。发布流程见源码仓库的 `docs/release-setup.md`。

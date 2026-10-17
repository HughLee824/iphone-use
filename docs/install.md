# iPhone-use 发布包安装

> 截至 2026-10-14，[iPhone-use 0.3.0](https://github.com/HughLee824/iphone-use/releases/tag/v0.3.0) 已正式发布，Homebrew formula 已更新，Release 附带插件 0.1.7 ZIP。0.3.1 正在准备草稿，尚未正式发布；公共 Tap 仍为 0.3.0。CLI 与插件独立更新。旧 AgentSoma 安装包不会因改名而获得标准模式。本文后续修订不改写已发布安装包内的 README 或任何资产。


iPhone-use 为外部 agent 提供真实 iPhone 的观察和操作能力。本包同时提供标准模式（截图 + 原生 HID）与 Runner 模式（XCTest）。普通用户先用标准模式，无需 Runner 签名或 setup；配套预编译 iOS Runner 供选择 Runner 模式的开发者在本机重签，不编译源码。

本文也作为安装包内的独立 README；下方包含首次连接与观察步骤。延伸文档位于源码仓库的 `docs/`，未随安装包提供。外部 Agent 插件为可选接入，首次 CLI 操作不依赖插件；接入方法见源码仓库的 `docs/first-task.md` 和 `docs/plugins.md`。

## 前置条件

- 完整 Xcode，已选为当前开发工具链。
- USB 连接且已信任 Mac 的 iPhone，开启 Developer Mode 并保持解锁。
- **标准模式**：当前适配器要求 macOS 27 / iOS 27，已测 Apple Silicon、Xcode 27 和 iPhone 12 Pro；不需要开发签名。
- **仅 Runner 模式**：Keychain 中可用的 Apple Development 证书及对应私钥，以及授权该证书、iPhone 和 Runner bundle ID 的 iOS development profile。

旧名称 AgentSoma 的 `0.1.0` 正式包实测组合为 Apple Silicon / macOS 15.0.1 / Xcode 16.0 / iPhone 12 Pro / iOS 26.6.1，使用已有付费开发团队的签名。免费 Personal Team 的首次配置与续签尚未验收。

## 手动安装：Release 安装包或候选包

从 [GitHub Releases](https://github.com/HughLee824/iphone-use/releases) 中实际已发布的版本取得 `.tar.gz` 和 `.tar.gz.sha256`；维护者验证草稿或使用本地候选包时，从该草稿或候选包提供者取得同一版本的两个文件。将它们放在新的空目录，在该目录校验并解压。版本号必须来自实际文件名，不能沿用旧 AgentSoma `0.1.0` 或预设某版本已公开：

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

包内包含项目 MIT 许可证、Swift ArgumentParser 许可证及版本/源码提交信息。当前 Mac CLI 使用 ad-hoc 签名，未做 Developer ID 签名或公证。此前候选的验证记录不能代替当前包的验收；检查对应 Release 说明中的源码提交、包摘要，以及宿主检查与真机验证的实际范围。旧 AgentSoma `0.1.0` 的终端下载和 Homebrew 验收不能作为新名称渠道已发布的证据。浏览器下载的系统隔离/首次运行仍未验收，不建议通过删除隔离标记或关闭系统保护绕过它。

源码开发者使用 Xcode 27，在 checkout 中运行 `swift build`，使用 `.build/debug/iphone-use`。标准模式不需要构建 Runner；源码 Runner 流程见源码仓库的 `docs/onboarding.md`“源码开发入口”。

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

两种模式均可运行 `iphone-use --session "$SESSION" preview` 打开只读本地实时预览，与控制、录屏共享会话。从 0.3.1 起，正式构建隐藏临时外观切换按钮，但仍优先显示对应机型的官方外框，素材不可用时自动回退自绘；Debug 构建保留外观对比按钮。0.3.0 的 Homebrew 符号链接入口会意外跳过官方素材，这是 0.3.1 修复的资源定位问题，并非生产版功能开关。详见源码仓库的 `docs/local-preview-prototype.md`。

标准模式的观察和动作前校验都使用 Apple PNG，不为截图启动或常驻媒体流。显式开始预览或录屏时才创建自有媒体会话；两者共存时共享该流，停止录屏后仍可保持预览，最后一个使用方结束后清理媒体会话。

未录屏也仍会在输入前只读查询媒体会话列表，以避免与 Device Hub 等客户端同时控制设备。`native_media_busy` 表示检测到其他客户端的媒体会话，不表示 iPhone-use 截图依赖媒体流。请自行结束对方的控制或录屏会话，再按返回的 `recovery` 处理；需要重连时只断开自己的会话，不关闭他人的全部媒体会话，也不自动重放原动作。解锁、信任和系统授权仍需用户在设备上完成。

连接返回 `ok:true` 仍需检查 `result.controlAvailable=true`；若为 false，读取 `controlErrorCode`、`controlError` 和 `recovery`，关闭本次会话后解决原因，再显式连接。不要通过运行 Runner setup 修复标准模式的媒体占用或设备授权问题。常见情况按下表处理；完整排错说明见源码仓库的 `docs/onboarding.md`。

| 返回结果 | 下一步 |
| --- | --- |
| `xcode_unavailable` / `xcode_license_required` | 选择完整 Xcode、检查 `DEVELOPER_DIR`，自行完成首次安装或许可提示，再查询 `devices`。 |
| `device_not_paired` / `developer_mode_disabled` / `device_locked` | 在 iPhone 完成对应信任、Developer Mode 或解锁步骤，再连接。 |
| `native_device_unavailable` | 检查设备 ID、USB 和授权提示；缺失设备信息不等于权限拒绝。 |
| `native_media_busy` | 自行结束其他客户端对该设备的控制或录屏会话，按返回的 `recovery` 恢复；重新观察后再选择动作，不自动重放。 |
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

下面的 Homebrew 命令仅适用于已通过 `iphone-use` formula 安装的用户，并以 Tap 实际提供的版本为准。手动安装及草稿/候选包按版本目录方式升级。旧 `agentsoma` formula 用户不能直接用 `brew upgrade iphone-use` 完成改名迁移；应先断开旧会话，再安装新版本。当前源码生成的 formula 仅提供 `iphone-use`，不再声明旧命令冲突，也不迁移旧配置。

升级前先断开活跃会话。Homebrew 用户执行：

```sh
brew update
brew upgrade iphone-use
iphone-use --version
```

手动安装用户按上述流程校验新版本、安装到新的版本目录，再切换软链接。保留旧版本目录可以回退；不要将新旧包文件混合。

仅 Runner 模式：若 Runner 内容改变、profile 到期或文件被改动，connect 会明确要求重新 setup。在 Xcode 更新签名资料后重跑 setup；无需寻找 `.xctestrun`。不要将包含个人 provisioning profile 的本机准备目录上传到公开 issue。

卸载前断开会话。Homebrew 用户运行 `brew uninstall iphone-use`；手动安装用户删除自己创建的入口软链接及版本目录。卸载 CLI 会保留 `~/Library/Application Support/iphone-use` 中的设备准备状态和手机上的 Runner；需要完全移除时，再删除该状态目录并在 iPhone 上卸载 iPhone-use Runner。模式偏好单独位于 `~/.iphone-use/config.json`，卸载不会自动删除。标准模式没有 Runner 准备产物。不会删除 Keychain 证书或 Xcode 的签名资料。

## GitHub Releases、Homebrew 与插件

[GitHub Releases](https://github.com/HughLee824/iphone-use/releases) 的公开发布状态决定普通用户能否下载；草稿存在不代表已经发布。GitHub 自动生成的源码归档不包含预编译 CLI/Runner，不能替代本指南的安装包。

Homebrew 用户先确认 [Tap](https://github.com/HughLee824/homebrew-tap) 已提供 `iphone-use` formula，且其版本对应实际已发布的稳定版，再运行 `brew install HughLee824/tap/iphone-use`。如果 Tap 仍只有旧 `agentsoma` formula，请使用实际取得的新安装包手动安装，不把旧包视为新版本。迁移旧 formula 时先断开会话，再安装 `iphone-use`。先前已发布的 formula 还提供 `agentsoma` 兼容命令，因此安装这些历史版本前需卸载旧 formula；当前源码生成的 formula 已移除此兼容入口与冲突声明。卸载旧 formula 不删除模式偏好、签名资料或手机 App。Homebrew 安装不编译源码、不执行 setup、不接触 iPhone。

### Homebrew 单公式信任

以下仅适用于包含旧命令冲突声明的历史 formula，当前源码生成的 formula 无需此步骤。启用 Tap Trust 的 Homebrew 可能在检查 `agentsoma` 兼容命令冲突时，因旧 formula 未受信任而拒绝安装；即使旧包已卸载，也需要读取该公式。先查看[旧公式内容](https://github.com/HughLee824/homebrew-tap/blob/main/Formula/agentsoma.rb)，确认信任后仅授权该公式，再重试：

```sh
brew trust --formula HughLee824/tap/agentsoma
brew install HughLee824/tap/iphone-use
```

这会持久信任该单个公式，不安装旧包，也不需要信任整个 Tap。若不愿授予信任，可使用上面的校验后手动安装路径。若 `brew trust` 不存在，不执行此命令；按当前 Homebrew 的实际错误处理。

### 插件渠道

外部 Agent 插件单独分发，版本号与 CLI 不同。使用对应 Release 附带的 `iphone-use-plugin-<version>.zip` 或仓库文档列出的实际可用客户端渠道；插件不包含 CLI，也不证明设备已就绪。新旧插件不要同时启用，避免同一手机任务匹配到两套操作说明。

二进制编译下限为 Apple Silicon / macOS 15，不能据此推断标准模式支持旧系统；标准模式当前仍要求上述 27 环境。发布流程见源码仓库的 `docs/release-setup.md`。

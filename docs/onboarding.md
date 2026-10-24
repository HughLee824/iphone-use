# 首次接入

新用户默认使用标准模式：Apple PNG 截图观察 + 原生 HID，无需 Runner 签名或 setup。Release 与 Homebrew 安装、旧版迁移及信任提示见[安装说明](install.md)，验证范围见[测试指南](testing.md)。

## 标准模式入口

使用完整 Xcode 27、已配对且开启 Developer Mode 的解锁 iPhone；当前原生适配器要求 macOS/iOS 27。安装完整候选包或运行 `swift build` 后：

```sh
iphone-use devices
iphone-use connect --device "$IOS_UDID" --mode standard
# 保存返回的 session，observe 后读取实际 PNG，将原 PNG 选点换算成本次观察 screen_points 中的屏幕点。
iphone-use --session "$SESSION" observe
iphone-use --session "$SESSION" tap OBSERVATION_ID --x POINT_X --y POINT_Y --observe
iphone-use --session "$SESSION" disconnect
```

设备、会话、观察 ID 和坐标均使用实际输出。首次信任、解锁与系统确认由用户完成。标准模式无需证书、profile、`build-runner` 或 `.xctestrun`；普通 Probe 只是开发验收 fixture，不是产品前提。设备被其他媒体客户端占用时明确拒绝，不关闭其会话。

需要 XCTest 与可用元素引用时选择下面的 Runner 路径。两种模式共用 CLI；`config set mode standard|runner` 保存新会话偏好，`connect --mode` 仅覆盖本次。`setup` 始终准备 Runner，不自动改变默认模式。

## 发布包 setup

1. 解压完整发布目录，将 `bin` 加入 PATH，保留相邻的 `libexec/iphone-use/runner`。可以移动整个目录或为 CLI 创建软链接；不要只复制单个二进制。
2. 使用完整 Xcode；`xcode-select -p` 应指向它的 `Contents/Developer`。在 Xcode Settings → Accounts 登录开发账号，确保 Keychain 中有可用的 Apple Development 证书和对应私钥。
3. 用 USB 连接 iPhone，完成信任确认并启用 Developer Mode，保持解锁。准备包含该设备、开发证书和目标 bundle ID 的 iOS development profile。已有 Xcode profile 可自动发现；付费开发团队也可按 Apple 的[开发 profile 流程](https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile)创建并下载，再传 `--profile`。setup 不创建 Apple 资源，也不通过编译 Runner 来生成 profile。

```sh
iphone-use --version
iphone-use devices
iphone-use setup --device "$IOS_UDID"
# 无匹配 profile 或存在歧义时，按实际签名条件明确选择：
iphone-use setup --device "$IOS_UDID" --profile "$DEVELOPMENT_PROFILE" --team "$APPLE_TEAM_ID"
```

交互式终端中，setup 默认输出进度并在启动 Runner 前开启只读视频；不自动打开浏览器。脚本和 Agent 应显式使用：

```sh
iphone-use setup --device "$IOS_UDID" --progress --preview
# 可选：--port 9876；不需要预览时使用 --progress --no-preview
```

`--progress` 输出 `setup_progress` 和原有 `connection_progress` NDJSON，最后一行是最终结果；读取早期 `previewURL` 后复用原标签页，不要等待 setup 结束才开页。`requiresUserAction=true` 时须在手机上完成认证，视频不依赖 Runner 授权。检查、重签和安装阶段不启动视频。预览不可用时通过 `previewError` 报告，仍继续一次 Runner 验证，用户可直接看手机完成授权；不会重放启动、抢占端口或切换设备。成功后返回 `preview.state=stopped` 和清理结果，临时会话及视频源均已释放，常驻只读页面保留并清空旧帧。失败时仍清理已有验证会话；清理未确认不能视为 setup 成功。

重定向 stdout 时默认仍返回单份 JSON，不启用预览；`--no-progress` 可显式关闭进度，`--no-preview` 可关闭预览。显式 `--preview` 需要进度开启，`--port` 需要预览开启。命令不改写用户的默认模式或预览端口。旧 CLI 若没有这些参数，应保留原 setup 形式并在手机上处理认证。

默认手机 App bundle ID 为 `com.iphone-use.runner.xctrunner`。若 profile 只授权自己的标识，首次 setup 添加 `--bundle-id com.example.iphone-use.xctrunner`；这里传的是 **App 的完整 bundle ID**，之后会保存复用。存在多个匹配开发证书时，用 `--identity` 传 `security find-identity -v -p codesigning` 中的证书 SHA-1。该标识用于本机选取私钥，不是私钥内容。

setup 依次校验发布文件和 CLI 配对、设备版本、profile 的设备/bundle ID/有效期/证书匹配，复制并重签 Runner，通过 CoreDevice 在设备安装，随后独立后台启动并经 USB 本地通信验证握手、截图和正常退出。只有全部成功才更新该设备的准备记录。`compiled:false` 表示这条用户路径没有编译；`verified` 的截图项不代表已验证某个业务 App 的 AX 树或交互效果。

之后从任意工作目录连接，无需 `.xctestrun`：

```sh
iphone-use connect --device "$IOS_UDID" --mode runner
# 使用真实返回的 session。
iphone-use --session "$SESSION" open com.apple.Preferences
iphone-use --session "$SESSION" observe
iphone-use --session "$SESSION" disconnect
```

设备准备记录和重签产物位于 `~/Library/Application Support/iphone-use`，与发布包、源码和临时会话目录分开。记录按 CoreDevice 返回的规范 UDID 关联，保存 bundle ID、签名选择、profile 到期时间和文件摘要。产物中包含用户自己的 profile，根目录权限为 0700、记录权限为 0600；不要将此目录放进公开 issue 或发布包。私钥留在 Keychain 中。

## 升级与续签

- **重复 setup**：检查已保存及 Xcode 缓存中的有效 profile，选择同一签名配置下最新的有效版本；已有产物仍匹配时直接复用；显式 setup 会再次部署并做设备验证，普通 connect 不安装。
- **发布包升级**：安装完整新目录，先断开旧会话再切换 CLI。Runner 内容改变时执行 setup；完全相同的 Runner 内容不会仅因 CLI 版本号变化而要求重签。旧目录不会被覆盖，避免破坏仍被宿主持有的文件。
- **profile 到期或证书轮换**：在 Xcode/开发团队中更新签名资料后重新 setup，必要时传新的 `--profile`。默认沿用设备记录中的 bundle ID，不因重新签名产生另一个 Runner App。
- **手机卸载了 Runner**：connect 返回 `runner_not_installed`，请重跑 setup 部署并验证；connect 不会自动重新安装。
- **旧产物清理**：当前保留重签产物及诊断目录。确认没有活跃会话引用后再清理旧目录；清理文件本身不会断开会话。

免费 Personal Team 的首次 provisioning 和到期续签尚未验收。Apple 对免费账号规定的 profile 有效期为七天，见[账号能力说明](https://developer.apple.com/help/account/basics/about-your-developer-account)；当前付费团队的成功结果不代表免费账号路径已成立。

## 源码开发入口

标准模式源码运行只需 `swift build`，然后按上方入口连接。以下签名步骤仅用于 Runner 源码工作流，不是标准模式或发布包用户 setup 的前置步骤。

### 准备一次签名环境

1. 使用完整 Xcode；`xcode-select -p` 应指向该 Xcode 的 `Contents/Developer`。如果选择了独立 Command Line Tools，可在 Xcode 的 Settings → Locations 中选择工具链。
2. 在 Xcode 登录自己的 Apple 开发账号，打开 `Runner/IPhoneUseRunner.xcodeproj`。选择 `IPhoneUseTests` target，在 Signing & Capabilities 中选择团队、启用自动签名，并设置该团队可使用的 bundle ID。默认 `com.iphone-use.runner` 是工程默认值，可按账号需要更改。
3. 用 USB 连接 iPhone，完成设备上的信任确认并启用 Developer Mode；保持解锁。首次证书/profile 配置需要时，在 Xcode 选择该设备和 `IPhoneUseRunner` scheme，使用 Product → Build For → Testing 完成签名配置。

CLI 不管理 Apple 账号、证书或 profile，不传入 `-allowProvisioningUpdates`。团队和 bundle ID 可以保存在本机 Xcode 工程设置中，也可由 agent 在构建时用 `--team`、`--bundle-id` 覆盖。命令行覆盖不会写回 Xcode 工程。

### 构建并连接

在 iPhone-use 源码目录执行：

```sh
swift build
.build/debug/iphone-use build-runner --team "$APPLE_TEAM_ID"
```

已经在 Xcode 工程中选择团队时，省略 `--team`。当 agent 的当前目录是待测 App 项目时，使用 iPhone-use CLI 的完整路径，并传 `build-runner --source-root /path/to/iphone-use`。

成功返回单行 JSON，路径以实际输出为准：

```json
{"ok":true,"result":{"xctestrun":"/path/to/iphone-use/.build/runner/<build-id>/Build/Products/IPhoneUseRunner_iphoneos18.0-arm64.xctestrun","runnerApp":"/path/to/iphone-use/.build/runner/<build-id>/Build/Products/Debug-iphoneos/IPhoneUseTests-Runner.app","buildDirectory":"/path/to/iphone-use/.build/runner/<build-id>","log":"/path/to/iphone-use/.build/runner/<build-id>/build.log"}}
```

`build-runner` 调用 Apple `xcodebuild build-for-testing` 和 `codesign --verify --deep --strict`。它从产物目录读取真实 `.xctestrun` 名称及 Runner 路径，不硬编码 SDK 版本。构建日志保存在 `build.log`，路径清单同时保存到 `build.json`；失败返回非零退出码和 JSON 错误。Apple 对构建与后续测试命令的说明见 [TN2339](https://developer.apple.com/library/archive/technotes/tn2339/_index.html)。

```sh
.build/debug/iphone-use devices
# SIGNED_RUNNER_APP 使用 build-runner 返回的 result.runnerApp；仅部署/升级时安装。
xcrun devicectl device install app --device "$IOS_UDID" "$SIGNED_RUNNER_APP"
.build/debug/iphone-use connect --device "$IOS_UDID" --xctestrun "$SIGNED_XCTESTRUN"
# 使用 connect 返回的 session。
.build/debug/iphone-use --session "$SESSION" apps --query Settings
.build/debug/iphone-use --session "$SESSION" open com.apple.Preferences
.build/debug/iphone-use --session "$SESSION" observe
# agent 读取 observe 返回的 PNG，再根据实际观察选择动作。
.build/debug/iphone-use --session "$SESSION" disconnect
```

`SIGNED_XCTESTRUN` 使用构建结果的 `result.xctestrun`。`connect` 只后台启动已安装的 Runner，以 USB 本地回环通信验证能力和执行操作；不会重新安装或要求打开 WLAN 权限。安装/升级由前面的显式部署步骤负责。断开会话停止进程并释放观察缓存，签名构建和手机上的 Runner 保留以便复用。

每次构建分配一个新的目录，避免覆盖活跃会话引用的文件。Runner 及其共享源码、Xcode 或签名发生变化后重新构建，并将新路径用于下一次 connect；仅 CLI/宿主代码变化时运行 `swift build` 后建立新会话即可。相同的兼容 Runner 构建可供后续会话复用；不需要每次连接都编译。构建目录暂时不自动清理，确认没有会话引用后可移除不再需要的目录。上述独立目录、CLI 名称与路径字段是工程实现选择。

## 常见接入错误

| 返回结果 | 下一步 |
| --- | --- |
| `xcode_unavailable` | 安装完整 Xcode、完成首次安装并在 Settings → Locations 中选定；检查当前进程的 `DEVELOPER_DIR` 覆盖。先用只读 `devices` 复查，标准模式无需 Runner setup。 |
| `xcode_license_required` | 自行打开 Xcode 审阅许可和首次启动提示，完成后再执行 `devices`。CLI 不代为同意许可。 |
| `device_not_paired` | Apple 明确报告未配对；通过 USB 连接、解锁并在 iPhone 完成“信任此电脑”，再查询 `devices` 和连接。 |
| `developer_mode_disabled` | Apple 明确报告 Developer Mode 关闭；在 iPhone 的“设置 → 隐私与安全 → 开发者模式”启用并完成系统提示，解锁后重连。 |
| `native_device_unavailable` | Apple 未返回全部设备、配对、Developer Mode 或隧道信息；检查设备 ID、USB 和授权提示，不把缺失信息自动判为权限拒绝。 |
| `native_protocol_unsupported` | 标准模式当前仅适配 macOS/iOS 27；检查完整 Xcode 与系统版本，不隐式切换模式。 |
| `native_media_busy` | 自行结束其他客户端的媒体控制连接后显式重连；不使用 stopAll。 |
| `runner_package_missing` / `runner_package_mismatch` / `runner_package_invalid` | 安装完整、同一版本的 CLI 与 Runner 发布包，保留目录结构。不要搜索 `.build` 选择旧产物。 |
| `setup_required` / `setup_update_required` / `setup_state_invalid` | 对该设备重新 setup；如旧会话仍活跃先断开。 |
| `ios_version_unsupported` | 设备需达到当前 Runner 包的最低版本。最低版本只用于排除已知不兼容，不代表所有组合都经过验收。 |
| `profile_not_found` / `profile_invalid` | 准备匹配的 iOS development profile，必要时传 `--profile`。发布用户不需要 build-runner。 |
| `profile_expired` / `profile_device_mismatch` / `profile_bundle_mismatch` / `profile_identity_mismatch` / `profile_team_mismatch` | 按错误修正 profile 或选择参数，然后重新 setup。 |
| `signing_identity_unavailable` / `signing_identity_ambiguous` | 检查当前执行上下文是否能访问 Keychain 中的开发私钥；明确选择匹配证书。沙盒内看不到证书不等于本机不存在证书。 |
| `runner_signing_failed` / `setup_verification_failed` / `setup_cleanup_failed` | 阅读错误和会话日志；签名成功不等于设备可用，验证失败不会保存准备记录。 |
| `runner_source_missing` | 将 `--source-root` 指向包含 `Runner/IPhoneUseRunner.xcodeproj` 的源码目录。复制单个 CLI 二进制不会携带 iOS 源码。 |
| `invalid_team` / `invalid_bundle_id` | 修正签名参数；team 是 10 位开发团队 ID，bundle ID 是点分隔标识。 |
| `runner_build_failed` | 阅读返回路径中的 `build.log`。若提示缺少开发团队/profile，在 Xcode 完成签名；若选中的是 Command Line Tools，切换到完整 Xcode。构建错误不一概归因于签名。 |
| `runner_products_invalid` / `runner_signature_invalid` | 检查当前源码、构建日志和产物；重新构建，使用新的输出路径。 |
| `runner_needs_rebuild` | 错误列出预期与实际能力版本。发布用户安装配套版本并 setup；源码开发者重新 build-runner，使用新路径 connect。 |
| `coredevice_initialization_timeout` | 若在沙盒内，先通过调用工具的授权机制，在允许 CoreDevice 通信的本机环境中对照一次只读 devices，再定位原因；不单凭超时断定服务损坏。见[接入诊断](discovery.md#接入失败诊断)。 |
| `coredevice_access_denied` | 原始命令输出明确拒绝访问。检查本机执行权限，再做一次只读 devices 对照。 |
| `coredevice_failed` | 读取错误中的失败阶段、退出码和原始信息；未知错误不自动归因于权限。 |
| `inspect_query_unsupported` | 当前会话宿主未确认查询参数。用新 CLI 重新 connect、observe 后查询；不需要因此重建兼容的 Runner。 |
| `device_locked` | 解锁手机后重新 connect。 |
| `runner_start_failed` / `coredevice_unavailable` | 查看返回的会话日志，核对设备信任、Developer Mode、USB 和开发服务状态。检查手机是否显示 XCTest UI 自动化授权提示，如有则自行完成；超时本身不能证明原因，构建成功不等于设备侧安装或启动成功。 |

## 工程边界

独立 Xcode 工程编译 `Runner/LiveSessionTests.swift`，并共享 `Sources/IPhoneUseCore` 中的帧稳定、画面校验和 XCTest 诊断实现，不依赖本地探针或 Fixture。测试模块叫 `IPhoneUseTests`，构建不需要 XcodeGen。目录职责见 [架构与仓库布局](architecture.md)。

免 Xcode 安装、全新 Mac 配置、免费 Personal Team 签名以及更多 OS/设备组合仍未验证。发布 Runner 的编译下限为 iOS 17，源码工程默认仍为 iOS 16；macOS CLI 编译下限为 13。这些编译下限不是完整链路的支持承诺。发布包验收见 [Release 与 setup](release-setup.md)。

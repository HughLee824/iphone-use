# Release 与 setup

当前候选包同时包含标准模式 CLI 和可选的预编译 Runner。标准模式无需重签或 setup；Runner 模式保留本机重签部署流程。项目采用 MIT，计划分发仓库为 `HughLee824/iphone-use`，Tap 为 `HughLee824/homebrew-tap`；本次未发布新名称渠道。

两种模式都保留完整 Xcode 前提，用户自己的开发签名仅是 Runner 的前提。日常使用不依赖源码仓库或 `.build` 目录。当前标准模式适配 macOS/iOS 27，不能以旧 Runner 发布包的编译下限推断兼容范围。用户流程见[首次接入](onboarding.md)，发布包附带的独立说明见[安装说明](install.md)。

## 包结构与信任边界

```text
iphone-use-<version>-macos-<architecture>/
  bin/iphone-use
  bin/agentsoma             # 同字节兼容入口
  libexec/iphone-use/runner/
    manifest.json
    Runner.xctestrun
    IPhoneUseRunner.app/
  README.md
  LICENSE                   # 项目 MIT
  licenses/SwiftArgumentParser.txt
  build-info.json           # 版本、架构、源码提交、工作区状态、构建工具版本
```

CLI 从自身真实路径定位配套资源，支持搬移整个目录和软链接入口。manifest 记录格式版本、release 版本、CLI SHA-256、Runner 内容版本、最低 iOS 版本和逐文件 SHA-256。CLI/Runner 混装、文件缺失、额外文件、符号链接和外部测试产物路径均拒绝。文件摘要用于发现错误和混装，不替代可信下载来源或维护者签名。

标准模式的 Swift/C/Objective-C 实现静态编入 CLI，随包无需额外 dylib 或研究探针。运行时使用系统 RemoteXPC、AVConference，以及 Xcode 安装的 CoreDevice 服务和元数据；这些 Apple 框架不随包复制，也不绕过权限。`verify-release.py` 检查 CLI 的 Mach-O 依赖仅指向系统库；动态打开的框架及服务需另做真机验收。

发布 Runner 不包含 provisioning profile、嵌入的 XCTest 框架、调试符号包或源码。发布构建将 iOS 编译下限设为 17，使用设备提供的 XCTest；最低版本检查只排除已知不兼容，不证明所有 iOS/Xcode 组合都可用。XCTest 的断言和跳过报告使用 `#fileID`，打包时检查二进制是否残留源码仓库的绝对路径。

setup 将包复制到用户状态目录，改写为保存的 App bundle ID、嵌入用户 profile，由本机 codesign 对测试 bundle 和 Runner 签名并校验。随后使用 `test-without-building` 做真机握手、截图和退出验证，成功后原子更新按 UDID 保存的记录。安装目录不写入用户签名资料。设备能力握手仍是最终兼容性检查；本地文件存在和签名校验成功不能替代它。

相同设备重复 setup 复用有效产物，续签时扫描 Xcode profile 和已保存 profile。相同签名配置选择较晚到期的有效 profile；跨团队或证书有歧义时明确报错，不猜测。Runner 内容摘要不包含 CLI release 版本和 CLI 摘要，因此同一 Runner 原样随 CLI 更新时可复用。新的重签目录不会覆盖旧目录，活跃会话继续持有自己的文件。

## 维护者构建

在 macOS/Xcode 主机的源码目录执行，需要 Python 3.9+；Python 仅用于维护者打包，不是用户运行依赖：

```sh
swift test
python3 -m unittest discover -s scripts/tests -v
python3 scripts/build-release.py --version 0.2.0-rc.1 --require-clean
python3 scripts/verify-release.py .build/releases/iphone-use-0.2.0-rc.1-macos-arm64.tar.gz --require-clean
python3 scripts/generate-homebrew.py .build/releases/iphone-use-0.2.0-rc.1-macos-arm64.tar.gz --output .build/releases/iphone-use.rb
```

脚本构建 release CLI、在隔离目录 `build-for-testing` 构建无开发签名的 Runner，移除二进制调试信息，整理固定相对路径的测试清单，附带许可证及构建记录，然后生成目录、tar.gz 和 SHA-256 文件。CLI 仅作本机运行所需的 ad-hoc 签名。产物默认位于 `.build/releases`，也可用 `--output-dir` 指定；已有同名产物会拒绝覆盖。打包和清单检查在临时目录完成，失败不会留下同名的半成品包。CLI 与 Runner 构建日志分开保存。脚本不创建 tag、不上传文件、不操作 Apple 账号、不使用维护者的 iOS profile。

`--require-clean` 要求构建前后源码已提交且工作区干净；公开 formula 生成也拒绝工作区有未提交修改的包。本地开发验收可省略此选项，formula 生成添加 `--local` 使用 `file://` 下载地址。含本机地址的 formula 不上传到 Tap。

`verify-release.py` 校验外层 SHA-256、归档路径、许可证、构建记录、CLI 与 Runner 逐文件摘要及测试清单，拒绝软链接、越界路径、签名资料和嵌入框架。默认还在含空格的新目录解压搬移，通过软链接检查版本、帮助、CLI 签名和链接库。在独立 `IPHONE_USE_CONFIG_DIR` 中验证新用户 standard 默认值与 standard/runner 偏好读写，不访问设备或改写用户偏好。`deviceVerified:false` 明确表示尚未验收真机；其他系统可用 `--no-execute` 仅检查归档。

iPhone-use 仍是 macOS CLI。Mac Developer ID 签名、公证是下载渠道与系统信任体验的选择，不代表需要制作 Mac GUI App，也不是所有 CLI 分发渠道统一的前置条件。当前流程未使用 Developer ID 或 notarization。若以后接入，签名必须先于 CLI 摘要及最终归档，不能沿用旧摘要。见 Apple 的 [Developer ID](https://developer.apple.com/developer-id/) 和 [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。浏览器下载后及全新 Mac 的安装体验仍需单独验收。

## GitHub Releases 与 Homebrew Tap

首次分发只生成已验证的 `macos-arm64` 安装包。CI 和发布工作流统一使用 GitHub 的 `xcode-27` ARM64 runner，并固定 `/Applications/Xcode_27.0.app/Contents/Developer`（Xcode 27.0），与镜像预装的 iOS 27 simulator runtime 配套；即使构建真机产物，App Icon 的资源编译也需要兼容的 simulator runtime。Intel 发布不在当前矩阵内。构建不需要维护者的 Apple 签名证书、profile 或 iPhone。

源码构建使用 Xcode 27。录屏解码依赖其 VideoToolbox Swift 接口，旧 Xcode 16.4 无法编译带 `frameOptions` 的调用；不为旧构建工具链删除每帧分辨率参数或添加兼容路线。该工具链选择不修改现有部署下限，也不代表旧系统运行兼容性已验收。GitHub 的 [`xcode-27` 镜像](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)目前标记为 preview；工作流打印实际 Xcode/Swift 版本，镜像问题按 CI 证据处理。

发布采用 **云端生成草稿 → 本地 Mac + iPhone 验收 → 发布同一安装包 → 更新 Homebrew → 验证公共安装入口**。

| 执行位置 | 检查范围 | 不代表什么 |
| --- | --- | --- |
| GitHub 的 CI 工作流 | Swift/Python/Node 测试、无开发签名 Runner 构建、插件归档与网站构建 | 发布包已发布或真机验收通过 |
| GitHub 的 Draft release 工作流 | 测试、编译、归档、搬移、Homebrew 安装与摘要校验 | setup、设备连接或业务任务通过 |
| 维护者本地 Mac + iPhone | 草稿安装包的 setup、连接、观察、操作、升级及业务结果 | 未测试的设备、系统和签名组合也兼容 |

[GitHub 托管 runner](https://docs.github.com/en/actions/concepts/runners/github-hosted-runners) 提供构建主机，不附带供此工作流使用的 iPhone。当前不接入云真机平台或 self-hosted runner；未来若自动化真机检查，需要另外提供 Mac + iPhone 测试环境。

1. 将本次发布源码提交到 `HughLee824/iphone-use` 的 `main`，让 CI 通过。
2. 在 Actions 中运行 **Draft release**，填写未使用过的版本，不含 `v`。工作流只允许从主仓库的 `main` 执行，运行 Swift/Python/Node 测试与插件一致性检查，构建干净源码，验证归档、搬移和 Homebrew 安装后的全部 CLI/Runner 摘要。
3. 云端检查通过后，独立的写入任务创建 GitHub Release **草稿**，附上 tar.gz、SHA-256、从同一归档生成的 `iphone-use.rb`，以及从该源码验证的插件 ZIP 与校验文件。说明自动填入版本、源码提交、包摘要和工作流链接，**本地真机验收始终初始化为 pending**。已有 tag 拒绝复用，不覆盖旧版本。包含 `-` 的版本自动标记 prerelease。
4. 在本地下载该草稿的安装包，按下文完成真机验收。将结果摘要填回草稿，补齐版本变化、升级说明和兼容性范围，保留失败和未测试项。
5. 维护者核对验收记录与草稿的版本、源码 SHA、包 SHA-256 一致后，手动发布该草稿。发布使用本地验收过的同一批资产，不重新构建或替换包。这是维护者发布前的检查；当前工作流只创建草稿，不自动判断业务结果，也不自动阻止维护者在 GitHub 页面点击发布。
6. 稳定版发布后，在 `HughLee824/homebrew-tap` 的 Actions 运行 **Update iPhone-use**，填写相同版本。它拒绝草稿和预发布版，校验归档、源码提交与 tag，再生成并对比 release 中的 formula，最后提交到 Tap 的 `main`。重复同版本不产生空提交。
7. 从公共 Release 地址重新下载并核对摘要，按安装说明验证手动安装。稳定版另用 `brew install HughLee824/tap/iphone-use`（已有安装则升级）核对版本和连接；Tap 工作流的成功不替代这一步。浏览器下载及全新 Mac 的系统信任体验单独记录。

Tap 初始文件位于 `packaging/homebrew-tap`，另复制仓库根目录的 `LICENSE`。其更新工作流只需要 Tap 自身的 `GITHUB_TOKEN`，不需要跨仓库写入 PAT；iPhone-use 源码与 Release 需公开可读。首次稳定版之前不放置指向不存在资产的 formula。预发布版本通过 GitHub Releases 手动安装。

Release 和 Tap 的实际可用版本以各仓库为准；发布流程不会自动把本地候选包或开发验收记录上传。

formula 将原包的 `bin` 与 `libexec` 一起放在 Homebrew keg 的 `libexec` 下，并创建 `bin/iphone-use` 软链接，保持 CLI 的相对资源定位规则。安装与升级不执行 setup，不编译、不在 iPhone 上操作。每次 release 的 `brew test` 检查安装后的 CLI 与 Runner 全部文件摘要，以发现 Homebrew 清理或二进制处理引入的修改。

### 本地候选包验收

登录有权访问草稿的维护者账号，从草稿页面下载资产。也可以在对应源码提交的仓库目录使用已登录的 [GitHub CLI](https://cli.github.com/manual/gh_release_download)：

```sh
(
  set -e
  IPHONE_USE_VERSION=0.2.0-rc.1 # 替换为待验草稿版本
  IPHONE_USE_PACKAGE="iphone-use-${IPHONE_USE_VERSION}-macos-arm64"
  IPHONE_USE_ACCEPTANCE_DIR="$PWD/.local/releases/$IPHONE_USE_VERSION"
  mkdir -p "$PWD/.local/releases"
  mkdir "$IPHONE_USE_ACCEPTANCE_DIR"
  gh release download "v${IPHONE_USE_VERSION}" --repo HughLee824/iphone-use \
    --dir "$IPHONE_USE_ACCEPTANCE_DIR" \
    --pattern "${IPHONE_USE_PACKAGE}.tar.gz" --pattern "${IPHONE_USE_PACKAGE}.tar.gz.sha256"
  python3 scripts/verify-release.py "$IPHONE_USE_ACCEPTANCE_DIR/${IPHONE_USE_PACKAGE}.tar.gz" \
    --require-clean > "$IPHONE_USE_ACCEPTANCE_DIR/package-verification.json"
  gh release view "v${IPHONE_USE_VERSION}" --repo HughLee824/iphone-use \
    --json body --jq .body > "$IPHONE_USE_ACCEPTANCE_DIR/acceptance.md"
)
```

使用尚未存在的验收目录，避免覆盖旧记录；下载或校验失败会停止后续步骤。失败重试时另选新目录。核对 `package-verification.json` 的版本、源码提交和 SHA-256 与草稿一致；其中 `executed: true` 包含版本/帮助、隔离偏好读写、签名和链接依赖检查，没有操作 iPhone。浏览器下载也应使用同一校验命令。原始记录保存在已忽略的 `.local/releases/<version>/`，草稿只填写不含个人数据的结果摘要。

按[安装说明](install.md)把完整包安装到源码目录外，从另一个工作目录运行它。每个命令使用该包的绝对路径，或先用 `command -v iphone-use` 和 `iphone-use --version` 确认入口，避免误用开发版。保留原始归档及 SHA-256，不用本地重新编译的 CLI 或 Runner 代替候选包。

| 真机验收项 | 需要记录的结果 |
| --- | --- |
| 环境与安装 | 验收人、日期、Mac 架构/macOS/Xcode、iPhone 型号/iOS、签名类型、候选包路径和版本 |
| 标准模式接入与退出 | 空的隔离配置中不运行 setup、不提供 xctestrun，省略 mode 连接应选择 standard；`connect → observe → Probe 一次点击 → 新截图核对 → disconnect`，并核对没有启动 Runner |
| Runner 回归 | 同一包保留 setup 与显式 `--mode runner`；已有开发签名下验证连接、截图与正常清理，记录使用的是包内重签产物还是源码签名产物 |
| 重复与升级 | 重复 setup；从上一公开版本升级后的连接、Runner 复用或要求重新 setup。首发没有上一版本时写明“不适用” |
| 业务结果 | 任务、预期值、保存后的实际值。例如在测试日历创建 10:00–11:00 日程，保存后重新打开核对日期、开始和结束时间；默认半小时不能代替这项验证 |
| 支持范围 | 通过、失败及未测试的条件。首发或接入流程变更时补干净 Mac 的首次配置；免费账号等范围按实测声明 |

外部 agent 可以协助执行本地验收，维护者依据观察结果填写草稿的 `Local device acceptance`，通过后改为 `passed`，并完成对应勾选；不适用项写明理由。setup 的截图或输入命令的成功响应不能代替业务结果核对。证书/profile、设备标识及含个人内容的截图和日志保留本地。

### 版本与失败处理

- RC（例如 `0.2.0-rc.1`）通过后可作为预发布版本公开供测试，使用手动安装。正式版 `0.2.0` 需要生成并验收它自己的包，不能只重命名 RC 资产或修改 Release 标题。
- 构建或上传失败时保持未发布状态；重试前检查已有草稿和资产，避免把不同提交的包混入同一版本。重新构建后，以新包摘要重新验收。
- 已公开版本发现问题时发布新版本修复，保留历史安装包供手动回退。Tap 更新失败只重试 Tap，不重建已验收的 Release。

当前双模式本地候选包的实现、宿主检查与真机进度见[标准模式首次使用验收](standard-package-acceptance.md)。下面保留旧发布路线的历史验收，不代表新名称渠道已发布。

## 验证范围

2026-09-07 对公开 `0.1.0-rc.1` 包补测下载渠道，包 SHA-256 为 `52ff3e7c8e90d142a704ec1914433c506ebcc4d92245b3a48db188d0934a174d`。本机 Apple Silicon / macOS 15.0.1 下，`curl` 下载、校验、解压及版本/setup/connect 帮助命令通过。Safari 下载内容与同一 RC 一致，解压后 CLI 保留隔离属性，但首次运行未通过；Chrome 下载在资产重定向处返回 `ERR_BLOCKED_BY_CLIENT`。这些结果分别记录，不将浏览器下载失败等同于 CLI 签名失败，也不将命令行安装通过外推为浏览器渠道通过。本轮没有重复真机业务验收。

当前采用命令行下载的已验证路径，保持 ad-hoc 签名。Developer ID 签名与公证不作为所有渠道统一的发布门槛；浏览器直接下载安装体验仍需解决后单独验收。上述 RC 补测时公共 Tap 尚未上架，已有 CI 中的 Homebrew 安装检查不代表公共 `brew install` 入口已可用；后续上架结果以 Tap 和对应 Release 为准。

已有本地开发候选包的验收记录覆盖 Apple Silicon / macOS 15.0.1 / Xcode 16.0 / iPhone 12 Pro / iOS 26.6，以及已有付费开发团队签名条件下的包校验、搬移、重签、重复 setup 和正常连接。这些是路线验证，不自动构成后来 GitHub 构建包的验收结果。每次发布的结果以对应草稿的包摘要和本地验收记录为准。原始设备记录、候选包、签名资料和日志保留在本地。

### 0.1.0 正式发布验收

2026-09-07 已发布 [0.1.0](https://github.com/HughLee824/AgentSoma/releases/tag/v0.1.0)，源码提交为 `25bef5092aac42a3f60bf1ec01b7ba79e12bee5d`，安装包 SHA-256 为 `c2eb4f1ee1e2c61cf05bfae46076f38d18c3385a6b0a5ab2c9181ed933fec80d`。本次验收使用从 GitHub 下载并搬移到源码目录外的同一安装包；发布时未重新构建或替换资产。

- Apple Silicon / macOS 15.0.1 / Xcode 16.0 / iPhone 12 Pro / iOS 26.6.1，已有付费开发签名。首次 setup 无需编译，重复 setup 复用成功。
- 连接、应用发现、打开、观察、受保护输入及断开通过。计算器 `125 × 8 = 1,000` 经截图与界面文本核对；断开重连后再次打开历史记录，确认今天的计算仍在。一次屏幕变化拦截未派发输入，刷新观察后恢复。
- setup 验证会话和业务会话均正常清理；业务会话的 host/xcodebuild 退出及观察缓存删除另行核对。
- [Tap 更新](https://github.com/HughLee824/homebrew-tap/actions/runs/34123914541)通过，formula 提交为 `ab3cc80fc7af9db4483177f334c9f3cd686e1505`。匿名下载的三个公开资产与验收文件逐字节一致，公开 tag 指向上述源码提交。
- 实际执行 `brew install HughLee824/tap/agentsoma` 和 `brew test HughLee824/tap/agentsoma` 通过，CLI/Runner 文件摘要与发布清单一致。使用 `/opt/homebrew/bin/agentsoma` 完成真机连接、截图检查、点击和正常断开。

本次证明现有开发签名条件下的正式包与公共安装入口可用，未扩展免费账号、全新签名环境或浏览器渠道的支持范围。私有设备标识、签名资料、截图与命令原始记录保留在本地。

## 尚未验收的发布条件

- 免费 Apple 账号是否列为首发正式支持，以及首次 provisioning 和七天到期后的续签恢复。
- 全新 Mac 从无证书/profile 到完成 setup；更多 Xcode/iOS 组合与 Intel Mac。
- 免 Xcode 启动。
- 公共下载后的全新 Mac / Gatekeeper 安装体验；是否增加 Developer ID 签名与公证根据渠道验收决定。

这些条件不由本机已有付费开发团队的成功结果推断，也不阻塞当前预编译路线的代码与本机验收。

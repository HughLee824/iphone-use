# Agent 插件与通用 skill

> 工作流 0.1.13 新增通用 adapter，与 Cursor/OpenCode 的独立 npm 安装器共用同一 skill。Codex、Claude Code、DeepSeek Harness 保留插件入口。CLI 与 skill 分别升级；安装、模型加载及真机任务的验收范围分别记录。


[公开网站](https://iphone-use.com) → [安装 CLI](install.md) → 安装本页插件 → [选择模式并连接](first-task.md#connect-in-standard-mode) → 首个真机任务。完整英文路径见 [First task](first-task.md)。

插件是 **CLI + skill** 封装，共用设备操作契约，分别适配 Codex 的命令执行、后台续读和图片工具，Claude Code 的 Bash、TaskOutput 和 Read，以及 DeepSeek Harness 的 bash、job_output 和 read_image。它不含 CLI、不创建开发签名、不自动接入手机，也不要求 MCP 服务。

## 先检查环境

新安装使用已发布的 CLI。旧 `agentsoma` formula 用户先断开会话、卸载旧 formula，再安装新 formula；遇到 Tap Trust 拒绝时按[单公式信任提示](install.md#homebrew-单公式信任)处理，不默认信任整个 Tap。

```sh
brew install HughLee824/tap/iphone-use
command -v iphone-use
iphone-use --version
```

正式版及开发工作流的环境以 [first-task](first-task.md) 为准：标准模式已验收 Apple Silicon / macOS 27、Xcode 27、iOS 27；需要设备信任、Developer Mode 和解锁。**只有 Runner 模式需要开发签名与 setup**。包内只读 `scripts/preflight.sh` 检查一次 CLI、Xcode 和输出能力，随后复用检测结果。

本地候选包不在 PATH 时，通过 `IPHONE_USE_CLI=/absolute/path/to/bin/iphone-use sh /absolute/path/to/skill/scripts/preflight.sh --candidate` 检查；源码 `development` 版本使用 `--source`。设备调用继续使用同一个可执行文件。不要为了通过版本检查切到另一个已安装版本。preflight 的兼容版本下限仍为 CLI 0.1.0，但新安装应使用已发布的 iPhone-use 0.3.3；旧 AgentSoma 0.1.0 的版本号不能证明它支持标准模式。

安装后重启原本已打开的客户端，使其取得更新的 PATH。插件安装成功不等于 signing/setup 成功。免费 Personal Team 和全新 Mac 配置仍未验收；详见[前置条件和签名](first-task.md#before-you-start)。

## Codex 安装

以下是终端命令，已核对 Codex CLI 0.146.0。使用支持 `codex plugin --help` 的版本：

```sh
codex plugin marketplace add HughLee824/iphone-use
codex plugin add iphone-use@iphone-use
codex plugin list --marketplace iphone-use --json
```

确认插件已启用，在 Codex 桌面插件入口选择 iPhone-use 并开始新任务，或在新任务中调用 **`$iphone-use:iphone-use`**。如果桌面列表未刷新，重启客户端。如果 CLI 没有 `plugin add`，使用兼容版本或通过已添加 marketplace 的桌面插件目录安装；不要套用 Claude 的 `plugin install` 命令。

仓库索引位于 `.agents/plugins/marketplace.json`，`source.path` 相对仓库根目录解析到 `./plugins/iphone-use`。插件身份由 `.codex-plugin/plugin.json` 定义。[官方格式与安装说明](https://developers.openai.com/plugins/build/plugins)及[客户端命令参考](https://learn.chatgpt.com/docs/developer-commands#codex-plugin-marketplace)。

## Claude Code 安装

以下命令已在 Claude Code 2.1.250 上验收。在终端执行：

```sh
claude plugin marketplace add HughLee824/iphone-use
claude plugin install iphone-use@iphone-use
claude plugin list --json
```

开始新的 Claude Code 会话，调用 **`/iphone-use:iphone-use`**。交互模式中也可使用 `/plugin marketplace add HughLee824/iphone-use` 和 `/plugin install iphone-use@iphone-use`；若安装结果要求 reload，按提示执行。

仓库索引位于 `.claude-plugin/marketplace.json`，插件同样从 `./plugins/iphone-use` 安装，读取自己的 `.claude-plugin/plugin.json`。两份清单共用一套内置 skill，不会引用维护者 checkout。[官方插件说明](https://code.claude.com/docs/en/plugins)与[marketplace 说明](https://code.claude.com/docs/en/plugin-marketplaces)。

添加 marketplace 时使用整个 Git 仓库或本地根目录，不使用 GitHub raw JSON 地址：单独下载索引不会携带相对路径下的插件文件。

## DeepSeek Harness 安装

使用官方 [bundle 打包与安装机制](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/develop/basic/publish.md)：`package.json` 声明 `dsh.bundle.patch`，`cordis.patch.yml` 插入 skill 插件，插件通过 `ctx.skills.register` 注册共用的 `iphone-use`。包内 JavaScript 可直接运行，无 npm 依赖、构建步骤或安装脚本。官方 [skill 接口](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/skills.md)提供资源根路径和卸载生命周期。

当前适配目标为 **DeepSeek Harness 0.2.1-rc.1**，清单声明 `>=0.2.1-rc.1 <0.3.0`；其他版本仍需验证。先安装 CLI，并确认 Harness 的 shell 与图片读取工具都运行在连接 iPhone 的 Mac 上。

在 **Add plugin** 输入框填写以下任意一项，两种来源安装的是同名插件，选一种即可：

| 安装来源 | 输入内容 |
| --- | --- |
| Package name（选择 Official npm registry） | `dsh-iphone-use` |
| GitHub repository address | `https://github.com/HughLee824/iphone-use` |

终端对应命令如下。桌面应用使用 `desktop` profile，Web 用户换成自己的 `web` profile：

```sh
# npm 包名
dsh plugin --profile desktop add dsh-iphone-use

# 或直接使用 GitHub 仓库地址
dsh plugin --profile desktop add https://github.com/HughLee824/iphone-use

dsh --profile desktop --dump-config
```

若桌面安装尚未将 `dsh` 加入 PATH，可将上面的 `dsh` 替换为 `"/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh"`。使用当前桌面 runtime 附带的 CLI，避免另一个版本的 `npx` 命令管理同一 profile。

仓库根目录的 `package.json` 直接暴露现有 `plugins/iphone-use` bundle，无需子目录参数、额外仓库、安装脚本或本地构建。根清单由 `scripts/sync-plugin.py` 从插件清单生成，发布的 npm 包只包含公开插件文件。Git 来源跟随仓库默认分支；需要固定版本时可指定已经存在的提交 SHA。npm 来源可用 `dsh-iphone-use@0.1.10` 固定版本。

重启 Harness 并开始新会话，要求“使用 iphone-use skill 打开我的 iPhone 设置，进入通用，读图验证并断开”。注册名称为 `iphone-use`，不使用 Codex/Claude 的冒号命名空间。模型通过 `skill` 工具加载指引，截图使用 **read_image**，文本参考文件使用 **read**。完整差异见 [DeepSeek adapter](../skills/iphone-use/references/deepseek-harness.md)。

本地开发仍可安装 `./plugins/iphone-use`，该方式链接到 checkout，须保留目录；独立 ZIP 解压后的 `iphone-use` 目录也可安装。npm 发布从仓库根目录执行，先运行 `python3 scripts/sync-plugin.py --check`、测试与 `npm pack --ignore-scripts`，核对包内文件后发布同一 tarball。

更新第三方插件时，先在 Plugin Manager 卸载，再通过原来源重装；或使用 `dsh plugin --profile desktop remove dsh-iphone-use` 后执行对应安装命令，再重启 Harness。这些操作只管理插件，不卸载 CLI。

2026-10-17 本地验证：使用桌面版附带的 Harness 0.2.1-rc.1，在隔离的 `DSH_HOME` 中分别安装本地目录与 npm tarball，`--dump-config` 确认插件层；使用真实 Cordis 和 SkillRegistry 验证迁移后的包可注册、加载并卸载 skill，参考文件仍从包内解析。npm 文件清单、ZIP 自包含与可复现检查已通过。这不包含模型驱动的真机操作或 Plugin Manager 图标的视觉验收。

2026-10-17 公开分发验证：从完整 GitHub 仓库地址安装到全新的隔离 profile，解析到提交 `54cd0d59505a4e0b788698161a0f445b8d2b6171`、插件版本 `0.1.10`。真实 Harness runtime 验证 skill 注册、包内参考文件/脚本/图标/语言资源读取和释放；CLI 卸载后配置层与包目录均已移除。[对应 CI](https://github.com/HughLee824/iphone-use/actions/runs/39015577838)通过。

同日通过纯包名 `dsh-iphone-use` 从官方 npm registry 安装到另一全新 profile/cache，解析到 `0.1.10`，通过相同的真实 runtime 检查，CLI 卸载后配置层与包目录均已移除。公开 tarball 的 SHA-1 为 `ef57fc351371f57ebe16b65604a211bfb8fcd351`，SHA-512 integrity 与发布前打包文件及安装后的 lockfile 一致。两种来源均未使用本地目录或本地 tarball 代替公开下载。

npm 发布命令成功返回后，仍须确认公开 registry 的 `latest` 和 tarball 已可用再执行包名安装验收。发布前扫描期间可能暂时出现 `0.0.0-stage` 占位版本；该版本不是可用插件，不能据此认定发布验收通过。

## 通用 skill（Cursor / OpenCode）

通用 skill 与三个插件使用同一个 `skills/iphone-use` 源。`iphone-use-skill` 是独立的 npm 安装器，`dsh-iphone-use` 仍是 DeepSeek Harness bundle；它们不互相替代。Node.js 20+：

```sh
npx iphone-use-skill install --agent cursor
npx iphone-use-skill check --agent cursor
npx iphone-use-skill update --agent cursor
npx iphone-use-skill uninstall --agent cursor
```

OpenCode 使用 `--agent opencode`。默认安装到当前项目 `.cursor/skills/iphone-use` 或 `.opencode/skills/iphone-use`；可指定 `--project /absolute/project/path`。加 `--global` 才写入用户专用目录 `~/.cursor/skills/iphone-use` 或 `$XDG_CONFIG_HOME/opencode/skills/iphone-use`（XDG 默认 `~/.config`）。即使全局安装，也应从实际工作项目运行检查，以覆盖项目副本。安装器不会写共享的 `.agents/skills`，不会修改插件清单、配置或缓存。

相同内容重复安装直接返回 `already-installed`；不同内容要求显式 `update`，禁止降级。扫描目标客户端的已知用户级、祖先项目级和嵌套项目级 skill 目录，发现同名 `iphone-use` 或旧 `agentsoma` 时打印路径并拒绝安装/更新。嵌套分类目录、已知兼容目录和符号链接别名也参与检查。未管理目录、本地改动/新增文件和链接目标不会被覆盖或卸载；没有强制覆盖参数。`check` 发现冲突或本地改动退出 2，扫描/操作异常退出 1，完成且无冲突退出 0。

指定 Codex、Claude Code、DeepSeek Harness 作为安装目标会被拒绝并提示使用现有插件，避免同一个客户端增加第二份 skill。这些插件可以与独立安装在 Cursor/OpenCode 专用目录中的 skill 共存。安装器无法枚举组织下发、远程、自定义目录或显式加载的插件；在新会话检查实际 skill 列表，保留一个启用来源。扫描失败不会被视为无冲突。迁移必须显式处理已有来源，安装器不自动卸载或禁用其他工具管理的内容。

不建议用第三方 `npx skills add ...` 替代上述命令：它不会运行我们的冲突检查，且目标 agent 参数不一定阻止共享目录被其他客户端扫描。通用 adapter 要求本机 shell、完整命令状态及真实 PNG 读图工具；云端 agent 或只有多模态模型但没有文件读图工具的客户端不满足真机操作条件。预览默认由 CLI 打开本机浏览器；设备会话和清理规则保持一致。

安装器源码在 `packages/iphone-use-skill`，发布包通过 `python3 scripts/build-skill-package.py NEW_OUTPUT_DIRECTORY` 从共享源生成，再在输出目录执行 `npm pack --ignore-scripts`。不要直接发布缺少 skill 资源的源码子目录。自动化测试覆盖打包后的 npm exec、重复安装、兼容目录冲突、更新、卸载和文件保留。安装成功、agent 实际加载成功、真机任务成功须分别验收；不能把一个客户端的结果视为全部客户端的真机兼容承诺。

## 首个任务

先按[设备准备](first-task.md#before-you-start)完成信任和解锁，在新会话调用上述 skill。标准模式直接发现设备并连接；Runner 才按提示 setup。可发送：

> 打开我的 iPhone 设置，进入“通用”，读取截图确认页面，然后断开会话。不要修改任何设置。

验收须包括发现设备、连接、发现/打开 App、读取实际 PNG、至少一次导航点击、读取新截图验证结果和正常断开。若本来就在“通用”，先返回再进入即可。手机界面语言可以不同；引用必须来自实际观察，不能照抄示例 `oN:eN`。

测试失败时，区分 `not_dispatched` 与可能已生效的 `unknown`；优先读取已经附带的有效观察，仅在缺失时重新截图；不能重复输入来补读输出。路径字符串和截图文件存在均不等于 agent 已读取图片。`--observe` 的 `action` 与 `observation` 分别判断，观察失败不覆盖动作事实。

## 默认实时预览

三个客户端共用同一份生命周期：任务所属会话连接成功后，在首次操作前默认启动一次预览。**Codex 执行 `preview --no-open`，再在内置浏览器打开返回的 URL；Claude Code 和 DeepSeek Harness 执行 `preview`，由 CLI 打开 Mac 默认浏览器。**不改变 CLI `connect` 本身，standard 和 runner 行为一致。

- 明确说“不要预览”“不要打开浏览器”即可跳过服务启动和开页，该选择在本任务重连后仍有效；不会写入全局偏好。
- 按 session ID 记录启动尝试和 URL，后台命令只续读、不重跑。复用会话时若已有预览，直接复用；后续操作或新一轮对话不再次开页。用户关闭页面后也不自动重开。
- 预检仅用 `preview --help` 检测能力。旧 CLI 不支持时跳过；启动失败只检查一次状态，必要时提供 URL，不反复重试、不自动升级或切模式。默认预览不是独立后台 hook，而是 Agent 执行的技能步骤。
- Codex 没有内置浏览器工具时（例如纯终端环境），提供 URL，不擅自改开系统浏览器。记录开页尝试和已返回的标签 ID，失败或结果不确定时不再开第二页。
- 用户指定浏览器时使用 `--no-open` 后只打开一次 URL。预览用于用户观看；Agent 仍读取原始截图、使用新引用操作。启动/停止预览后重新观察。
- 任务结束或取消时断开自己持有的会话，核对预览、媒体与控制资源清理。有准确的任务自建标签句柄时可关闭该标签；没有浏览器工具时，失效页面可能留在浏览器中。关闭标签不等于停止服务，也不应退出整个浏览器。

示例：“用 runner 打开设置并进入通用，让我在电脑上看操作过程”；或“打开设置并进入通用，不要预览”。首次默认开页无需再问一次偏好，但仍遵守客户端命令权限。

安装、冲突处理和 Cursor 模型驱动真机结果见[通用 skill 验收记录](universal-skill-acceptance.md)。
维护者通过 [CI 发布流程](skill-release.md)发布新的 npm skill 版本，本机仅用于验收。

## 升级生效与卸载

新插件身份为 `iphone-use@iphone-use`。启用前停用旧 AgentSoma 插件，避免同一手机任务重复匹配；若曾另行安装 `~/.codex/skills/agentsoma`，还需在 Codex 的技能配置中单独停用这份独立 skill，插件停用不会影响它；确认新插件可用后再按需移除旧插件。CLI 与插件版本号独立：本分支的插件/通用 skill 工作流版本为 0.1.13。只升级 Homebrew 不会更新插件。各端更新插件后需开始新会话，确认安装缓存中的 workflow version 为 0.1.13，并包含 `dynamic_or_transitioning` 和 `--dynamic-target` 指引。旧会话不会自动替换已加载的 skill；不要修改已发布版本的附件。

先断开活跃设备会话，再 `brew update` / `brew upgrade iphone-use`。插件另外更新：

```sh
# Codex：更新仓库快照后重新安装插件。
codex plugin marketplace upgrade iphone-use
codex plugin add iphone-use@iphone-use

# Claude Code：更新仓库快照后更新插件。
claude plugin marketplace update iphone-use
claude plugin update iphone-use@iphone-use
```

以上更新命令适用于跟随默认分支的 Git 来源。若曾固定 `v0.2.0` 标签，更新仍会留在该标签：Codex CLI 0.146.0 需要先 `codex plugin marketplace remove iphone-use`，再 `codex plugin marketplace add HughLee824/iphone-use`；Claude Code 2.1.250 可再次 `claude plugin marketplace add HughLee824/iphone-use` 切回默认分支。然后执行上面的更新命令。此处更换 Codex marketplace 来源会保留已安装插件，不是卸载插件。

重开客户端会话，核对安装缓存中 SKILL.md 的 workflow version，而非只看开发目录。发布方修改 skill/adapter 时必须同步三份客户端清单版本，再运行同步脚本更新仓库根清单；Claude 的版本缓存尤其需要版本号变化。正式包的 Runner 变化或签名过期时按 CLI 提示重新 setup。

卸载插件：`codex plugin remove iphone-use@iphone-use` / `claude plugin uninstall iphone-use@iphone-use`。若不再使用项目 marketplace，再分别 `codex plugin marketplace remove iphone-use` / `claude plugin marketplace remove iphone-use`。这些操作不卸载 CLI、不删除签名资料。

## 维护者本地验证

canonical skill 位于 `skills/iphone-use/`；已提交的自包含副本位于 `plugins/iphone-use/skills/iphone-use/`。修改源文件后执行：

```sh
python3 scripts/sync-plugin.py
python3 scripts/sync-plugin.py --check
python3 -m unittest discover -s scripts/tests -v
node --test scripts/tests/test_dsh_plugin.mjs scripts/tests/test_agent_templates.mjs
```

`--check` 在副本有遗漏或漂移时失败。Codex/Claude 的 Git 插件安装不需要额外的 Python 或 Node；DeepSeek 使用 Harness 自带的 JavaScript runtime。生成独立 ZIP 和校验文件：

```sh
python3 scripts/sync-plugin.py --archive .build/plugins
```

Codex/Claude 本地 marketplace 安装使用**仓库根目录**：`codex plugin marketplace add /absolute/path/to/iphone-use` 或 `claude plugin marketplace add /absolute/path/to/iphone-use`，随后执行对应安装命令。Claude 也支持 `claude --plugin-dir /absolute/path/to/iphone-use/plugins/iphone-use` 或解压后的自包含目录。DeepSeek 安装的是 `plugins/iphone-use` 包目录。

`test_dsh_plugin.mjs` 默认执行不依赖 Harness 的单元与 npm 打包检查。可用 `DSH_RUNTIME_MODULES` 指向 Harness 的 `node_modules`，额外运行真实 registry 集成测试；桌面包位于 ASAR 内，需要它自己的 Electron runtime 读取：

```sh
ELECTRON_RUN_AS_NODE=1 \
DSH_RUNTIME_MODULES='/Applications/DeepSeek Harness.app/Contents/Resources/app.asar/dsh/node_modules' \
'/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness' \
  --test scripts/tests/test_dsh_plugin.mjs
```

该测试使用临时插件副本，不连接设备或启动模型，也不修改用户 profile。

对通过公开渠道安装的包，使用同一个真实 runtime 运行 `scripts/verify-dsh-install.mjs /absolute/path/to/profile/node_modules/dsh-iphone-use`，验证已安装文件而非 checkout。分别为 npm 与 GitHub 来源创建隔离的 `DSH_HOME`/profile，安装后用 `--dump-config` 核对 bundle 层，再执行该脚本，最后通过 CLI 卸载并确认配置层与包目录消失。若安装时指定了 `--store-dir`，卸载时也传入同一个目录。

独立 ZIP 包含 Codex/Claude 清单、DeepSeek 的 package.json、patch、注册入口与中英文显示元数据、README、MIT LICENSE 和完整 skill。不要将插件目录外的共享文件或软链接当成已打包依赖。正式发布验收必须覆盖各客户端的实际分发渠道、任务和升级，不能用本地加载成功代替公开分发验收。

本阶段使用项目自有公开 Git marketplace；没有宣称已进入 Codex 或 Claude 官方目录。目录提交是另外的发布事项。

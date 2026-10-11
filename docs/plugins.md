# Codex / Claude Code 插件

> CLI 0.2.0、Homebrew 和新名称网站已公开；Release 附带插件 0.1.4。源码插件的 0.1.5 是文档修订版，本次不发布新 ZIP 或替换已有资产。两种客户端的公开安装、缓存升级和真机任务验证仍未在本次发布中补做，详见[渠道状态](rename-to-iphone-use.md)。


[公开网站](https://agentsoma.dev) → [安装 CLI](install.md) → 安装本页插件 → [选择模式并连接](first-task.md#connect-in-standard-mode) → 首个真机任务。完整英文路径见 [First task](first-task.md)。

插件是 **CLI + skill** 封装，共用设备操作契约，分别适配 Codex 的命令执行、后台续读和图片工具，以及 Claude Code 的 Bash、TaskOutput 和 Read。它不含 CLI、不创建开发签名、不自动接入手机，也不要求 MCP 服务。

## 先检查环境

新安装使用已发布的 CLI 0.2.0。旧 `agentsoma` formula 用户先断开会话、卸载旧 formula，再安装新 formula；遇到 Tap Trust 拒绝时按[单公式信任提示](install.md#homebrew-单公式信任)处理，不默认信任整个 Tap。

```sh
brew install HughLee824/tap/iphone-use
command -v iphone-use
iphone-use --version
```

正式版及开发工作流的环境以 [first-task](first-task.md) 为准：标准模式已验收 Apple Silicon / macOS 27、Xcode 27、iOS 27；需要设备信任、Developer Mode 和解锁。**只有 Runner 模式需要开发签名与 setup**。包内只读 `scripts/preflight.sh` 检查一次 CLI、Xcode 和输出能力，随后复用检测结果。

本地候选包不在 PATH 时，通过 `IPHONE_USE_CLI=/absolute/path/to/bin/iphone-use sh /absolute/path/to/skill/scripts/preflight.sh --candidate` 检查；源码 `development` 版本使用 `--source`。设备调用继续使用同一个可执行文件。不要为了通过版本检查切到另一个已安装版本。preflight 的兼容版本下限仍为 CLI 0.1.0，但新安装应使用已发布的 iPhone-use 0.2.0；旧 AgentSoma 0.1.0 的版本号不能证明它支持标准模式。

安装后重启原本已打开的客户端，使其取得更新的 PATH。插件安装成功不等于 signing/setup 成功。免费 Personal Team 和全新 Mac 配置仍未验收；详见[前置条件和签名](first-task.md#before-you-start)。

## Codex 安装

以下是终端命令，已核对 Codex CLI 0.146.0。使用支持 `codex plugin --help` 的版本：

```sh
codex plugin marketplace add HughLee824/iphone-use
codex plugin add iphone-use@iphone-use
codex plugin list --marketplace iphone-use --json
```

确认插件已启用，在 Codex 桌面插件入口选择 iPhone-use 并开始新任务，或在新任务中调用 **`$iphone-use:iphone-use`**。如果桌面列表未刷新，重启客户端。如果 CLI 没有 `plugin add`，使用兼容版本或通过已添加 marketplace 的桌面插件目录安装；不要套用 Claude 的 `plugin install` 命令。

仓库索引位于 `.agents/plugins/marketplace.json`，`source.path` 相对仓库根目录解析到 `./plugins/iphone-use`。插件身份由 `.codex-plugin/plugin.json` 定义。[官方格式与安装说明](https://developers.openai.com/plugins/build/plugins)。

## Claude Code 安装

在终端执行：

```sh
claude plugin marketplace add HughLee824/iphone-use
claude plugin install iphone-use@iphone-use
claude plugin list --json
```

开始新的 Claude Code 会话，调用 **`/iphone-use:iphone-use`**。交互模式中也可使用 `/plugin marketplace add HughLee824/iphone-use` 和 `/plugin install iphone-use@iphone-use`；若安装结果要求 reload，按提示执行。

仓库索引位于 `.claude-plugin/marketplace.json`，插件同样从 `./plugins/iphone-use` 安装，读取自己的 `.claude-plugin/plugin.json`。两份清单共用一套内置 skill，不会引用维护者 checkout。[官方插件说明](https://code.claude.com/docs/en/plugins)与[marketplace 说明](https://code.claude.com/docs/en/plugin-marketplaces)。

添加 marketplace 时使用整个 Git 仓库或本地根目录，不使用 GitHub raw JSON 地址：单独下载索引不会携带相对路径下的插件文件。

## 首个任务

先按[设备准备](first-task.md#before-you-start)完成信任和解锁，在新会话调用上述 skill。标准模式直接发现设备并连接；Runner 才按提示 setup。可发送：

> 打开我的 iPhone 设置，进入“通用”，读取截图确认页面，然后断开会话。不要修改任何设置。

验收须包括发现设备、连接、发现/打开 App、读取实际 PNG、至少一次导航点击、读取新截图验证结果和正常断开。若本来就在“通用”，先返回再进入即可。手机界面语言可以不同；引用必须来自实际观察，不能照抄示例 `oN:eN`。

测试失败时，区分 `not_dispatched` 与可能已生效的 `unknown`；优先读取已经附带的有效观察，仅在缺失时重新截图；不能重复输入来补读输出。路径字符串和截图文件存在均不等于 agent 已读取图片。`--observe` 的 `action` 与 `observation` 分别判断，观察失败不覆盖动作事实。

## 升级生效与卸载

新插件身份为 `iphone-use@iphone-use`。启用前停用旧 AgentSoma 插件，避免同一手机任务重复匹配；确认新插件可用后再按需移除旧插件。CLI 与插件版本号独立：0.2.0 Release 中的插件仍是 0.1.4，Git 来源的源码修订版为 0.1.5，安装后应核对缓存版本，不凭仓库版本推断已升级。

先断开活跃设备会话，再 `brew update` / `brew upgrade iphone-use`。插件另外更新：

```sh
# Codex：更新仓库快照后重新安装插件。
codex plugin marketplace upgrade iphone-use
codex plugin add iphone-use@iphone-use

# Claude Code：更新仓库快照后更新插件。
claude plugin marketplace update iphone-use
claude plugin update iphone-use@iphone-use
```

重开客户端会话，核对安装缓存中 SKILL.md 的 workflow version，而非只看开发目录。发布方修改 skill/adapter 时必须同步两份清单版本；Claude 的版本缓存尤其需要版本号变化。正式包的 Runner 变化或签名过期时按 CLI 提示重新 setup。

卸载插件：`codex plugin remove iphone-use@iphone-use` / `claude plugin uninstall iphone-use@iphone-use`。若不再使用项目 marketplace，再分别 `codex plugin marketplace remove iphone-use` / `claude plugin marketplace remove iphone-use`。这些操作不卸载 CLI、不删除签名资料。

## 维护者本地验证

canonical skill 位于 `skills/iphone-use/`；已提交的自包含副本位于 `plugins/iphone-use/skills/iphone-use/`。修改源文件后执行：

```sh
python3 scripts/sync-plugin.py
python3 scripts/sync-plugin.py --check
python3 -m unittest discover -s scripts/tests -v
node --test scripts/tests/test_agent_templates.mjs
```

`--check` 在副本有遗漏或漂移时失败。直接安装 Git 仓库时客户端无需 Python 或 Node；它们仅用于开发验证。生成独立 ZIP 和校验文件：

```sh
python3 scripts/sync-plugin.py --archive .build/plugins
```

本地安装使用**仓库根目录**：`codex plugin marketplace add /absolute/path/to/iphone-use` 或 `claude plugin marketplace add /absolute/path/to/iphone-use`，随后执行对应安装命令。Claude 也支持 `claude --plugin-dir /absolute/path/to/iphone-use/plugins/iphone-use` 或解压后的自包含目录。

独立 ZIP 可包含两份客户端清单、README、MIT LICENSE 和完整 skill。不要将插件目录外的共享文件或软链接当成已打包依赖。正式发布验收必须再从公开 Git 源安装、运行任务并确认升级，不能用 `--plugin-dir` 成功代替 marketplace 分发验收。

本阶段使用项目自有公开 Git marketplace；没有宣称已进入 Codex 或 Claude 官方目录。目录提交是另外的发布事项。

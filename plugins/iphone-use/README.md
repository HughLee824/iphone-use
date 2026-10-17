# iPhone-use plugin

> Workflow 0.1.13 adds a portable agent adapter shared with the separate `iphone-use-skill` npm installer for Cursor/OpenCode. CLI and skill versions are independent; see the installation guide for channel-specific acceptance results.


Eyes and hands for agents operating a real iPhone. This self-contained package supports **Codex**, **Claude Code**, and **DeepSeek Harness** through one shared skill and client adapters. For new installations, use the published iPhone-use CLI, full Xcode on a Mac, and a trusted, unlocked iPhone with Developer Mode. Only Runner mode requires local Apple development signing; standard mode needs no Runner setup. See the first-task guide for the currently validated macOS/iOS environment.

[Website](https://iphone-use.com) · [First task](https://github.com/HughLee824/iphone-use/blob/main/docs/first-task.md) · [中文安装指南](https://github.com/HughLee824/iphone-use/blob/main/docs/plugins.md)

Install the CLI with `brew install HughLee824/tap/iphone-use`. Migrate from the old formula and resolve any Tap Trust refusal using the [installation guide](https://github.com/HughLee824/iphone-use/blob/main/docs/install.md#homebrew-单公式信任); trust only a reviewed formula, not the entire Tap by default. Installing this plugin does not install the CLI, log in to Apple, or provision a device. Read `skills/iphone-use/SKILL.md` for the environment check and task workflow. All referenced local files are included; the installed plugin does not depend on the maintainer's checkout.

From the public Git repository:

```sh
# Codex CLI 0.146.0 command names; use a release exposing `codex plugin`.
codex plugin marketplace add HughLee824/iphone-use
codex plugin add iphone-use@iphone-use

# Claude Code
claude plugin marketplace add HughLee824/iphone-use
claude plugin install iphone-use@iphone-use
```

Disable the old AgentSoma plugin before enabling iPhone-use to avoid duplicate device instructions. CLI and plugin versions are independent. Start a new client session. Invoke `$iphone-use:iphone-use` in Codex or `/iphone-use:iphone-use` in Claude Code, followed by:

> Open Settings on my iPhone, navigate to General, read the screenshot to verify the page, then disconnect. Do not change any settings.

For offline/local authoring, Claude Code can load this folder with `claude --plugin-dir /absolute/path/to/iphone-use`. Codex installs from a marketplace root containing this folder; see the first-task guide. Public distribution is through the project's own Git marketplace. This is not an official directory listing.

## DeepSeek Harness

This package targets Harness 0.2.1-rc.1 (`engines.dsh`: `>=0.2.1-rc.1 <0.3.0`). It uses the official [bundle format](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/develop/basic/publish.md) and skill registry; no build or installation scripts are needed.

In **Add plugin**, enter either **`dsh-iphone-use`** (Official npm registry) or **`https://github.com/HughLee824/iphone-use`**. Both sources install the same named bundle. CLI equivalents:

```sh
# Use your actual profile: desktop for the desktop app, web for the Web UI.
dsh plugin --profile desktop add dsh-iphone-use
# Or install from GitHub:
dsh plugin --profile desktop add https://github.com/HughLee824/iphone-use
dsh --profile desktop --dump-config
```

If the desktop CLI is not on PATH, use `/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh`. Restart Harness, start a new session, and ask it to use the `iphone-use` skill for the Settings task above. Read [the Harness adapter](skills/iphone-use/references/deepseek-harness.md) for `bash`, `job_output`, and `read_image` behavior. The shell and image reader must access the device-connected Mac.

The repository root exposes this same bundle through a generated `package.json`, so GitHub installation needs no subdirectory suffix. npm releases are packed and published from the repository root. Local development can still install this directory or a `.tgz`; linked directories must remain in place. To update, remove `dsh-iphone-use`, install again from the chosen source, and restart Harness. Uninstall with `dsh plugin --profile desktop remove dsh-iphone-use`.

The control path runs locally on the Mac and iPhone. The selected AI client's model may receive screenshots and UI text under that client's data settings. Review what is visible before asking it to work with private apps.

With plugin 0.1.8, after a successful connection the agent starts one local preview per task-owned session in either mode, using the built-in browser in Codex (`preview --no-open` followed by one in-app open) and the Mac default browser in Claude Code and DeepSeek Harness (`preview`). Codex without an in-app browser tool returns the URL without opening a system browser. Say “no preview” or “do not open a browser” to skip both service startup and page opening. Existing previews and prior attempts are reused rather than reopened. Older CLIs without preview keep the phone-control workflow. Preview failure is reported without retry loops or blocking otherwise-ready control. At task end, disconnect stops the owned preview/media; an inactive browser tab can remain when no exact tab handle is available. Preview does not replace the agent's screenshot and reference checks.

Plugin 0.1.13 must be installed separately from a CLI upgrade. Update the marketplace and plugin, then start a new client session and verify workflow version 0.1.13 in the installed skill. See the [upgrade guide](https://github.com/HughLee824/iphone-use/blob/main/docs/plugins.md#升级生效与卸载). A changing video frame is usable evidence; follow the scoped controls and fresh-image checks in the skill instead of terminating the app to recover.

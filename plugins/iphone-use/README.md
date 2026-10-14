# iPhone-use plugin

> CLI 0.3.1 and plugin 0.1.7 are public. This branch prepares plugin 0.1.8 with a shared default live-preview workflow for Codex and Claude Code; it is not published yet and does not replace existing release assets.


Eyes and hands for agents operating a real iPhone. This self-contained package supports **Codex** and **Claude Code** through one skill and two client adapters. For new installations, use the published iPhone-use CLI **0.3.1**, full Xcode on a Mac, and a trusted, unlocked iPhone with Developer Mode. Only Runner mode requires local Apple development signing; standard mode needs no Runner setup. See the first-task guide for the currently validated macOS/iOS environment.

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

The control path runs locally on the Mac and iPhone. The selected AI client's model may receive screenshots and UI text under that client's data settings. Review what is visible before asking it to work with private apps.

With plugin 0.1.8, after a successful connection the agent starts one local preview per task-owned session in either mode, using the built-in browser in Codex (`preview --no-open` followed by one in-app open) and the Mac default browser in Claude Code (`preview`). Codex without an in-app browser tool returns the URL without opening a system browser. Say “no preview” or “do not open a browser” to skip both service startup and page opening. Existing previews and prior attempts are reused rather than reopened. Older CLIs without preview keep the phone-control workflow. Preview failure is reported without retry loops or blocking otherwise-ready control. At task end, disconnect stops the owned preview/media; an inactive browser tab can remain when no exact tab handle is available. Preview does not replace the agent's screenshot and reference checks.

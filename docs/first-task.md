# Your first iPhone task

> This guide describes the published Runner workflow. This checkout also adds standard (screenshot/HID) mode and `~/.agentsoma/config.json`; see [control modes](control-modes.md) before configuring a source build. These mode-management changes are not yet released. Standard mode does not require Runner signing/setup.


Start at the [AgentSoma website](https://agentsoma.dev). This guide follows the public **Homebrew → client plugin → device setup → first task** path. It works outside the AgentSoma source checkout.

[中文安装](install.md) · [中文插件指南](plugins.md) · [Troubleshooting](#when-something-stops)

## Before you start

- **Mac:** the release package targets Apple Silicon and macOS 15+.
- **Xcode:** install full Xcode, open it once to finish installation, and select it in Xcode Settings → Locations. `xcode-select -p` should end in the Xcode application's `Contents/Developer`. Command Line Tools alone are insufficient.
- **iPhone:** connect with USB, trust the Mac, enable Developer Mode, and keep it unlocked during setup and tasks.
- **Signing:** a usable Apple Development certificate **with its private key in Keychain**, and an iOS development provisioning profile that authorizes this certificate, device, and Runner bundle ID. Setup uses existing signing materials; it does not log in to Apple or create them.
- **Client:** an installed, authenticated local Codex or Claude Code client with command execution and image-reading tools. A hosted chat without local Mac tools cannot operate this device.

The public CLI 0.1.0 was validated on Apple Silicon / macOS 15.0.1 / Xcode 16.0 / iPhone 12 Pro / iOS 26.6.1, using an existing paid development team's signing. These are tested configurations, not a promise that every newer Xcode or iOS release works. Fresh-Mac and free Personal Team provisioning/renewal remain unverified. The Mac CLI is ad-hoc signed, without Developer ID signing or notarization; use the documented Terminal/Homebrew download path. See [release acceptance](release-setup.md) and [current limitations](../README.md#current-limitations).

## Install the CLI

Run in Terminal on the Mac connected to your phone:

```sh
brew install HughLee824/tap/agentsoma
command -v agentsoma
agentsoma --version
```

The plugin requires stable CLI **0.1.0 or later**. Homebrew installs the complete CLI and precompiled Runner; it does not connect to the phone. If you prefer a versioned archive, follow [manual installation and checksum verification](install.md#手动下载安装). Keep the full `bin` and `libexec` package layout.

If your client was already running before installation, restart it so it inherits the updated PATH. Confirm `agentsoma --version` from the client's own command tool as well as Terminal.

## Install a client plugin

The repository is a public Git marketplace. Add **the repository**, not a raw `marketplace.json` URL; plugin paths resolve inside the downloaded repository. This distribution is separate from submission to either client's official directory.

### Codex

Use a Codex version exposing `codex plugin --help`. These command names were checked against CLI **0.146.0**:

```sh
codex plugin marketplace add HughLee824/AgentSoma
codex plugin add agentsoma@agentsoma
codex plugin list --marketplace agentsoma --json
```

Confirm the installed entry is enabled. Start a **new Codex task**, select the AgentSoma plugin if using the desktop UI, and invoke **`$agentsoma:agentsoma`**. The namespaced skill avoids confusion with a manually copied `$agentsoma` skill. Restart the desktop client if its plugin picker has not refreshed.

If `plugin` or `add` is unavailable, use a compatible Codex CLI release or install from the added marketplace through the desktop plugin directory. Check the client's actual `--help`; do not substitute Claude's `plugin install` command into Codex. See the [official plugin packaging and marketplace documentation](https://developers.openai.com/plugins/build/plugins).

### Claude Code

In Terminal:

```sh
claude plugin marketplace add HughLee824/AgentSoma
claude plugin install agentsoma@agentsoma
claude plugin list --json
```

Start a **new Claude Code session** and invoke **`/agentsoma:agentsoma`**. The same commands are available interactively as `/plugin marketplace add HughLee824/AgentSoma` and `/plugin install agentsoma@agentsoma`; follow the install summary if it requests a plugin reload. See [Claude Code plugins](https://code.claude.com/docs/en/plugins) and [marketplace installation](https://code.claude.com/docs/en/plugin-marketplaces).

Both plugins install instructions and client adapters. They do not install the CLI, create a signed Runner, or grant access to the Mac or iPhone. Keep the client's normal command approvals. The environment check is read-only; first-time trust, Developer Mode, Apple sign-in, and system permission dialogs require you to act on your devices.

## Prepare the device

Run in Terminal, or ask your agent to run the same steps with its command tool:

```sh
agentsoma devices
# Replace the placeholder with the id returned for your intended iPhone.
export IOS_UDID='YOUR_DEVICE_ID'
agentsoma setup --device "$IOS_UDID"
```

Choose explicitly if more than one phone is listed. Setup re-signs the bundled Runner with your local development credentials, installs it, then verifies a handshake, screenshot capture, and clean shutdown. Continue only when setup returns `ok: true`. `compiled: false` means no source compilation was needed.

If a matching provisioning profile is not already cached by Xcode, obtain one through your development team's [Apple development profile workflow](https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile). It must include the intended device and certificate. The default Runner app bundle ID is `com.agentsoma.runner.xctrunner`.

When setup asks you to resolve a signing ambiguity, use your actual values:

```sh
agentsoma setup --device "$IOS_UDID" \
  --profile '/absolute/path/to/development.mobileprovision' \
  --team 'YOUR_TEAM_ID'
```

For a profile authorizing your own bundle ID, also pass `--bundle-id 'com.example.agentsoma.xctrunner'`. If needed, `--identity` accepts the SHA-1 identifier of a matching development certificate, not private key contents. See [signing details](onboarding.md#发布包-setup). Preparation is saved for later sessions. Do not run `build-runner` as a workaround for a release-package setup error; source development is a separate [workflow](onboarding.md#源码开发入口).

## Run the first task

In a fresh client session, invoke its AgentSoma skill and send:

> Open Settings on my iPhone, navigate to General, read the screenshot to verify the page, then disconnect. Do not change any settings.

If you have multiple connected phones, include which one to use. Keep the phone unlocked. The agent should:

1. Load the installed skill and its client adapter; verify the CLI and full Xcode.
2. Discover the device, connect, and retain the returned device session ID.
3. Find Settings using `apps --query`, open the returned bundle ID, observe, and **open the actual PNG** with its image tool.
4. Tap General using a current observed reference; if it is already on General, go back and re-enter for a first-click check. UI labels may be localized.
5. Read the new screenshot and confirm General is visible. It must not treat a successful command or screenshot filename as visual confirmation.
6. Disconnect the session and check the cleanup response.

**Pass:** the agent read the screenshots, executed a navigation action, verified General on the real phone, and reported clean disconnection. No settings need to be changed. Running `devices`, validating a manifest, or receiving `completed` from a tap alone is not this acceptance test.

Command tools may return a background job ID. That ID differs from AgentSoma's device session. The plugin tells the agent to collect the **original** command's completed output instead of relaunching it. Codex reads PNGs with its image tool; Claude Code reads them with Read. For `unknown` actions, it observes first and does not blindly retry.

## When something stops

| Symptom | Next step |
| --- | --- |
| `agentsoma: command not found` in the client | Verify the Terminal installation, check the client's PATH, and restart the client. The plugin does not contain the executable. |
| Client cannot parse its own configuration | Resolve the CLI/app version or configuration mismatch first; this error occurs before plugin loading. Do not replace your full configuration with a sample. |
| Codex says the selected model requires a newer CLI | Update Codex using its original installation method, or select a model supported by the installed CLI. This is a client/model compatibility error before the device task. |
| Plugin installs but the skill is absent | Confirm the plugin is enabled, use the namespaced invocation, and start a new session. For updates, refresh the marketplace **and** installed plugin. |
| `setup_required` / `setup_update_required` | Run the indicated `setup --device ID` with the release CLI, then connect again. |
| `profile_not_found` or a signing mismatch | Prepare the matching development profile or pass the correct `--profile`, `--team`, `--bundle-id`, or `--identity`. See [signing errors](onboarding.md#常见接入错误). |
| `coredevice_initialization_timeout` | Follow the diagnostic: compare `agentsoma devices` once in an approved local host context. A sandbox timeout does not prove the phone is disconnected. Keep permissions scoped to the required commands; do not reset services or disable the client's sandbox globally. |
| Locked phone or failed trust | Unlock the iPhone, finish trust/Developer Mode dialogs, and connect again after resolving the stated error. |
| `not_dispatched` | Read the error and `requiresObservation`. Correct the request or acquire fresh references as directed. |
| `unknown` | The input may have happened. Observe, read the PNG, and choose the next action from actual state. Do not replay blindly. |
| An action succeeds but its observation fails | Preserve `action.outcome`; recover with `observe`. Repeating input does not repair a screenshot read. |

If a task stops, ask the agent to disconnect its session if possible and report the command, error, and unverified outcome. Include client, CLI, Xcode, macOS, and iOS versions in an issue. Keep device identifiers, personal screenshots, logs, and profiles private.

## Upgrade or remove

Disconnect active device sessions before upgrading the CLI:

```sh
brew update
brew upgrade agentsoma
agentsoma --version
```

Refresh the client package separately:

```sh
# Codex
codex plugin marketplace upgrade agentsoma
codex plugin add agentsoma@agentsoma

# Claude Code
claude plugin marketplace update agentsoma
claude plugin update agentsoma@agentsoma
```

Start a new session and check the workflow version in the **installed** skill. Editing source or refreshing a marketplace alone may leave a cached plugin in use. Runner changes or expired signing can require `agentsoma setup` again; follow the CLI response.

To remove the plugin, use `codex plugin remove agentsoma@agentsoma` or `claude plugin uninstall agentsoma@agentsoma`. Remove its marketplace separately if desired. `brew uninstall agentsoma` removes the CLI package while preserving local device preparation; [complete removal](install.md#升级和卸载) is optional.

Device control runs locally. Your chosen client can send screenshots and UI text to its model provider according to its data settings. Review what is on screen before using private apps.

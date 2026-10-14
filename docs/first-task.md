# Your first iPhone task

> This guide starts from the published iPhone-use CLI 0.2.1. The Release and Homebrew channels are available; plugin distribution and client verification are tracked separately in [channel status](rename-to-iphone-use.md). Older AgentSoma releases do not gain standard mode from these instructions. Release 0.2.1 includes the approved iphone-use Logo in its Runner.

Start with **standard mode**: screenshots and native HID, without Runner installation, signing or `setup`. Choose **runner mode** explicitly when you want XCTest and available element references. Both modes use the same CLI and persistent session; they never switch control routes automatically.

[中文安装](install.md) · [Mode configuration](control-modes.md) · [Runner signing](onboarding.md#发布包-setup)

## Before you start

- **Standard mode:** the current adapter targets macOS 27 and iOS 27. Acceptance uses Apple Silicon, Xcode 27 and iPhone 12 Pro; other combinations are not implied by the package's minimum deployment version.
- **Xcode:** install full Xcode, finish its first-launch installation, and select it in Xcode Settings → Locations. `xcode-select -p` should identify that Xcode's `Contents/Developer`. Command Line Tools alone are insufficient.
- **iPhone:** connect with USB, trust this Mac, enable Developer Mode and keep the phone unlocked. Finish system authorization on the devices yourself.
- **Runner only:** existing Apple Development signing credentials and a matching development provisioning profile are needed. Standard mode does not use them. Free Personal Team and fresh-Mac provisioning remain unverified.

## Install the CLI

Install the public package with `brew install HughLee824/tap/iphone-use`, or download and verify the 0.2.1 archive from [GitHub Releases](https://github.com/HughLee824/iphone-use/releases/tag/v0.2.1). When migrating from the old `agentsoma` formula, disconnect active sessions and uninstall that formula first because both commands conflict. If Homebrew refuses to read the legacy conflict formula as untrusted, review it and explicitly trust only that formula before retrying; see [Homebrew trust and installation](install.md#homebrew-单公式信任). For a manual package, retain its `bin` and `libexec` layout and add `bin` to PATH. It can run outside the source repository. Local candidate packages and `swift build` remain separate development paths.

```sh
command -v iphone-use
iphone-use --version
iphone-use connect --help
xcode-select -p
xcrun --find devicectl
iphone-use config get mode
iphone-use devices
```

Confirm that the executable supports `--mode standard|runner`. Check any `DEVELOPER_DIR` override if the effective tools differ from `xcode-select -p`. These checks do not start a Runner or media session; `config get mode` does not create preferences. A successful version/help command does not prove device connectivity. The public package and Homebrew installation checks do not establish fresh-Mac or physical-device acceptance for every environment.

## Connect in standard mode

Choose the intended device from `devices`; do not guess if several phones are listed.

```sh
export IOS_UDID='DEVICE_ID_FROM_DEVICES'
iphone-use config get mode
iphone-use connect --device "$IOS_UDID" --mode standard
```

The explicit option selects this session only. Fresh users also default to standard when `--mode` is omitted; valid legacy preferences/prepared Runner state can retain runner mode. To make a deliberate persistent choice, run `iphone-use config set mode standard`. Preferences are stored in `~/.iphone-use/config.json` and affect new sessions only.

Before input, require `mode=standard`, `backend=apple-native` and `result.controlAvailable=true` in connect/status. `ok:true` can describe an observation-only session; read `controlErrorCode` when control is unavailable.

No `setup`, signing certificate, provisioning profile or `.xctestrun` is needed for this path. End another client's Device Hub/control session yourself if `native_media_busy` is returned; iPhone-use never stops foreign media sessions.

## Observe, act and verify

For a first manual test, open a harmless page in the app you intend to use, with a clearly visible navigation button. The development acceptance uses the ordinary iPhone-use Probe and its counters; that signed test app is not a requirement for controlling other installed apps.

```sh
export SESSION='SESSION_FROM_CONNECT'
iphone-use --session "$SESSION" observe
```

Open the returned PNG. Standard mode returns a screenshot observation such as `o1`, without AX element references. Read the screenshot dimensions and use **screen-point coordinates** for `--x` and `--y`. Map a point selected in the original PNG into the returned `screen_points` rectangle; do not pass PNG pixels or resized-preview coordinates directly. For a full-screen image, `x = screen.x + pixelX * screen.width / imageWidth`, and similarly for y. Use the current observation dimensions, not a fixed scale factor. Replace every placeholder below with the current observation and a button you have actually seen:

```sh
iphone-use --session "$SESSION" tap OBSERVATION_ID --x POINT_X --y POINT_Y --observe
# Read the new observation's PNG and confirm the expected page/counter changed.
iphone-use --session "$SESSION" disconnect
```

Pass means the intended visible effect happened and cleanup was confirmed, not just that `tap` exited successfully. Every next action uses the latest inspected, valid observation. Reuse a successful attached observation instead of capturing it again. An `unknown` result requires inspecting that observation and judging the effect, never automatic replay. If the action succeeds but its following observation fails, recover with `observe`, not another tap.

## Optional: Runner mode

For a precompiled package, prepare its Runner with your own signing materials, then choose the mode explicitly:

```sh
iphone-use setup --device "$IOS_UDID"
iphone-use connect --device "$IOS_UDID" --mode runner
```

`setup` verifies signing, connection, screenshot and cleanup before saving preparation. It does **not** change the default mode. Use `config set mode runner` if you want future connections without `--mode` to use Runner. Signing choices and the separate source workflow (`build-runner`, then `connect --xctestrun`) are described in [onboarding](onboarding.md).

Runner observations also include available elements; actions can use current references such as `o1:e9` where supported. Consult `connect/status` support fields and [actions](actions.md), rather than assuming the routes have identical text semantics. Explicit recording in both modes uses the shared owned native media recorder; Runner input remains XCTest.

## Optional: external agent

A client with local Mac command execution and PNG-reading tools can perform the same loop. See [client plugins](plugins.md) for the separate plugin workflow. The plugin does not install the CLI or grant device access. CLI 0.3.1 and its plugin 0.1.7 archive are public. The source branch prepares plugin 0.1.8 (not yet published): both clients default to one local preview after connection (Codex built-in browser; Claude Code Mac default browser), honor explicit opt-out, reuse existing previews and clean up on disconnect. See [preview lifecycle](plugins.md#默认实时预览插件-018-候选). CLI and plugin updates remain independent; manual CLI `connect` does not open a browser.

Tell the agent which device and mode to use, and the intended task. It must view the PNG before selecting coordinates, keep the returned session and observation IDs, inspect the actual result, and disconnect its own session. A command tool's background job ID is not an iPhone-use session ID; collect the original command's output instead of starting it again.

## When something stops

| Result | Next step |
| --- | --- |
| CLI not found, or `--mode` unknown | Check `command -v iphone-use`, PATH and the actual package version. Restart an already-running client if needed. |
| `xcode_unavailable` | Select full Xcode in Settings → Locations, finish first-launch installation, and check any `DEVELOPER_DIR` override; retry read-only `devices`. No Runner setup is needed for standard. |
| `xcode_license_required` | Open Xcode and review the license/system prompts yourself, then retry `devices`. |
| `device_not_paired` | Connect by USB, unlock and complete Trust This Computer on the iPhone; run `devices` again. |
| `developer_mode_disabled` | Apple explicitly reported it disabled; enable Developer Mode on the phone and complete its system prompts before reconnecting. |
| `native_device_unavailable` | Some required device/tunnel facts were unavailable; inspect device discovery and authorization without assuming that permissions were denied. |
| `native_protocol_unsupported` | Check the supported macOS/iOS 27 toolchain. Do not silently switch to Runner. |
| `device_locked` or trust/authorization prompt | Complete the system prompt locally, then reconnect or refresh as directed. |
| `native_media_busy` | End the other client's device-control session, disconnect your own observation-only session if returned, then reconnect explicitly. |
| `runner_start_failed` | Inspect the returned log and the phone for an XCTest authorization prompt; timeout alone does not identify the cause. Complete any actual prompt yourself. |
| `setup_required` / signing error | These concern Runner mode. Check your selected mode; use Runner setup only when Runner is intended. |
| `coredevice_initialization_timeout` | Follow [discovery diagnostics](discovery.md#接入失败诊断). A restricted execution-context timeout does not prove the phone is disconnected. |
| `not_dispatched` | Correct the stated request/readiness problem and refresh observations when required. |
| `unknown` | Observe and inspect the actual effect before choosing a new action. |

Disconnect your own session when finished or blocked. Preserve errors and unverified outcomes; keep device identifiers, profiles and personal screenshots private. See [upgrade and removal](install.md#升级和卸载); updating the CLI never changes an active session's mode.

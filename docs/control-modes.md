# Control modes and user configuration

iPhone-use provides explicit mode selection. Use `--version` and `connect --help` to check the installed executable’s capabilities.

## Choose a mode

- **standard** → `apple-native`: screenshots, visual coordinate selection and native HID; Unicode/multiline input uses the device clipboard and HID Paste. It does not install/start a Runner or fall back to XCTest. Current acceptance requires the documented macOS/Xcode/iOS 27 environment, pairing, Developer Mode and an unlocked device. No Runner signing is needed for control; the signed Probe is only a development fixture. This is not a claim of no-Xcode or no-Developer-Mode support.
- **runner** → `xctest`: the existing signed XCTest Runner, screenshots and available element data. Existing setup/build-runner workflows remain. Both modes implement the main gestures, app lifecycle operations and shared native recording. Element access and text/key behavior differ; identical operation names do not promise identical behavior in every app.

```sh
iphone-use config get mode
iphone-use config set mode standard
iphone-use connect --device "$DEVICE"

# Override only this connection; do not change the saved default.
iphone-use connect --device "$DEVICE" --mode runner
# Or select Runner as the default for later connections.
iphone-use config set mode runner
```

`setup` still prepares/verifies Runner. It does not change an existing mode preference. If you previously selected standard, choose runner explicitly after setup. Source developers can continue to supply `--xctestrun /absolute/signed.xctestrun`.

## Standalone Runner over USB

Runner connects to the **already-installed** signed app. It launches once in the background using `devicectl --no-activate`, without an `xcodebuild test-without-building` process or an IDE-driven XCTest session. The existing Runner listens only on `127.0.0.1:47821`; the host opens a fresh usbmuxd stream for each authenticated JSON request. Only the selected UDID's `USB` entry is eligible. There is no wireless fallback, host forwarding listener, Appium/Python/iproxy dependency, or automatic replay of UI commands.

`setup` explicitly installs the prepared signed package and verifies it. Ordinary `connect` never installs or re-signs the app, changes Wireless Data, or takes over an already-running Runner. The supplied `.xctestrun` identifies the expected host bundle; the host validates the launched PID, authenticated session identity and live protocol capabilities before admitting commands. That handshake establishes compatibility, not a hash of every installed file. A missing app requires setup; a protocol mismatch requires matching CLI/Runner resources. Source developers must explicitly install the signed app returned by `build-runner` before connecting with its manifest.

Control no longer uses the device's CoreDevice tunnel IP as the Runner listener address. Preview and recording still acquire their own native CoreDevice media connection on demand. Disconnect closes media, requests authenticated shutdown, and confirms the owned Runner process has exited; it may terminate that exact PID/path if still running. It never terminates a replacement process merely because the bundle name matches. CoreDevice's PID-only termination retains a final lookup-to-signal race. Startup failures also save cleanup facts, including an unconfirmed launch or process exit.

`runner_usb_required` means no unique wired device was found. `runner_already_running` means an existing process must be released by its owner. `runner_start_failed` distinguishes an observed process exit from a bounded readiness timeout. Neither proves a passcode authorization or network-permission problem. Check device XCTest logs and the actual phone screen; never repeatedly ask for a nonexistent authorization prompt. Users complete any real system authentication themselves and never share their passcode.

The source Runner also guards XCTest's first startup Home event against the password-dialog dismissal race: it waits for a settled active application before sending that one event, then restores ordinary button handling. It does not suppress authentication or replay startup. Runtime signature checks and a bounded wait preserve failure behavior on unsupported or unsettled systems. See [testing](testing.md) for runtime checks and physical validation. Standard does not load this guard.

## Storage and precedence

User configuration is `~/.iphone-use/config.json`:

```json
{
  "version": 1,
  "mode": "standard"
}
```

For isolated local acceptance, `IPHONE_USE_CONFIG_DIR=/absolute/private/directory` selects a separate `config.json`. The override disables inference from existing iPhone-use Runner preparation, so an empty directory starts with standard mode. It must be an absolute path. It does not relocate session locks, device pairing, signing credentials or Runner preparation; explicitly choosing Runner still uses the normal Runner setup workflow. Leave it unset for ordinary use. The override applies to config/connect commands, not already-running sessions.

The directory is private (0700), and files written by the CLI are 0600. Updates are atomic and serialized with a local configuration lock. Unknown versions/fields, invalid modes, malformed JSON and non-regular configuration files are errors; they do not select an alternate backend. Repair invalid files before setting preferences. `config get mode` is read-only: it reports the effective default, its source, the path and whether a configuration file is saved. It neither connects to a phone nor creates configuration.

Selection order:

1. Explicit connection options. `--mode standard|runner` is the preferred interface. Existing `--backend apple-native|xctest` remains compatible. An explicit `--xctestrun` implies runner; the diagnostic `--native-endpoint-inventory` implies standard. Compatible options can coexist; contradictory options fail before any host/device operation. Explicit selection neither reads nor changes the user default.
2. Saved `mode` in `~/.iphone-use/config.json`.
3. One-time initialization at the first connection without explicit options: migrate an intact, unexpired Runner setup compatible with the installed package to runner; otherwise a fresh installation uses standard. The selected default is saved before starting the host and remains even if connection fails.

Migration examines only local Runner preparation records and validates the prepared files using the existing package validation. The presence of Xcode, certificates or an unregistered Runner alone is insufficient. Existing JSON setup records that cannot be validated produce `mode_selection_required`; choose with `config set mode runner` or `config set mode standard`. Expired or broken setup must not silently redirect an old workflow. Migrating runner does not establish that the phone or signing environment is currently ready; normal Runner connection checks still run.

The preference is global to this macOS user. There are no device-level overrides in this version. Runner artifacts stay in `~/Library/Application Support/iphone-use`; session IPC, logs and observations stay under `/private/tmp/iphone-use-<uid>` (or `IPHONE_USE_STATE_DIR`). User preferences are separate from session state.

## Session contract for agents

`connect`, `status` and host replies report `mode`, `backend` and `modeSource`. Sources are `command_line_mode`, `command_line_backend`, `command_line_xctestrun`, `command_line_native_endpoint_inventory`, `configuration`, `legacy_runner_migration` or `default`. Direct core callers can report `explicit_runner`/`explicit_standard`; saved hosts predating this field report `legacy_session`. Old host configurations without a backend remain XCTest. Older running host binaries cannot gain these fields until a new session is created.

`connect.result.support` and `status.result.support` describe implemented operations, observation sources, action target forms, text modes/methods and keys. They describe implementation support, not current readiness or per-app success. Standard-mode `controlAvailable`, `capabilities`, media and recovery fields still report dynamic availability. Successful Runner status verifies its ping; element availability must be established by the actual observation. Ordinary Runner typing uses XCTest; explicit `--method touch-paste` instead stages the clipboard for a visually selected Paste-menu action. Consult the action's help for bounds and other requirements.

Agent rules:

1. Use [explicit sequential connection reuse](session-reuse.md) when continuing a healthy connection. Respect created/borrowed ownership and obtain a fresh observation. Otherwise connect using the user’s explicit choice or saved default; do not choose based on installed developer tools.
2. Read the session's support and readiness. Standard mode uses screenshot `oN` references; Runner permits captured `oN:eN` elements where supported. Screenshots still work for Runner coordinate taps/swipes.
3. Keep session/observation binding, coordinates, screen protection and outcome facts intact. Text `--mode insert|replace|append` controls editing and is separate from **connect** `--mode standard|runner`.
4. Unsupported operations or unavailable control are explicit failures. Do not start another backend to complete them. If the result is unknown, observe and judge the effect; never replay automatically.
5. Changing the user configuration affects only new connections. To change a device's active mode, explicitly close its session, handle pending input/clipboard/media cleanup, then connect with the new mode and observe again. Never transfer old references or pending actions. Existing per-device locking prevents simultaneous iPhone-use control sessions. Cleanup uncertainty is reported, not resolved by switching routes.

The external agent owns planning and visual verification. No model or automatic cross-backend action router is added.

Runner text now supports insert/replace/append. Append reconstructs a readable non-secure value and replaces the field; it is not a native document-end shortcut. LF multiline input requires a text_view. CR/CRLF remain rejected in Runner’s XCTest typing because XCTest changes their bytes; standard paste keeps them intact. See [text actions](actions.md).

Runner also implements screenshot-coordinate long-press, double-tap and pinch. Drag-and-drop uses swipe with an initial press duration. These actions keep screen guards and never establish a native control session; see [Runner gestures](runner-gestures.md).

Runner supports `home oN`, `terminate BUNDLE` and `relaunch BUNDLE` through XCTest. Home confirms input completion; lifecycle commands confirm application state, not page readiness. Use `--observe` to check the result. See [Runner lifecycle](runner-app-lifecycle.md).

Runner implements Return, Backspace, arrows and Tab/Shift+Tab with the same names as standard mode, current element references and XCTest execution. Runner Escape remains unsupported after device validation; it does not switch modes. See [Runner editing keys](runner-editing-keys.md) for the validated scope and limitations.

## Current differences

Both modes support coordinate tap, long-press, swipe/drag, double-tap, pinch, Home and application lifecycle commands. Runner also exposes available elements and uses element references for text/press; standard mode uses visually confirmed focus and optional screenshot field rectangles. Runner Escape remains unsupported, and ordinary Runner typing rejects CR/CRLF while standard paste preserves it. Both modes additionally support explicit `--method touch-paste` staging and `text-finish`; it accepts literal CR/LF without key synthesis. Native keyboard preparation and auto/keys/paste method selection remain standard-only. Keep these differences explicit in session support; neither mode silently starts the other control backend.

Both modes implement `record-start` / `record-stop` through the shared native media recorder. The current source also provides an experimental read-only `preview` command. In Runner mode an explicit recording or preview request opens an owned display/media connection; input stays on XCTest. A recording started while preview is active shares its decoded frames and retains the media connection until both consumers stop. It neither creates a HID control session nor waits for XCTest attachment export. Preview does not create observations or renew the session through browser requests. See [Runner recording](runner-recording.md) and [local preview](local-preview.md) for ownership, usage and the known performance/rotation limits. Stable 30 fps has not passed acceptance.

See [installation and upgrades](install.md) for package updates and [Runner setup](onboarding.md) for signing and installation.

Both modes share the host-owned [touch-paste workflow](actions.md#纯剪贴板与触摸粘贴两种模式). It opens only the Apple clipboard service, never a second control backend or a keyboard service. Menu gestures remain on the selected backend. Availability still depends on that service on the paired device.

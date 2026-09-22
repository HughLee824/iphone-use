# AgentSoma → iPhone-use

This checkout is renamed locally. The GitHub repository has **not** been renamed by this change; no version, Homebrew formula or plugin has been published. New repository URLs in current documentation and release templates target the planned `HughLee824/iphone-use` repository. They are not evidence that the remote switch has happened.

## Names and compatibility

- Brand: **iPhone-use**. Repository/project/package/CLI: **iphone-use**. Swift targets: `IPhoneUse`, `IPhoneUseCore`, `IPhoneUseCoreTests`.
- `iphone-use` is the primary command. The source package also builds `agentsoma` from the same target. Release archives include an identical, hash-checked binary copy under the old name; Homebrew exposes the old command as a symlink to the new binary. Both use the same configuration and session implementation.
- New preferences: `~/.iphone-use/config.json`. If absent, valid `~/.agentsoma/config.json` supplies the default before Runner/default detection. The first implicit connection atomically saves that preference in the new directory and preserves the old file. `config get mode` previews migration without writing. New configuration always wins thereafter. Invalid old configuration never silently resets the mode; explicit `config set mode` chooses a new preference.
- `IPHONE_USE_STATE_DIR` is the new session-directory override; `AGENTSOMA_STATE_DIR` remains accepted. Different simultaneous values are rejected. The default remains `/private/tmp/agentsoma-<uid>` so old active session IDs still resolve. New device hosts hold the old default device lock as well as any overridden state-root lock; this prevents a new custom-root host bypassing an old default-root session. If an older CLI used a custom state root, keep that same override during transition. Arbitrary independently configured old roots are not discoverable automatically.
- Active hosts keep their existing executable, mode and protocol. They cannot gain new fields/features until reconnected. Do not move an active session's directory or replay unknown actions during migration.
- New Runner preparation lives in `~/Library/Application Support/iphone-use`. Old prepared/signing payloads are neither moved nor reused. Old mode preferences are migrated, but renamed Runner products require `iphone-use setup` (packaged workflow) or a new `build-runner` (source workflow). Without a mode preference, old Runner state triggers an explicit mode choice rather than silently selecting standard. No existing phone app is uninstalled.

## Apple identities

The Runner project/scheme is `Runner/IPhoneUseRunner.xcodeproj` / `IPhoneUseRunner`, with test target `IPhoneUseTests`. The default test bundle identifier is `com.iphone-use.runner`; Xcode's generated host is `com.iphone-use.runner.xctrunner`. The ordinary text/gesture Probe uses `com.iphone-use.native-text-probe` and displays `iPhone-use Text Probe`. Existing explicit `--bundle-id` customization remains supported. New identifiers need matching provisioning/signing before physical deployment; this rename does not reuse an old profile under a new identity.

Runner payload names, portable xctestrun entries, file inventories and release checks all change together. The internal `agentsoma-spike-jsonl-v1` protocol marker is retained because this change does not alter its wire format. Existing backend identifiers `apple-native`/`xctest`, control modes `standard`/`runner`, observation/action semantics and unknown-result rules remain unchanged.

## Plugin and assets

The canonical skill is `skills/iphone-use`; the self-contained plugin is `plugins/iphone-use`. Both client manifests and marketplace entries use `iphone-use`. Local plugin version is 0.1.4; it is not published. Install the new plugin identity through the client's normal workflow when available and disable/remove the old AgentSoma plugin with user authorization. Do not enable duplicate skills for the same phone task. The new plugin checks for `iphone-use`; it does not silently fall back to an arbitrary older AgentSoma executable.

All existing Logo/image assets, filenames, brand manifest and the wordmark generator are preserved. README/Runner still show the existing visual mark until the new design is approved. Copyright attribution and historical plans/acceptance evidence retain their original names. The existing website domain and separate website repository remain unchanged.

## Remaining external rollout

After accepting the local build:

1. Rename the GitHub repository and update local remotes; do not relocate the active working directory mid-session. The local checkout path is still AgentSoma. Updated release workflow repository guards expect the new remote name.
2. Update the separate Homebrew Tap from the new template and publish the new formula only with a validated public archive. The new formula conflicts with the old formula because both install `agentsoma`; disconnect first, uninstall the old formula, then install the new one. Local configuration is retained. No formula replacement/remote Tap edit has been executed here.
3. Publish/install the new plugin identity and verify client discovery and the first controlled phone task. Remove the old identity only with user authorization.
4. Update the independent website, links and later the approved Logo assets. No new domain is assumed.

The GitHub/Tap/website and plugin rollout are separate from local code changes. Host tests, unsigned builds and relocatable archive checks do not establish signed installation or real-device control under the new bundle IDs.


## Physical acceptance (2026-09-22)

The signed products from commit `cbe37b5` were exercised on a paired wired iPhone 12 Pro / iOS 27.0, using macOS 27.0 and Xcode 27.0. Both renamed bundle IDs installed/launched. Explicit Runner opened the new Probe, tapped its sample and entered `头🙂尾`; the subsequent screenshot and element snapshot confirmed exact UTF-8 content. The type command nevertheless reported `frame_stability_timeout` after input, so its outcome remained unknown and was not replayed. Runner's whole-frame stability behavior remains an open limitation, not a proven rename regression.

Explicit standard mode connected without starting Runner, used a screenshot-bound coordinate tap and owned clipboard/HID paste, and produced the same exact Probe result with one edit. The source-anchored caret fade exception admitted the input. Ownership-checked clipboard restoration completed. A preceding expired-observation tap was rejected before dispatch; a new action was chosen only after inspecting its returned current screenshot.

Standard → Runner → standard reconnect/observe/shutdown completed with distinct sessions and native media ownership. All owned host/xcodebuild processes were independently confirmed absent after cleanup. No default mode change, implicit fallback, `stopAll`, unknown-input replay or publication occurred. An earlier native RemoteXPC startup failure did not recur, but its cause remains unproven. This is a controlled smoke test, not all-feature regression coverage. Detailed commands, screenshots, failed attempts and cleanup evidence are local under `.local/research/iphone-use-device-20260922/RESULT.md`; raw evidence is not committed.

The subsequent [Runner stability diagnosis](runner-frame-stability-diagnosis.md) reproduced the timeout with all intermediate frames retained: caret fading and tiny keyboard-region color changes continually reset the exact whole-frame comparison. This is a diagnosed limitation; no behavior fix is included.

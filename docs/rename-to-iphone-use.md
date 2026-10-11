# AgentSoma → iPhone-use

As of 2026-10-11, the repository is [HughLee824/iphone-use](https://github.com/HughLee824/iphone-use), [CLI 0.2.0](https://github.com/HughLee824/iphone-use/releases/tag/v0.2.0) is public, and the Homebrew formula and website have switched to iPhone-use. Release assets, repository plugin content and client installation are separate channels; see the status and remaining checks below. This documentation update does not rebuild or replace published assets.

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

The canonical skill is `skills/iphone-use`; the self-contained plugin is `plugins/iphone-use`. Both client manifests and marketplace entries use `iphone-use`. The 0.2.0 Release includes plugin 0.1.4. The source plugin is versioned 0.1.5 for this documentation-only correction; it does not change device workflow behavior or replace the published ZIP. When installing from Git, check the version in the client cache instead of assuming it matches the Release ZIP. Install the new plugin identity through the client's normal workflow and disable/remove the old AgentSoma plugin with user authorization. Do not enable duplicate skills for the same phone task. The new plugin checks for `iphone-use`; it does not silently fall back to an arbitrary older AgentSoma executable.

All existing Logo/image assets, filenames, brand manifest and the wordmark generator are preserved. README/Runner still show the existing visual mark until the new design is approved. Copyright attribution and historical plans/acceptance evidence retain their original names. The existing website domain and separate website repository remain unchanged.

## Remaining external rollout

Status checked on 2026-10-11:

| Channel | Published state and evidence | Remaining work |
| --- | --- | --- |
| Source repository | Renamed to `HughLee824/iphone-use`; local origin uses the new URL. | The local checkout directory remains AgentSoma intentionally. No move is required. |
| CLI Release | 0.2.0 is published from `d79263dd58554705924f87459d2840c950c0eee2`; all five anonymous asset downloads matched the verified draft, and the public tag matches that source. | No new physical-device acceptance of these exact archive bytes; prior-candidate results remain explicitly separate. |
| Homebrew | [Tap update](https://github.com/HughLee824/homebrew-tap/actions/runs/38115023135), public install, `brew test`, CLI/Runner digests and both command versions passed. | Users migrating from the old formula must resolve the command conflict; see below. |
| Website | [agentsoma.dev](https://agentsoma.dev) serves the new brand and bilingual installation guides. Tests, deployment and public-file checks passed; the [Wrangler security update](https://github.com/HughLee824/agentsoma-website/commit/0dee54496eb824def6a09e30d39df0357b180ce6) also passed a full zero-finding dependency audit. | Domain, Worker identity, website repository name and Logo remain unchanged. |
| Plugin | The public repository contains both marketplace indexes. Release 0.2.0 includes the verified 0.1.4 ZIP; the source 0.1.5 revision corrects documentation only. | Public Git installation, version pickup after an upgrade, and task execution in Codex and Claude Code have not been reverified in this release. Not listed in either official plugin directory. |

For Homebrew migration, disconnect first, uninstall the old `agentsoma` formula, then install `iphone-use`: both expose the compatibility command. Local configuration and signing material are retained. New Tap Trust enforcement may also require permission to read the old formula for the conflict check; after reviewing it, explicitly trust that one formula if desired. See [formula-scoped trust](install.md#homebrew-单公式信任). Whole-Tap trust is not required; checksum-verified manual installation remains an alternative.

The next client-channel check is to install from the public Git marketplace outside the source checkout, confirm the cached plugin version, disable the old duplicate identity and verify upgrade pickup. Any later controlled phone task must record its own image-reading and cleanup evidence. ZIP/preflight checks and historical phone results do not establish this client-channel acceptance.

Existing signed-device history below remains dated evidence. Free Personal Team onboarding/renewal, fresh-Mac signing and browser/Gatekeeper first-run installation remain unverified; the public package is ad-hoc signed and is not notarized. Logo replacement waits for design approval, independently of CLI and plugin releases.


## Historical physical acceptance (2026-09-22)

The results below describe the rename trial at that date. For subsequent Runner stability changes, see [Runner frame stability](runner-frame-stability-diagnosis.md); current standard-mode observation and caret contracts are in [actions](actions.md) and [screen guard](screen-guard.md).

The signed products from commit `cbe37b5` were exercised on a paired wired iPhone 12 Pro / iOS 27.0, using macOS 27.0 and Xcode 27.0. Both renamed bundle IDs installed/launched. Explicit Runner opened the new Probe, tapped its sample and entered `头🙂尾`; the subsequent screenshot and element snapshot confirmed exact UTF-8 content. The type command nevertheless reported `frame_stability_timeout` after input, so its outcome remained unknown and was not replayed. At that point, Runner's whole-frame stability behavior was an open limitation, not a proven rename regression.

Explicit standard mode connected without starting Runner, used a screenshot-bound coordinate tap and owned clipboard/HID paste, and produced the same exact Probe result with one edit. The source-anchored caret fade exception admitted the input. Ownership-checked clipboard restoration completed. A preceding expired-observation tap was rejected before dispatch; a new action was chosen only after inspecting its returned current screenshot.

Standard → Runner → standard reconnect/observe/shutdown completed with distinct sessions and native media ownership. All owned host/xcodebuild processes were independently confirmed absent after cleanup. No default mode change, implicit fallback, `stopAll`, unknown-input replay or publication occurred. An earlier native RemoteXPC startup failure did not recur, but its cause remains unproven. This is a controlled smoke test, not all-feature regression coverage. Detailed commands, screenshots, failed attempts and cleanup evidence are local under `.local/research/iphone-use-device-20260922/RESULT.md`; raw evidence is not committed.

The subsequent [Runner stability diagnosis](runner-frame-stability-diagnosis.md) reproduced the timeout with all intermediate frames retained: caret fading and tiny keyboard-region color changes continually reset the exact whole-frame comparison. That diagnosis did not yet include a behavior fix.

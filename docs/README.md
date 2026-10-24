# Documentation

Start with [your first iPhone task](first-task.md). These documents describe the current source; an installed release may expose fewer features. Check `iphone-use --version`, command `--help`, and the session's support/readiness fields. Release-specific compatibility and distribution status belong in [GitHub Releases](https://github.com/HughLee824/iphone-use/releases), not an undated promise in a guide.

## Use iPhone-use

| Guide | Purpose |
| --- | --- |
| [First task](first-task.md) | Install, connect, observe, act, verify and disconnect. |
| [Installation](install.md) | Package layout, Homebrew, upgrades and uninstalling. |
| [Setup and troubleshooting](onboarding.md) | Xcode, device authorization, Runner signing and source installation. |
| [Client plugins](plugins.md) | Codex, Claude Code, DeepSeek Harness, Cursor and OpenCode. |
| [Control modes](control-modes.md) | Standard/Runner differences, configuration and compatibility. |
| [Connection reuse](session-reuse.md) | Continue a connection sequentially without taking over another task. |
| [Preview](local-preview.md) · [Recording](runner-recording.md) | Read-only viewing, shared media, cleanup and limitations. |

## Command and behavior reference

| Reference | Purpose |
| --- | --- |
| [Discovery](discovery.md) | Physical devices, installed apps and discovery errors. |
| [Observations](observations.md) · [Example](examples/observe/README.md) | Screenshots, AX capture, compact output, queries and reference lifetime. |
| [Actions](actions.md) | Input, app control, result facts and clipboard transactions. |
| [Screen guards](screen-guard.md) | Coordinates, protected regions and dynamic content. |
| [Native text guard](native-text-phase-matching.md) | Observation-bound caret exclusions and their limits. |
| [Runner editing keys](runner-editing-keys.md) | Focus requirements and supported keys. |
| [Runner gestures](runner-gestures.md) · [App lifecycle](runner-app-lifecycle.md) | XCTest execution and completion conditions. |

## Contribute and maintain

| Guide | Purpose |
| --- | --- |
| [Architecture](architecture.md) · [Native backend](apple-native-backend.md) | Module boundaries, Apple runtime adapters and failure semantics. |
| [Testing](testing.md) | Shared checks, physical acceptance, evidence handling and current validation scope. |
| [Release packaging](release-setup.md) | CLI/Runner builds, signing, archive validation and publication. |
| [Plugin and website releases](public-access-release.md) · [Portable skill releases](skill-release.md) | Source ownership and channel-specific publication. |
| [Preview calibration](preview-hardware-calibration.md) | Hardware geometry references; artwork licensing is in [assets/preview](../assets/preview/README.md). |

## What belongs here

Keep durable instructions, current contracts, design decisions with tradeoffs, reproducible test procedures, and concise sanitized compatibility results. Update the owning page when behavior changes instead of appending another chronological report. Keep existing public paths where practical; update all in-repository links when consolidating a page.

Investigation diaries, failed-attempt timelines, candidate-by-candidate results, session handoffs, filming briefs and raw device captures belong under ignored `.local/`. Extract any still-relevant limitation or regression case before removing a process document. Put reusable sanitized fixtures in `Tests/`; keep original evidence local. Use release notes and pull requests for change history. Removing a file from the current tree does not erase prior Git history.

Run `python3 scripts/check-docs.py` for local links and Markdown heading anchors, or `python3 scripts/check.py` for the complete engineering checks. The checker does not validate remote URLs or the factual accuracy of instructions. Update both READMEs when changing public usage.

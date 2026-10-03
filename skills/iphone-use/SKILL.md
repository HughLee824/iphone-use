---
name: iphone-use
description: Operate apps on a connected physical iPhone using the iPhone-use CLI. Use when the user asks to use iPhone-use or perform an iPhone UI task. Does not cover desktop or browser automation, or development of iPhone-use itself.
---

# iPhone-use

Use the local `iphone-use` CLI for iPhone observation and input. The agent interprets the UI and verifies the user's result; the CLI reports execution facts. Do not enable the old AgentSoma skill alongside this one.

## Start once

Workflow version: **0.1.4**. Public packages require **CLI 0.1.0 or later**. The plugin contains instructions, not the CLI or a signed Runner.

1. Run `sh scripts/preflight.sh` with its absolute path resolved relative to **this SKILL.md**, not the working directory. It checks the CLI, full Xcode and supported command forms; it does not prove phone readiness. If missing, follow the [first-task guide](https://github.com/HughLee824/iphone-use/blob/main/docs/first-task.md) (`brew install HughLee824/tap/iphone-use`). Restart the client after PATH changes. For an explicitly supplied development build use `--source`, or `--candidate` for a local prerelease package, with `IPHONE_USE_CLI` set to that exact executable. Use that same binary throughout; do not silently switch builds.
2. Read only the adapter for the actual client: [Codex calls](references/codex-calls.md) when `functions.exec` exposes `tools.exec_command`, or [Claude Code calls](references/claude-code.md). In Codex, use the start template to execute **one selected command and display its attached screenshot in the same tool call**. Do not split those into separate calls when the template is available. Native execution tools and other clients should preserve completion fields and use their image reader.
3. Run `iphone-use devices`, then `connect --device DEVICE_ID` using the returned device ID. Keep the returned session ID for subsequent calls. Reuse an existing session only if it belongs to this task and `status` confirms readiness. A successful new connection already provides status; no immediate extra status query is needed.

Use preflight capabilities once per executable. Consult `--help` only for forms not covered here or rejected by the installed CLI. Read linked references only when their condition applies; do not preload every reference, source code or research report for a UI task.

## Keep the selected mode

`connect --device DEVICE_ID` honors the saved default in `~/.iphone-use/config.json`. Add `--mode standard` or `--mode runner` only for the user's explicit choice; do not change saved configuration without authorization. A supplied signed `--xctestrun` implies Runner. Older CLIs retain their documented Runner workflow; use only supported options.

Read connection `mode`, `backend`, `modeSource`, `result.support` and readiness/recovery. Standard uses screenshots and HID, without an element tree or Runner signing. Runner uses XCTest and available element data. Support lists command forms, not live readiness. Never fall back to the other backend. An explicitly requested switch requires owned cleanup, a new connection and fresh observations; old references and unknown input cannot migrate.

## Observe → choose one action → verify

Discover unknown app IDs with `apps --query NAME` and use the returned bundle ID. Do not guess a macOS ID or select a similarly named app. Desktop computer-use tools do not control this iPhone.

These common forms follow `iphone-use --session SESSION`; replace placeholders from actual results. When supported, add `--agent-output` only to input actions (such as open/tap/type) and native text-prepare/text-finish. It is not a global flag; do not add it to devices/connect/apps/observe/inspect/disconnect.

| Intent | Command |
| --- | --- |
| Open discovered app and see it | `open BUNDLE_ID --observe` |
| Tap a screenshot target | `tap oN --x X --y Y --observe` |
| Tap an observed Runner element | `tap oN:eN --observe` |
| Capture when no usable observation exists | `observe` |
| Search existing Runner snapshot | `inspect oN --query TEXT` |
| Release this task's session | `disconnect` |

Use `--observe` when supported: it returns separate `action` and `observation` results. A successful `observation.result` contains fresh references, text and a PNG. **Read that image before selecting another input**; a path or `ok` is not visual verification. Reuse it instead of an extra `observe`. Codex's template displays the attached PNG even when the action exits nonzero. Only older CLIs need the [separate action/observation fallback](references/action-observation.md).

Screenshot dimensions are pixels; action coordinates are `screen_points`. Map using the returned screen rectangle and actual PNG dimensions. Runner `inspect` searches captured data only: `source_missing=true` cannot be repaired by paging it, and reading an invalidated snapshot cannot revive references. A screenshot alone supplies no AX references.

Read `action.outcome` independently of `observation.ok`:

- `completed`: input completed; verify the UI before claiming task success.
- `unknown`: input may have happened. Inspect the attached observation (capture only if missing); never automatically replay input.
- `not_dispatched`: input was not sent. Inspect any attached rejection frame and correct the evidenced cause. `requiresObservation=true` is satisfied by reading an attached successful current observation; it does not demand another capture.

Preserve the action facts if capture or image reading fails. Resolve that failure without replaying input. A nonzero exit or lost response does not establish non-dispatch. Partial stdout is pending work: continue the original execution handle until exit, never relaunch it. The CLI device session, execution background ID and orchestration cell ID are distinct.

## Screen guards and text

Keep guard defaults. `--max-screen-change` measures change **before input** relative to the observation, not expected post-input motion. Change it only for an understood guard rejection. For a visually identified autoplay video outside the target, supported screenshot-coordinate gestures accept one `--ignore-rect X,Y,WIDTH,HEIGHT` in screen points, at most 25% of screen. It cannot overlap touch neighborhoods, gesture paths or protected regions. Re-select it from each observation; never exclude meaningful task context or assume all motion is video. It does not change post-input stability or authorize replay.

For **standard text**, read [native text](references/native-text.md) before the first input. It provides preparation, complete field coordinates, replace/append/insert and clipboard restoration. For **Runner text**, use `type oN:eN --mode replace --text TEXT --observe` with an observed target; no native clipboard commands. Read [wheel guidance](references/wheels.md) only when adjusting picker wheels.

`--agent-output` keeps action/observation facts while saving full diagnostics to a private `receipt`. Read that file only for a concrete unanswered question. A direct pixel match needs no temporal exception; `fieldTemporalMatch=false` alone is not failure.

## When access fails

- `setup_required` / `setup_update_required`: follow the indicated `setup --device DEVICE_ID` with existing signing configuration for the selected Runner route, then connect. An explicit source workflow can use its supplied signed `.xctestrun`; do not search signing directories or rebuild routinely.
- `coredevice_initialization_timeout`: follow the diagnostic and compare read-only discovery **once** in an approved host execution context. It does not prove disconnection. Keep the working context; do not switch to desktop discovery or reset services.
- Same failure and unchanged device state: stop retrying, report the concrete missing connection/unlock/trust/permission, and wait for new evidence. Do not use timed connect loops or `setup` to repair an unavailable tunnel unless instructed by the CLI.

## Finish

Stay within the requested operation and object; creating a new item does not authorize replacing an existing one. Verify requested fields before saving and the resulting UI afterward. Continue already authorized save/delete sequences and their app confirmations without requesting duplicate permission; ask only for consequential missing information or required authorization.

Give brief progress updates during longer work. Disconnect the task's own session, check cleanup, and report unresolved execution or verification failures. Ordinary tasks need no separate timing report or receipt archive unless requested; receipts can contain private UI text and should remain local.

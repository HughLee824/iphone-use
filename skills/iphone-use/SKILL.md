---
name: iphone-use
description: Operate apps on a connected physical iPhone using the iPhone-use CLI. Use when the user asks to use iPhone-use or perform an iPhone UI task. Does not cover desktop or browser automation, or development of iPhone-use itself.
---

# iPhone-use

Use the local `iphone-use` CLI for iPhone observation and input. The agent interprets the UI and verifies the user's result; the CLI reports execution facts. Do not enable the old AgentSoma skill alongside this one.

## Start once

Workflow version: **0.1.18**. Public packages require **CLI 0.1.0 or later**. The plugin contains instructions, not the CLI or a signed Runner.

1. Run `sh scripts/preflight.sh` with its absolute path resolved relative to **this SKILL.md**, not the working directory. It checks the CLI, full Xcode and supported command forms; it does not prove phone readiness. If missing, follow the [first-task guide](https://github.com/HughLee824/iphone-use/blob/main/docs/first-task.md) (`brew install HughLee824/tap/iphone-use`). Restart the client after PATH changes. For an explicitly supplied development build use `--source`, or `--candidate` for a local prerelease package, with `IPHONE_USE_CLI` set to that exact executable. Use that same binary throughout; do not silently switch builds.
2. Read only the adapter for the actual client: [Codex calls](references/codex-calls.md) when `functions.exec` exposes `tools.exec_command`, [Claude Code calls](references/claude-code.md) in Claude Code, or [DeepSeek Harness calls](references/deepseek-harness.md) in DeepSeek Harness. In Codex, use the start template to execute **one selected command and display its attached screenshot in the same tool call**. Do not split those into separate calls when the template is available. For Cursor, OpenCode, or any other client, read the [portable agent adapter](references/generic-agent.md) and verify shell completion and actual PNG-reading capabilities before connecting. Do not infer a client from a similar tool name.
3. Run `iphone-use devices`, then `connect --device DEVICE_ID` using the returned device ID. When preflight reports connection progress, add `--progress` and read [connection progress](references/connection-progress.md) before connecting. Keep the returned session ID for subsequent calls. Reuse an existing session only if it belongs to this task and `status` confirms readiness. A successful new connection already provides status; no immediate extra status query is needed.
4. After successful connection, follow [live preview](references/live-preview.md) once for this task-owned session, in **both standard and runner**: default to opening a local preview unless the user explicitly declined. Use preflight capabilities, the returned preview status and the per-session attempt record to avoid duplicate pages. Do this before the first app observation/input; starting preview invalidates earlier references. This is a shared agent workflow, not a CLI connect hook.

Use preflight capabilities once per executable. Consult `--help` only for forms not covered here or rejected by the installed CLI. Read linked references only when their condition applies; do not preload every reference, source code or research report for a UI task.

## Keep the selected mode

`connect --device DEVICE_ID` honors the saved default in `~/.iphone-use/config.json`. Add `--mode standard` or `--mode runner` only for the user's explicit choice; do not change saved configuration without authorization. A supplied signed `--xctestrun` implies Runner. Older CLIs retain their documented Runner workflow; use only supported options.

Read connection `mode`, `backend`, `modeSource`, `result.support` and readiness/recovery. Standard uses screenshots and HID, without an element tree or Runner signing. Runner uses XCTest and available element data. Support lists command forms, not live readiness. Never fall back to the other backend. An explicitly requested switch requires owned cleanup, a new connection and fresh observations; old references and unknown input cannot migrate.

## Observe → choose one action → verify

Discover unknown app IDs with `apps --query NAME` and use the returned bundle ID. Do not guess a macOS ID or select a similarly named app. Desktop computer-use tools do not control this iPhone.

These common forms follow `iphone-use --session SESSION`; replace placeholders from actual results. When supported, add `--agent-output` only to input actions (such as open/tap/type) and text-prepare/text-finish. It is not a global flag; do not add it to devices/connect/apps/observe/inspect/disconnect.

| Intent | Command |
| --- | --- |
| Open discovered app and see it | `open BUNDLE_ID --observe` |
| Tap a screenshot target | `tap oN --x X --y Y --observe` |
| Tap an observed Runner element | `tap oN:eN --observe` |
| Capture when no usable observation exists | `observe` |
| Search existing Runner snapshot | `inspect oN --query TEXT` |
| Release this task's session | `disconnect` |

Use `--observe` when supported: it returns separate `action` and `observation` results. A successful `observation.result` contains fresh references, text and a PNG. **Read that image before selecting another input**; a path or `ok` is not visual verification. Reuse it instead of an extra `observe`. Codex's template displays the attached PNG even when the action exits nonzero. Only older CLIs need the [separate action/observation fallback](references/action-observation.md).

Screenshot dimensions are pixels; action coordinates are `screen_points`. Map using the returned screen rectangle and the dimensions of the image actually viewed. For a full-frame preview of size W×H, use `x = screen.x + previewX / W * screen.width` and similarly for y. If the image reader resized the PNG, do not divide preview coordinates by the original PNG dimensions. Re-locate targets after keyboard or layout changes. Runner `inspect` searches captured data only: `source_missing=true` cannot be repaired by paging it, and reading an invalidated snapshot cannot revive references. A screenshot alone supplies no AX references.

Read `action.outcome` independently of `observation.ok`:

- `prepared`: touch-paste clipboard staging completed; no text was inserted. Follow the returned touch workflow, never re-stage automatically.
- `completed`: input completed; verify the UI before claiming task success.
- `unknown`: input may have happened. Inspect the attached observation (capture only if missing); never automatically replay input. Repeated `unknown` codes alone do not mean repeated failures. Choose the next action from the visible result, including the bounded UI recovery below.
- `not_dispatched`: input was not sent. Inspect any attached rejection frame and correct the evidenced cause. `requiresObservation=true` is satisfied by reading an attached successful current observation; it does not demand another capture.

Preserve the action facts if capture or image reading fails. Resolve that failure without replaying input. A nonzero exit or lost response does not establish non-dispatch. Partial stdout is pending work: continue the original execution handle until exit, never relaunch it. The CLI device session, execution background ID and orchestration cell ID are distinct.

When `observation.stability` is present, `stable=false` means the returned valid image did not settle within the observation budget, not that input failed. Inspect that image before deciding what to do next; do not resend text. Both modes can return `reason=dynamic_or_transitioning` after a bounded observation window. This is a usable current frame, not proof of business success or permission to replay input. Standard input can still be `unknown` because its HID transport has no execution acknowledgement.

After a substantial screen change (navigation, scrolling, rotation, a keyboard, sheet or permission dialog opening/closing), reassess the current page, editor/focus, target and dynamic content from the returned image. Re-select coordinates or available Runner references, field/caret bounds and any motion exclusion for this observation; do not carry old geometry or assume the planned next action still applies. Preserve pending input/clipboard transaction facts across this reassessment. Use the attached image when usable; if a transition obscures the target, obtain a fresh observation before input. Large change is a reason to reassess, not to loosen guards or mask the changed layout.

If `stable=false` or `screen_changed` is explained by a visibly identified continuous animation, use the scoped exclusion or dynamic overlay rules below and select an action from the current UI. Do not terminate/relaunch an app merely because a video never becomes pixel-stable. If the cause is unclear or neither scoped method applies, report the limitation rather than looping. If a menu did not open, a fresh inspected image still shows the same safe menu opener and no conflicting effect, the Agent may select one further tap with current references/coordinates. This is a new visual decision, not backend replay; stop if it still has no effect. Do not extend it to uncertain text, submissions, purchases, destructive actions or state toggles.

## Screen guards and text

Keep guard defaults. `--max-screen-change` measures change **before input** relative to the observation, not expected post-input motion. Change it only for an understood guard rejection. For a visually identified autoplay video outside the target, supported screenshot-coordinate gestures accept one `--ignore-rect X,Y,WIDTH,HEIGHT` in screen points, at most 25% of screen. It cannot overlap touch neighborhoods, gesture paths or protected regions. Re-select it from each observation; never exclude meaningful task context or assume all motion is video. Standard-mode post-action stability also uses this explicit region while the original display geometry remains valid; it never authorizes replay.

After `stale_observation` / `screen_changed`, inspect `agentSummary.comparison.mismatches`, deadline facts and the attached current image. A pixel mismatch is not evidence that the screenshot expired. For continuous video motion, a new observation ID alone cannot fix the rejection: identify the video bounds and choose a static gesture whose **touch neighborhoods and full path remain outside the video**, then use the explicit exclusion. Changing only the reference repeats the same failing strategy. For visible video-page controls, use the bounded dynamic tap below when its requirements hold; otherwise report the blocker instead of cycling through observe and input. After scrolling, locate any video again; it may have moved outside the old box. A transient notification can instead be handled once it visibly disappears.

For a video page with visible fixed controls, both modes support a coordinate `tap oN --x X --y Y --dynamic-target X,Y,W,H --dynamic-anchor X,Y,W,H`. First inspect the original screenshot. Tightly bound the complete target icon/text and a separate, recognizable page landmark; these are **two local shape checks**, not full-screen identity or app verification. The target must contain the tap (at most 96×96 points); the anchor must not overlap it (at most 256×96 points). Keep default thresholds and do not combine with ignore/protect options. Shapes must remain at the same coordinates; hidden controls, a blank video surface, low contrast, changing text, or significant background edges can be rejected. Do not use an unrelated status-bar icon as the page landmark, or use this reduced scope for submissions, purchases or destructive actions. After rejection, inspect the new frame: one new decision is reasonable when the same safe target is visibly intact; otherwise stop and report the limitation. Rotation invalidates old rectangles. Older CLI/Runner packages do not support these options; do not substitute threshold bypasses.

If dynamic baseline preparation returns `dynamic_target_unusable` or `dynamic_anchor_unusable`, input was not sent and no live comparison occurred. Read `screenGuardPreparation` in the result or agent summary: it identifies the failed component and its rectangle in `screen_points`. Inspect the attached current image and check the dimensions of the image actually viewed; re-map the complete icon/text bounds to screen points. A crop can help locate small controls, but include its origin and scale when mapping back. Choose a tight, recognizable target/landmark with visible shape contrast, not blank background. Do not infer staleness, repeat unchanged rectangles with a new observation ID, run input probes, or loosen thresholds. Allow at most one corrected attempt supported by new visual evidence; if no usable pair is visible or the correction fails, stop and report the blocker. Older CLIs may report only `invalid_screen_guard` with “observe again”; for a dynamic tap, inspect the baseline rectangles first rather than looping on that generic hint.

For explicit **touch-paste** in either mode, first read [touch paste](references/touch-paste.md); it stages the clipboard without keyboard events, then you operate the visible Paste menu. Check `result.support.textMethods` for availability; never substitute the older `paste` shortcut if unavailable. For other **standard text**, read [native text](references/native-text.md) before the first input. Prepare the keyboard once, then inspect the field and focus it if needed; current builds reuse the built-in CoreDevice keyboard. The reference covers complete field coordinates, replace/append/insert and clipboard restoration. For ordinary **Runner text**, use `type oN:eN --mode replace --text TEXT --observe` with an observed target; do not use native keyboard preparation. Read [wheel guidance](references/wheels.md) only when adjusting picker wheels.

`--agent-output` keeps action/observation facts while saving full diagnostics to a private `receipt`. Read that file only for a concrete unanswered question. A direct pixel match needs no caret exception. Native text accepts an Agent-confirmed `--caret-rect` bound to the current `oN`; pixels inside that fixed narrow box are excluded, without background or opacity inference. Inspect the complete field and follow `references/native-text.md`. Each pre-input stage uses one Apple PNG, with no blink-cycle retry.

## When access fails

- During Runner startup, promptly relay `connection_progress` messages. A confirmed `requiresUserAction=true` means ask the user to complete **Enable UI Automation on the iPhone**, never in chat, and continue the same pending command. Without explicit evidence, phrase this conditionally; a slow start, timeout, unavailable log monitor or stopped video is not proof of authorization. Never switch modes or relaunch to avoid a prompt. See [connection progress](references/connection-progress.md).

- `setup_required` / `setup_update_required`: follow the indicated `setup --device DEVICE_ID` with existing signing configuration for the selected Runner route, then connect. An explicit source workflow can use its supplied signed `.xctestrun`; do not search signing directories or rebuild routinely.
- `coredevice_initialization_timeout`: follow the diagnostic and compare read-only discovery **once** in an approved host execution context. It does not prove disconnection. Preserve the successful tool execution options for **connect and all subsequent device calls**, including disconnect; approval for one command does not automatically change later calls. The [Codex adapter](references/codex-calls.md) stores this context and describes a bounded startup correction. Do not switch to desktop discovery or reset services.
- Same failure and unchanged device state: stop retrying, report the concrete missing connection/unlock/trust/permission, and wait for new evidence. Do not use timed connect loops or `setup` to repair an unavailable tunnel unless instructed by the CLI.

## Finish

Stay within the requested operation and object; creating a new item does not authorize replacing an existing one. Verify requested fields before saving and the resulting UI afterward. Continue already authorized save/delete sequences and their app confirmations without requesting duplicate permission; ask only for consequential missing information or required authorization.

For a time-bounded feed task, verify the requested cutoff rather than treating a relative calendar label such as “Yesterday” as proof of 24-hour coverage. If the boundary cannot be established or browsing is blocked, report the confirmed coverage and completed interactions as partial results.

Give brief progress updates during longer work. Disconnect the task's own session, check cleanup (including its preview and media), and report unresolved execution or verification failures. Closing a browser tab is not cleanup; follow the [preview finish rules](references/live-preview.md#finish). Ordinary tasks need no separate timing report or receipt archive unless requested; receipts can contain private UI text and should remain local. When evidence is requested, copy each relevant PNG, snapshot and receipt together immediately after inspecting that observation, before the next device action. The cache retains only the latest two observations and disconnect removes it; saving everything at the end loses earlier screenshots. Avoid separate per-file tool calls or manually reconstructing response JSON.

---
name: iphone-use
description: Operate apps on a connected physical iPhone using the iPhone-use CLI. Use when the user asks to use iPhone-use or perform an iPhone UI task. Does not cover desktop or browser automation, or development of iPhone-use itself.
---

# iPhone-use

Use the local `iphone-use` CLI for iPhone observation and input. The calling agent owns the user's task, UI interpretation, and outcome verification.

This is the renamed iPhone-use skill. Do not enable it alongside the old AgentSoma skill for the same task. The renamed CLI is required; the `agentsoma` compatibility command shipped by iPhone-use uses the same configuration and session paths. Renaming a cached plugin is not an upgrade: install the new identity and disable/remove the old plugin through the client's normal UI when authorized.

## Check the installation

Workflow version: **0.1.4**. The public package path requires **iPhone-use CLI 0.1.0 or later**. The plugin contains instructions, not the CLI or a signed Runner.

Before the first device command in a new task, run `sh scripts/preflight.sh` using the absolute path resolved relative to **this SKILL.md**, not the user's working directory. This read-only check verifies CLI version and full Xcode, and reports whether action `--observe` is available. If the CLI is missing, follow the [first-task guide](https://github.com/HughLee824/iphone-use/blob/main/docs/first-task.md): `brew install HughLee824/tap/iphone-use`. Restart the client after PATH changes. Device trust and Developer Mode still need setup; Runner mode additionally needs signing; the check does not prove a phone is ready.

For an **explicitly chosen source workflow** with a supplied signed `.xctestrun`, pass `--source` to the preflight so an unversioned `development` CLI can be checked. Do not silently switch a release user to a development build. Resolve the installed skill's actual base directory rather than assuming the client cache layout; a local marketplace can expose its source directory.

## Enter the right device session

- Start with `iphone-use devices`; use the device ID it returns. Desktop computer-use tools do not control this iPhone. Discover the app with `apps --query` using the user's app name, then use the returned bundle ID; do not guess a macOS bundle ID or substitute a similarly named app.
- For a new session, use `iphone-use connect --device DEVICE_ID`. Reuse an existing session only when it belongs to the current task and `status` confirms it is ready. Keep the returned iPhone-use session ID in subsequent calls.
- Follow `setup_required` / `setup_update_required` with the indicated `iphone-use setup --device DEVICE_ID`, using existing signing configuration, then connect again. Use a supplied signed `.xctestrun` for an explicitly chosen source workflow. Do not rebuild Runner or search signing directories for every task.
- A `coredevice_initialization_timeout` does not establish a disconnected phone. Follow its diagnostic: compare read-only device discovery once in an approved host execution context before repeating commands or restarting services. Keep the execution environment consistent once it works. Recover CLI discovery or connection errors through the CLI and its diagnostics; switching to desktop computer-use discovery does not resolve iPhone access.
- If the same connection error remains after one diagnostic comparison and the device state is unchanged, stop retrying. Request the missing USB connection, unlock, trust, or stated permission and wait for new evidence. Do not run `setup` to repair an unavailable device tunnel unless the CLI specifically requires setup. Report the block and continue independent work; do not add timed connect loops.

## Respect the selected control mode

On a CLI whose `connect --help` lists `--mode`, use `connect --device DEVICE_ID` to honor the saved default in `~/.iphone-use/config.json`. Pass `--mode standard` or `--mode runner` only for the user's explicit choice; do not change `config set mode` without authorization. Existing `--backend apple-native|xctest` is a compatibility option. A supplied signed `--xctestrun` implies Runner. Older released CLIs retain their documented Runner workflow; do not send them unsupported mode/config options.

Read `mode`, `backend`, `modeSource` and `result.support` from connection/status when available. Standard means screenshots and HID; it requires the supported Apple toolchain/device environment but no Runner signing or installation. Runner means XCTest with available element data. Support describes implemented command forms, not live readiness: check standard-mode `controlAvailable`, capabilities and recovery; read actual observations for element availability. Do not infer support from the mode name alone. Unsupported actions and native connection failures must never start the other backend. Follow setup instructions only for the explicitly selected Runner route.

Keep the selected backend for the lifetime of the session. Configuration changes apply to new connections. Switching requires an explicitly requested close, owned cleanup, a new connection and a fresh observation; never migrate old references or replay an unknown action. The agent plans and verifies; iPhone-use reports access and execution facts. Feature parity is a future goal, not permission to mix routes.

## Keep command completion visible

Use the adapter matching the client's actual tools:

- **Codex:** read [the fixed call templates](references/codex-calls.md) before the first command when `functions.exec` exposes `tools.exec_command`. With native `exec_command` / `write_stdin`, use them directly, preserving the same completion fields; open screenshots with `view_image`.
- **Claude Code:** read [Bash, continuation, and Read instructions](references/claude-code.md) before the first command. Use Bash for CLI execution and Read for the actual PNG. Do not paste Codex JavaScript into Bash or assume Codex tools exist.
- Other clients use equivalent command continuation and image-reading tools.

There are separate identities: the iPhone-use device session, the execution tool's background command ID, and (if present) the orchestration tool's running cell ID. A partial stdout result is not command completion. Retain the background ID and continue the original command until its exit code is available; do not start it again to obtain output.

## Observe, act, verify

1. Open the discovered app, then `observe`. Read the returned PNG with the available image tool; combine it with captured element text when available. Standard mode has no element tree. Screenshot coordinates are pixels; action coordinates are `screen_points`.
2. When an element snapshot exists and a target is omitted from compact output, use `inspect oN --query TEXT` or inspect a known subtree. This searches captured data only; `source_missing=true` cannot be repaired by paging the same snapshot. Use the screenshot to resolve ambiguous matches and geometry.
3. Perform one selected action with a current reference. Keep screen-guard defaults; `--max-screen-change` measures changes **before input**, relative to the observation, not the size of the expected animation or scroll. Change it only after understanding a concrete guard rejection.
4. After `completed` or `unknown`, observe again before another input. `completed` describes input completion, not task success. `unknown` may already have changed the app: inspect the result before deciding any further action, and do not automatically replay it. A `not_dispatched` error may still require a fresh observation; follow `requiresObservation` and reference validity.

`inspect` can read an invalidated cached observation, but cannot revive its references. An action screenshot contains no new AX references. A nonzero shell exit or lost transport response alone does not prove an input was never sent.

For an already authorized, selected action, use `--observe` when the installed command's `--help` lists it. Read `action.outcome` separately from `observation.ok`; top-level `ok` is true only when both succeed. A successful `observation.result` supplies fresh references, `text`, and `screenshot`, replacing a separate `observe`; read that PNG and verify the result before another input. If observation fails, retain the action facts and recover with observation, never by replaying input. This is a client-side sequence compatible with older hosts, not an exclusive device transaction. For older CLIs, read the [fallback template](references/action-observation.md); do not add `--observe` to that template's action array, which would duplicate capture.

## Adjust wheels from observed values

- Read the current selected value from the form or control and inspect the wheel's frame and child rows. Visible, enabled `text` is not a promise that tapping selects that value. If a value tap has no effect, prefer a controlled drag for similar wheels unless new evidence supports another interaction.
- `swipe oN:eN --direction up` moves the finger across 60% of the visible element height (width for horizontal movement). Slow velocity does not shorten that distance; this can cross several rows.
- Near the target, use explicit endpoints based on the observed row spacing: `swipe oN --from-x X --from-y Y --to-x X --to-y Y --velocity 100 --hold-duration 0.2`. These speed/hold values are starting points, not a one-row guarantee. Use the observation ID with endpoints; optionally add `--protect oN:eN` for an additional protected element.
- After each drag, read the actual value and adjust the remaining distance. Repeated no-change or overshoot calls for checking the selected field, frame, and interaction strategy before another attempt. Do not assume a minute-wheel wrap changes the hour or that changing the start preserves the intended end.
- A custom `scroll_view` is not a native `picker_wheel`. Do not invent a select-by-value CLI command. Use `iphone-use swipe --help` for supported parameters.

## Finish the user's task

Preserve the requested operation and object: creating an item does not authorize replacing a similar existing item. Before saving, verify the requested fields, including both dates, times, and timezone for a calendar task. Continue within existing authorization; ask only for missing consequential information or a required permission.

For example, a request to create, save, reopen, verify, and delete a test calendar event authorizes that sequence for the newly created event. Once its identity and fields are verified, continue through Save and the app's delete confirmation without asking the user to repeat that authorization. An app confirmation dialog is a UI step, not by itself a new user-approval requirement. If an applicable higher-priority instruction or tool approval decision requires a separate permission, explain its source and the blocked action.

Give brief progress updates during longer work, including time spent recovering from errors. After saving, observe and verify the resulting UI before reporting success. Describe material app defaults when relevant. End the task's session with `disconnect` and check the cleanup result. Report unresolved execution or verification failures accurately.

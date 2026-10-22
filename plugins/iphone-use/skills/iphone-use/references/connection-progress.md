# Connection progress and system authentication

When preflight reports support, use `connect --progress`. It streams newline-delimited JSON progress records while pending and ends with the ordinary success/error JSON. It does not change authorization, retry launch, or switch modes. Without this flag the CLI retains its single-result JSON contract.

Before Runner launch, tell the user to keep the iPhone unlocked and complete **Enable UI Automation** on the phone if it appears. Never request a passcode in chat. Do not claim the prompt exists just because startup is slow.

While the command is pending, read each new complete JSON line (retain incomplete lines until the next chunk). For `event=connection_progress`:

- `reason=ui_automation_authorization_required`, `requiresUserAction=true`, `authorization=required`, `evidence=device_log_exact_runner_pid`: Apple's live log matched an authentication request to the exact Runner process launched by this session. Immediately tell the user to complete authentication on the phone. Continue waiting on this execution handle; do not reconnect or launch Runner again.
- `phase=starting`, no confirmed authorization: relay the conditional check-phone guidance. An unavailable monitor means no reliable authorization evidence, not that permission was denied or granted.
- Authentication completion is distinct from command readiness. Only the final `ok:true` proves connection succeeded. A failed attempt may have already exited even if the user subsequently authorized; verify cleanup and changed state before a user-requested retry.

Do not wait for command exit before relaying a human-action event. Use short execution yields (about one second at launch, no more than five seconds while authorization is pending) so a system authentication timeout does not expire while the agent remains silent. Preserve progress separately from the final result; parse the final non-progress JSON as the connection response. Older CLI adapters that assume one JSON document must not be used unchanged with `--progress`.

## Early Runner preview

When the selected mode is known to be Runner and the user wants preview, add `--preview` to `connect --progress`; `--port PORT` can override the configured port. This opens a loopback page before Runner authorization. Newer hosts also start independent CoreDevice video before Runner launch, so the actual phone authorization screen can remain visible; older hosts may show guidance until Runner is ready. Live video is not proof that Runner control is ready: wait for the final connection result before device actions. Standard mode continues to start preview after connect. Honor preview opt-out; never add `--preview` when opted out. Do not change saved mode to enable this feature.

A progress record's `previewURL` is an early page URL, not proof of connection readiness. Open it once using the client's normal browser mechanism and record the session/URL/opening attempt. Codex uses its built-in browser. Reuse that page after readiness: do not issue another preview start or reopen it when the final connection result includes the same URL. With healthy video, authorization updates the status indicator without covering the real phone feed. Without usable video, the page shows conditional startup or confirmed-authorization guidance. Media failure does not establish authorization failure, and does not authorize a reconnect or another preview attempt.

A startup port conflict occurs before Runner launch and returns an error; confirm owned cleanup before retrying the connect command with a different `--port`. Do not confuse this with an active session's `preview_port_in_use` recovery. Do not kill another listener.

The device log monitor is best effort and read-only; it does not modify system permissions, collect passcodes, save raw device logs, or infer authorization from image stalls. Confirmed messages require a single-client association with the launched Runner PID. Unsupported log formats or lost monitoring fall back to conditional guidance. A normal connection/media error has a separate visible message and must not be presented as an authorization request.

This monitor covers Runner **UI Automation authentication only**, during startup or while connected. It is not a detector for all permission prompts. Camera, Photos, location, notifications, and app-specific prompts should remain visible in the live phone feed; do not replace them with “Enable UI Automation” guidance. Identify those prompts from the actual device observation and follow the task’s authorization rules. A generic `requiresUserAction` flag alone does not identify a permission type.

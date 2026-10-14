# Live preview lifecycle (Codex and Claude Code)

The preview is for the person watching the task. It does not replace the agent's fresh `observe` / attached PNG, current references or screen guards. Use the same resolved CLI, execution permissions and configuration/state environment as connect for every command below. The client adapter chooses where to open it: **Codex uses its built-in browser**, while **Claude Code uses the Mac default browser**. Neither client needs to inspect browser content to operate the phone.

## Start once per owned session

Default to preview after a successful connection in either standard or runner. Do not ask an extra preference question. Honor an explicit request such as “no preview”, “don't open a browser”, or “只操作手机，不要预览” for the entire task, including reconnects, until the user changes it. Skip starting the service as well as opening the page. If the user later opts out, stop only this task's preview with `preview --stop` and obtain fresh references before further input.

Preflight reports **Live preview: available** only when the selected CLI supports `preview`, `--no-open` and `--stop`. If unavailable, continue the supported phone workflow and briefly explain that preview needs a newer CLI (current recommended CLI: 0.3.1). Do not automatically upgrade, switch binaries or modes, or repeatedly probe help.

Keep a small task record keyed by the returned device **session ID**: preview skipped, attempted/pending, active with returned URL, or failed. Preserve it across turn continuation/compaction. It is task bookkeeping, not a new persistent user setting. A new session gets a new record; the user's opt-out still applies. Never start another connection just to open a preview.

1. For a new connection use its `result.preview`. For a reused task-owned session use the `status` response already required to check readiness. If the record says attempted/pending, active, failed or skipped, do not issue another automatic start or open another tab. Continue the original execution handle if pending.
2. If a returned `result.preview.url` is nonempty and its state is not `stopped`, reuse it, record it as active/already handled, and do **not** run `preview` again or separately open the URL. `waiting` is not proof of failure: a static phone screen can hold its last frame with healthy media. If state is unavailable/ambiguous, inspect status once if needed; do not guess that no page exists or restart an existing service.
3. For an unhandled session with no active preview, mark the automatic attempt **before** executing the client-specific command below. Collect completion using the actual client adapter and record the returned `result.url` plus whether opening was attempted. **Codex:** run `iphone-use --session SESSION preview --no-open`, then open the returned URL once in its built-in browser using the available tool described by the Codex adapter. **Claude Code:** run `iphone-use --session SESSION preview`; the CLI opens the Mac default browser, so do not add a browser-open call. Subsequent phone actions, observations, task turns and reuse of the same session must not reopen it. If the user closes the page, do not reopen automatically; explicit “show/reopen preview” is a new user request.
4. After starting/stopping preview, obtain a fresh observation (or an app action with a fresh attached observation) before selecting device input. Never reuse pre-preview references, including when startup partially failed.

If startup/browser launch fails or its outcome is uncertain, preserve the attempt record. Inspect `status` once after command completion to see whether the service already exists. If a URL exists, report it for manual opening without automatically launching another page. Otherwise briefly report the preview limitation and continue authorized phone work if the session remains ready. Do not loop, reconnect, change modes or weaken permissions to force preview. A user-requested retry after resolving the cause is allowed; an automatic repeat is not. An unopened URL is not evidence that a browser displayed it.

If Codex has no built-in browser capability (for example, a terminal-only client), still use `--no-open` and provide the URL; do not silently fall back to the system browser. A failed or uncertain page-opening attempt is not grounds to create a second tab. Preserve any returned tab ID for reuse and cleanup.

For an explicit request overriding the client default with a particular browser or embedded panel, run `preview --no-open` once and open the returned URL once through the authorized client capability; track that opening in the same record. If that capability is unavailable, return the URL rather than silently opening a different browser. Do not routinely inspect the browser or screen-share the Mac to drive the iPhone.

## Finish

On completion, cancellation, a terminal failure or an explicitly requested mode switch, disconnect the session owned by this task and check the cleanup response. Disconnect stops its preview server and releases its owned media/control resources; a separate `preview --stop` before disconnect is unnecessary. Do not stop another task's session or recording.

If the user explicitly asks to keep the session running, stop this task's preview with `preview --stop` unless they also want to keep watching; report what remains active. Stopping preview preserves an active recording. Browser traffic does not renew the CLI session timeout. Do not change global timeout/configuration just to keep a page alive.

If browser tools provide the exact tab created by this task, close that tab when ending the preview. Do not close pre-existing/user tabs, quit the browser, or require desktop automation solely for cleanup. Without a tab handle, the inactive page may remain open after disconnect; report that if relevant. Merely closing the tab does not stop the service. Never claim cleanup succeeded if disconnect failed.

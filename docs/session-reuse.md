# Continue an existing device connection

`iphone-use connect --device UDID --reuse` checks the current user's selected state directory for an existing connection. If exactly one matching endpoint is healthy and uses the selected mode, it returns that same session and current status with `reused: true` and `lifecycle.ownership: borrowed`. No new Runner, media stream, preview, or browser page is started. The existing preview URL and idle timeout are unchanged. A new connection returns `reused: false` and ownership `created`.

Use the physical UDID from `devices` for discovery. `iphone-use sessions [--device UDID]` lists endpoints and probes their status without renewing idle time or changing the phone UI. Discovery stays in `IPHONE_USE_STATE_DIR` when set; it does not search arbitrary other state directories. Both chats must use the same state environment. Ended sessions without a socket are ignored; unreachable socket endpoints are reported for inspection rather than deleted or restarted automatically.

Mode/explicit Runner conflicts, ambiguous endpoints, unavailable control, active work reported by the host, or unfinished clipboard transactions fail closed. `--reuse` does not change device locking or permit concurrent agents to operate the phone. Finish the previous task before continuing in another chat. Always obtain fresh observations in the new task.

The current agent workflow probes `--reuse` support at preflight and uses it automatically. Older CLIs retain the old connect behavior. A borrowed connection remains running after a short task, including its existing preview. The agent disconnects it only on an explicit user request. A connection created for an ordinary task is still disconnected at completion; a preparation task should explicitly ask to keep the connection **and preview** running for the next chat. Browser traffic and status checks do not reset the idle timer.

Example preparation request:

> Connect my iPhone and open its live preview. Keep the connection and preview running so I can continue in a new chat. Do not operate any apps yet.

Then in a new chat, after opening the returned preview URL in that chat's right browser panel:

> @iphone-use Open Settings and go to General. Verify the page without changing any settings.

An already active preview URL is reused without opening a duplicate page. Cross-chat browser placement is a client operation, not an automatic CLI hook. The agent still uses fresh phone screenshots for control. Ask to disconnect when finished; otherwise the original idle timeout eventually releases the connection and preview.

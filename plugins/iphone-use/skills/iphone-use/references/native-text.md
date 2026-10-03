# Standard-mode text without duplicate captures

Use this only for a native standard session. Keep the executable path, configuration environment, session ID, keyboard readiness, latest inspected observation and any pending clipboard transaction from actual results. `IPHONE_USE_CONFIG_DIR` is an environment variable, not a `--config` argument. Reuse the established execution context and quote the executable path exactly, including spaces. No command here changes the saved mode.

## First input

1. Inspect the current screen and, if necessary, tap the intended field using its observed coordinates. Verify focus visually; native type does not focus for you.
2. When preflight reports scoped text preparation and the complete field is visible, use `text-prepare --field-rect X,Y,WIDTH,HEIGHT` for the first text baseline; add `--ignore-rect` only for an identified video outside the field. This establishes a bounded stable media baseline, or returns a new Apple PNG if media does not settle. It also prepares the keyboard if needed. Without scoped support or a visible field, use ordinary `text-prepare` when the keyboard is not prepared. Read the returned screenshot, recheck geometry after registration, and do not immediately call `observe` again. Preparation does not prove focus.
3. Select the **complete** focused field in screen points from that image. Map both edges using the actual PNG dimensions and returned screen rectangle. Round outward if integer rounding is necessary so the right/bottom edge is not lost. Do not shrink the field to avoid changing text or a caret. Exclude an identified video only with a separate `--ignore-rect` outside the entire field, at most 25% of the screen; exclude no adjacent static controls or task context.
4. Choose the intended operation and call `type` once, with `--observe` and, if supported, `--agent-output`. For example (replace every placeholder with actual values):

```sh
iphone-use --session SESSION type CURRENT_OBSERVATION --mode replace --text '待输入的文字' --field-rect X,Y,WIDTH,HEIGHT --observe --agent-output
```

`replace` selects all at the current focus. Native `append` sends document-end before inserting; it does not read the field and reconstruct its contents. `insert` uses the actual caret/selection. Verify the operation's visible result. Unicode/multiline auto input uses a clipboard transaction; follow existing user authorization for clipboard access and never discard unbacked content without explicit permission.

## Verify and continue

- Inspect the attached observation, even on a nonzero exit. Native `outcome=unknown` with queued input is expected when there is no device execution acknowledgement; it is **not** permission to repeat text. Read the actual field content to establish the visible result.
- If `result.pasteboard.restorePending=true` (under `action.result` for `--observe`), after inspecting the result and resolving any paste permission dialog, call `text-finish CURRENT_OBSERVATION --transaction RETURNED_TRANSACTION_ID`. Add `--agent-output` when available. It restores only that transaction and returns a new observation; inspect that image and reuse it for the next authorized action.
- For another replace/append/insert, reuse the prepared keyboard and the latest inspected observation. Re-select geometry if the field moved. Scoped type/press and the following text-finish also return a checked text baseline. Do not repeat `text-prepare`, `status` or `observe` merely because another text operation follows. An observation older than 30 seconds is revalidated at execution; age alone is not a reason to capture again.
- `text-finish` must not claim visual verification when the image is unavailable or the result remains unclear. Recover observation without replaying input. If restoration is unconfirmed, follow the returned recovery and preserve the transaction facts; do not automatically repeat restoration.

A normal two-input clipboard flow is preparation → input → finish → input → finish: five returned observations, each read as an image. A separate focus action or genuine recovery can add observations. This is an example, not a fixed number of calls or an authorization to perform additional input.

## Handle rejection once, using the evidence

`not_dispatched` means the input was not sent. A successful `observation.phase=pre_input_rejection` is the actual frame that rejected it, already stored under a new observation ID. Inspect that frame directly instead of discarding it and capturing again.

In `agentSummary.comparison`, `fieldMatch=pixels` or `temporal` means the field matched; `mismatches=screen_changed` means global change exceeded the returned limit, including after any exclusion. A field match does not override global change. A deadline failure remains a deadline failure even if comparison matched. Read `error`, `preInputDeadlineExceeded`, and the per-stage summary together.

Correct the evidenced cause before deciding on a new action. If a media field rejection is traced to an early or freshly rebuilt media baseline while the visible field is unchanged, one scoped `text-prepare` can establish a new baseline to inspect; it does not authorize replaying an unknown input. Do not enlarge an ignore rectangle into a whole horizontal strip, raise tolerance, repeat preparation, or reconnect merely to get past a rejection. If the summary is insufficient, inspect the receipt once for that question. Unchanged repeated failure calls for a concise explanation and new evidence, not a retry loop.

Disconnect the task's own session and check cleanup when finished. Receipts can contain private UI text and paths: keep them local; delete task-owned receipts when no longer needed. No long report or separate timing log is needed for ordinary use unless requested.

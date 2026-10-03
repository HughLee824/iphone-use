# Standard-mode text

Read this once before native text input. Reuse the established executable, execution context, session, keyboard readiness, latest inspected observation and any pending clipboard transaction. Runner uses element references instead.

## Normal path

1. Inspect the screen; tap the intended field if needed and verify focus. Native type does not focus it for you.
2. For the first input, if scoped preparation is supported and the complete field is visible, run `text-prepare --field-rect X,Y,WIDTH,HEIGHT --agent-output`. It prepares the keyboard and obtains a bounded stable media baseline or a new Apple PNG. Otherwise use ordinary `text-prepare` when the keyboard is not prepared. Inspect its attached image directly; no extra `observe`. Keyboard registration can change field geometry and does not establish focus.
3. Select the **complete focused field**, in screen points, from that image. Map both edges using actual PNG dimensions and the returned screen rectangle; round outward if necessary. Never crop away text or the caret to pass guards.
4. Execute one selected text operation. Inspect the attached PNG even after a nonzero exit or `unknown`; queued native input may lack execution acknowledgement. Establish the visible result, never repeat text merely because it is unknown.
5. If `action.result.pasteboard.restorePending=true`, after visual verification and resolution of any paste dialog, call `text-finish` with the current observation and returned transaction ID. It restores that transaction and returns a new observation. Inspect and reuse that image for the next action.

Commands below follow `iphone-use --session SESSION`. Substitute actual values and use `--agent-output` / scoped preparation only when preflight supports them. In Codex, execute through the adapter's combined command/image template.

| Step | Command |
| --- | --- |
| Initial baseline and keyboard | `text-prepare --field-rect X,Y,WIDTH,HEIGHT --agent-output` |
| Replace focused content | `type oN --mode replace --text TEXT --field-rect X,Y,WIDTH,HEIGHT --observe --agent-output` |
| Append at document end | `type oN --mode append --text TEXT --field-rect X,Y,WIDTH,HEIGHT --observe --agent-output` |
| Insert at actual caret/selection | `type oN --mode insert --text TEXT --field-rect X,Y,WIDTH,HEIGHT --observe --agent-output` |
| Restore after reading the result | `text-finish oN --transaction TRANSACTION_ID --agent-output` |

`replace` selects all at current focus. Native `append` moves to document-end, without reading/reconstructing text. `insert` uses the actual selection. Unicode/multiline auto input uses a clipboard transaction: respect existing authorization; never discard unbacked content without explicit permission. Without `--observe`, pasteboard facts are under `result` rather than `action.result`.

For another input, reuse the keyboard and latest inspected observation; re-select geometry if it moved. Scoped type/press and text-finish also return checked baselines. Do not repeat prepare/status/observe just because another operation follows or the observation is older than 30 seconds: execution revalidates it. The normal two-input clipboard path is prepare → input → finish → input → finish, with five images to inspect. Focus actions or recovery may add calls.

## Recover from evidence, once

- `not_dispatched` means input was not sent. A successful `observation.phase=pre_input_rejection` is the actual rejection frame with a new ID; inspect it instead of capturing again.
- `agentSummary.comparison.fieldMatch=pixels` or `temporal` means the field matched, not that the whole screen or deadline passed. Read `error`, `mismatches`, `preInputDeadlineExceeded` and stage summaries together. A direct pixel match needs no temporal exception.
- If an unchanged visible field is rejected because of an early/rebuilt media baseline, one scoped preparation can obtain a new baseline to inspect. It never authorizes replay of unknown input. Read the full receipt only for an unanswered diagnostic question. Do not raise tolerance, reconnect or repeat preparation merely to bypass rejection.
- For an identified video outside the field, supported preparation/input accepts one `--ignore-rect` in screen points, at most 25% of screen. It must exclude neither any part of the field nor adjacent static controls/task context. Do not expand it into a horizontal strip.
- If an image is unavailable or the result remains unclear, recover observation without replaying input. Do not call `text-finish` claiming visual verification before it occurred. If restoration is unconfirmed, preserve transaction facts and follow recovery; do not automatically repeat restoration.

Unchanged repeated failure needs new evidence, not a retry loop. On task completion, disconnect the owned session and check cleanup. Keep private receipts local; no separate report/archive is needed unless requested.

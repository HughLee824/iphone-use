# Standard-mode text

Read this once before native text input. Reuse the established executable, execution context, session, keyboard readiness, latest inspected observation and any pending clipboard transaction. Runner uses element references instead.

## Normal path

1. Before the first input in this session, run `text-prepare --agent-output` if the keyboard is not already prepared. Current builds discover the existing CoreDevice keyboard (`keyboard.serviceSource=coredevice_builtin`) without attaching a hardware keyboard. Inspect the returned Apple PNG; `keyboardPrepared=true` does not confirm focus. Do not prepare keyboards on connections that do not need text.
2. From that new image, open the intended editor or tap the intended field as needed, using `--observe`. Verify the visible field and focus. Use the visible caret/editor state to assess focus, not keyboard visibility alone. Native type does not focus a field for you.
3. Select the **complete focused field**, in screen points, from the latest image. Map both edges using the returned screen rectangle and the dimensions of the image actually viewed; round outward if necessary. Never crop away text or the caret to pass guards. Use this action's observation directly; no second `text-prepare` is required to bind the field.
4. If a visible caret can be identified, confirm its narrow bounds with `--caret-rect X,Y,WIDTH,HEIGHT` on this same `oN`, inside the complete `--field-rect` (width <=4, height 8...80 screen points). Include faint/antialiased tips, not adjacent text. This is your visual assertion; iPhone-use constrains it but cannot prove focus. Never invent a box for a hidden caret or cover an ambiguous text stroke. Execute one selected text operation with that observation and `--field-rect`. Standard observations and pre-input checks use Apple PNG. Inspect the attached image even after a nonzero exit or `unknown`; establish the visible result, never repeat text merely because it is unknown.
5. If a paste permission dialog appears, resolve it within the user's authorization and inspect the resulting image. Permission approval is not proof that the text reached the field. Apply the skill's general screen-change reassessment, including any newly exposed dynamic content. If the editor closed or the text is hidden, use the bounded UI recovery to reopen the same draft and verify it, without typing again or submitting to test whether input worked. If the result cannot be verified safely, report it as uncertain.
6. If `action.result.pasteboard.restorePending=true`, call `text-finish` with the current observation and returned transaction ID **only after seeing the intended text**. This asserts caller verification and restores the transaction; it does not verify text itself. Inspect its new observation before submitting or selecting another action. If verification remains impossible, disconnect the owned session for pending clipboard cleanup and check its restoration result; do not falsely confirm `text-finish` or replay the input.

If the editor was already open before initial preparation, inspect the preparation image and reopen/refocus only if needed. Re-select its location from the new layout. Reuse the prepared keyboard; repeating preparation cannot restore focus. Scoped `text-prepare --field-rect X,Y,WIDTH,HEIGHT` remains available when intentionally observing an already visible field, but the supplied rectangle does not focus or pin that field across layout changes.

Commands below follow `iphone-use --session SESSION`. Substitute actual values and use `--agent-output` / scoped preparation only when preflight supports them. In Codex, execute through the adapter's combined command/image template.

| Step | Command |
| --- | --- |
| Prepare once, then inspect the editor | `text-prepare --agent-output` |
| Replace focused content | `type oN --mode replace --text TEXT --field-rect X,Y,WIDTH,HEIGHT --observe --agent-output` |
| Append at document end | `type oN --mode append --text TEXT --field-rect X,Y,WIDTH,HEIGHT --observe --agent-output` |
| Insert at actual caret/selection | `type oN --mode insert --text TEXT --field-rect X,Y,WIDTH,HEIGHT --observe --agent-output` |
| Restore after reading the result | `text-finish oN --transaction TRANSACTION_ID --agent-output` |

`replace` selects all at current focus. Native `append` moves to document-end, without reading/reconstructing text. `insert` uses the actual selection. Unicode/multiline auto input uses a clipboard transaction: respect existing authorization; never discard unbacked content without explicit permission. Without `--observe`, pasteboard facts are under `result` rather than `action.result`.

For another input, reuse the keyboard and latest inspected observation; re-select geometry if it moved. Scoped type/press and text-finish also return new Apple PNG observations with the field options retained. Do not repeat prepare/status/observe just because another operation follows or the observation is older than 30 seconds: execution revalidates it. The normal path is prepare once → open/focus the field → input → finish. Subsequent input → finish reuses the prepared keyboard; focus actions are needed only when the current image shows they are necessary.

## Recover from evidence, once

Older builds that do not report `keyboard.serviceSource=coredevice_builtin` register a hardware keyboard and can hide an app's composer even when prepared before opening it. If preparation leaves the entire editor invisible, stop text input and report the limitation. Do not invent a field rectangle, reuse the old layout, type blindly or repeat preparation. Current builds fail explicitly if no unique built-in keyboard is available; they do not fall back to hardware keyboard registration.

- `not_dispatched` means input was not sent. A successful `observation.phase=pre_input_rejection` is the actual rejection frame with a new ID; inspect it instead of capturing again.
- `agentSummary.comparison.fieldMatch=pixels`, `appearance`, or `caret` means the field matched, not that the whole screen or deadline passed. Read `error`, `mismatches`, `preInputDeadlineExceeded` and stage summaries together. A direct pixel match needs no caret exception.
- If validation rejects input, inspect the attached current Apple PNG and decide again. Do not assume that re-preparation will fix the rejection, replay unknown input, or raise tolerance to bypass it. Read the full receipt only for an unanswered diagnostic question.
- For an identified video outside the field, supported preparation/input accepts one `--ignore-rect` in screen points, at most 25% of screen. It must exclude neither any part of the field nor adjacent static controls/task context. Do not expand it into a horizontal strip.
- A changed layout is new evidence, even when the preceding click returned `unknown`. Follow the skill's general reassessment and bounded UI recovery; re-select controls, complete field/caret bounds and any exclusion from the current image. A verified missing effect does not authorize replaying text or a submission. Stop when the effect remains uncertain and there is no safe, evidenced next action.
- If an image is unavailable or the result remains unclear, recover observation without replaying input. Do not call `text-finish` claiming visual verification before it occurred. If restoration is unconfirmed, preserve transaction facts and follow recovery; do not automatically repeat restoration.

Unchanged repeated failure needs new evidence, not a retry loop. On task completion, disconnect the owned session and check cleanup. Keep private receipts local; no separate report/archive is needed unless requested.

## Single-frame caret contract

Each native pre-input stage takes one fresh Apple PNG. `--caret-rect` is bound to the action's current observation and original pixels, field and screen context; pixels inside that fixed narrow rectangle are excluded from field and screen comparison. The host checks geometry and binding only, not color, matching backgrounds, caret shape or opacity. In `field-bound-caret-exclusion-v3`, the native-pixel rectangle additionally includes one original pixel above and below its tips, clipped to the field; it never expands sideways. `caretRect` reports the confirmed bounds and `caretExclusionRect` the effective exclusion. Older builds exclude only the supplied bounds. Changes outside the effective rectangle retain the normal checks. No blink-cycle sampling or difference-driven mask expansion occurs. It is consumed with the action and never inherited by an edited observation. Re-evaluate the next screenshot and specify a new visible caret only when appropriate. The existing clipboard-before/after checks both remain; each uses the same original bound assertion.

- `caret_confirmation_required`: inspect the attached current image. Confirm a visible caret there for the next action, or explicitly observe once if it is hidden. Do not replay the old reference or loop on the same rejection. An ambiguous stroke requires visual judgment, not a wider rectangle.
- `invalid_caret_region`: correct invalid geometry or choose a suitable original observation.
- `text_field_changed` / `screen_changed`: inspect the actual change before planning again.
- `input_preflight_timeout`: evidence arrived too late; no input dispatched. It is independent of caret matching.

Example shape only (replace all coordinates and the ID from the actual image):

```sh
iphone-use --session SESSION type oN --mode replace --text '中文' --field-rect X,Y,W,H --caret-rect CX,CY,CW,CH --observe --agent-output
```

Use a host reporting `textCaretConfirmationSupported=true`. Explicit caret calls use versioned wire operations so older hosts reject them rather than silently omitting this check. Any change wholly inside the confirmed box is unexamined, including text mistakenly covered by the Agent. This narrow, action-local exclusion is not proof of caret identity or keyboard focus. Include the actual caret tips but do not widen the box to hide adjacent text changes.

Map both corners from the image actually viewed; preserve fractional screen points rather than rounding each coordinate to the nearest integer. If the tiny caret boundary is ambiguous in a resized preview, inspect the original image or a local enlarged crop with a known crop origin. Include the antialiased tips. The one-pixel tip allowance handles small rounding errors, not a guessed focus location; even in v3, changes wholly inside its two extra rows are unexamined.

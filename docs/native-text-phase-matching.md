# Native text: observation-bound caret exception

The current algorithm is `field-bound-caret-exclusion-v3`. Standard-mode input uses **one fresh Apple PNG per pre-input stage**. It does not sample a blink cycle. Clipboard-based input still checks before staging and again before HID dispatch; both stages refer to the same original observation. The eight-second stage and thirty-second request deadlines remain.

## Confirming the region

The external Agent selects the complete focused field and, when visible in that original screenshot, the caret:

```sh
iphone-use --session SESSION type oN --mode replace --text '中文' \
  --field-rect X,Y,W,H --caret-rect CX,CY,CW,CH --observe --agent-output
```

`--caret-rect` is optional and applies only to native screenshot `type`/`press`, with `--field-rect`. The host resolves the current `oN` from its own cache and constructs the exception from those original pixels and screen context. It never constructs a mask from live differences. This assertion is action-local, consumed with the reference, and never inherited by a new post-edit observation. The Agent must re-evaluate the next image. `text-prepare` does not confirm a caret in its future image.

The rectangle must lie inside the complete field, be no wider than four screen points, 8–80 points high, and have aspect ratio >=3. It is rounded outward to native pixels, then extended by one native pixel at each vertical tip and clipped to the field. Sideways bounds never expand. Receipts report the confirmed `caretRect` and effective `caretExclusionRect`. These are geometry checks only. The Agent, not a pixel classifier, confirms that the region is a caret. There is no color, foreground-shape, matching-background or opacity requirement, and no automatic region search or difference-driven expansion.

## Comparing a fresh image

1. Compare original and current field directly, then with the existing bounded local appearance rules.
2. If those fail and a caret was confirmed, compare the complete field outside its fixed bounds. Pixels inside the bounds are excluded regardless of their color or change.
3. For coarse screen/region comparison, replace exactly those native pixels in a temporary comparison image with their original values before downsampling. This prevents excluded pixels from affecting global scores through interpolation. The actual captured PNG, rejection image and field comparison are never modified.
4. Independent screen/context/source/deadline checks must still pass. The region does not follow a moving caret; any visible change outside it remains subject to the original checks.

No second frame is needed to infer a background or blink phase. The current image never replaces the action's baseline. Both clipboard stages use the same original assertion.

Full-field appearance rules are unchanged: direct channel tolerance 8, four isolated differences up to 16; bounded differences up to 32 only at existing corresponding 5×5 edges; remaining low-contrast differences have a total cap and connected components no larger than 2×2 native pixels. Full details remain in the field guard implementation and historical validation. These are engineering tolerances, not a guarantee to detect every microscopic text edit.

## Errors and receipts

- `invalid_caret_region`: malformed, excessive or out-of-field geometry.
- `caret_confirmation_required`: an unconfirmed field difference resembles a narrow vertical stroke. Inspect the image; confirm a visible caret on that observation or explicitly obtain a suitable new observation. Do not repeat the old input request or enlarge the box to force acceptance.
- `text_field_changed`: the remaining field differs.
- `screen_changed`: independent screen comparison failed.
- `input_preflight_timeout`: the check completed after the dispatch deadline.

A rejection after capture attaches that exact PNG as a new observation, with `not_dispatched`; no input is replayed. Receipt fields distinguish `fieldPixelsMatch`, `fieldAppearanceMatch`, `fieldCaretMatch`, `caretRect` and `caretObservationID`. Agent summaries use `fieldMatch=pixels|appearance|caret|different`. Explicit wire operations `type-with-caret` and `press-with-caret` make older hosts fail closed. Native status advertises `textCaretConfirmationSupported=true`.

## Limits and validation

All changes inside the asserted box are intentionally unexamined, including text accidentally covered by a wrong assertion or movement entirely within the box. The host cannot prove caret identity or focus. The Agent must select the narrow visible caret, include its antialiased tips, avoid adjacent text and re-evaluate after each action. A changed pixel just outside the box remains protected; an undersized box may therefore reject blink changes. This is a bounded, explicit exclusion, not an automatic caret detector. Video exclusions remain separate and cannot cover the field. No OCR, built-in model, AX dependency or Runner fallback is added.

Runner post-input stability remains unchanged. Host regression tests cover fixed caret exclusions, tip rounding, changes outside the region, observation binding and dispatch deadlines.

# Native text: bounded caret exclusion

The current native field algorithm is `field-edge-temporal-caret-v2`. It replaces the original whole-field blend reconstruction after [real-media failure replay](native-text-phase-root-cause.md). It does not change Runner text execution, the global screen guard, explicit video exclusion, observation ownership, input deadlines or unknown-result replay policy.

## Full-field comparison

The original source pixels and coordinates remain fixed. A strict fast path retains the channel tolerance of 8 and the old allowance of four isolated pixels up to 16. A second local appearance path examines every native field pixel without resampling, translation, OCR or semantic text inference:

- Differences above 8 have a total cap of `max(4, min(512, pixelCount / 1000))` pixels. No accepted difference exceeds 32.
- A pixel may use the edge allowance only when both images have contrast in the same channel within the same 5×5 native-pixel neighborhood: at least `max(24, 2 * difference)`. New strong strokes and changes on a flat background do not qualify merely because their area is small.
- Other low-contrast noise must be at most 16, at most `max(4, min(32, pixelCount / 16384))` pixels total, and each 8-connected component must fit within 2×2 native pixels. Connected lines longer than this are rejected.

These are bounded engineering tolerances, not a proof that every possible low-contrast character change is distinguishable from encoding noise. A tiny low-contrast 2×2 change can fall within the documented noise allowance. Tests include real media pixels with injected thin strokes, deleted text and selection-like changes; passing a single positive sample is insufficient.

A native field appearance match can supersede the coarse 48×48 field-region mismatch, just as the previous temporal exception could. The independent whole-screen check must still pass. Coordinate gestures and Runner guards do not use this native-only matcher.

## Automatic caret region

If direct field matching fails, at most six fresh frames are examined within the existing deadline. Current frames must establish an A–B–A return with stable field appearance. Significant A/B changes must form a narrow vertical core: at least 12 pixels, width ≤4 points, height 8–80 points, aspect ratio ≥3 and occupancy ≥30%. Changes must fade in a consistent direction; opposing moving edges reject.

The mask adds exactly two native pixels around that core for antialias/chroma fringes, clipped to the complete field. It never grows after rejection. Outside that mask, A/B and the original/current field must pass the full local comparison. Inside it, source channel values must fit the observed A/B and fixed-rim background range within 16; arbitrary incompatible source marks are not accepted merely because they intersect the mask. No single blend factor is required.

This mask is internal, action-local and color-independent. It does not authorize Agent-specified `--ignore-rect` inside the field. `fieldPixelsMatch`, `fieldAppearanceMatch`, `fieldTemporalMatch` and the confirmed screen-point `caretRect` distinguish the evidence; concise output uses `fieldMatch=pixels|appearance|temporal|different`. A repeated outer check of the same selected PNG reuses only that preflight's evidence. Each clipboard stage starts a new matcher.

Visible displaced cursors, new persistent text outside the mask and wide selections are covered by rejection tests. A hidden cursor's invisible displacement, a mark visually indistinguishable from the caret, or arbitrary custom block/underline cursors cannot be guaranteed by screenshot comparison. No claim of focus or semantic correctness is added.

Source observations are never silently replaced. The schedule, cancellation checks, eight-second preflight budget and thirty-second keyboard request budget remain unchanged. There is no input replay, color list, new external model, automatic Runner fallback or user setting to disable the guard.

## Current validation

Implementation validation is recorded in [the mask implementation report](native-text-caret-mask-validation.md). Historical v1 results below describe the earlier algorithm and do not constitute acceptance of v2.

## Historical v1 validation

Host validation: **362 tests, one existing optional skip, zero failures**; Release build passed. Regressions cover black/white/red/purple/green/blue on light/dark backgrounds, visible/hidden/intermediate source phases, real A–B–A evidence rather than two frames, full-field thin-stroke and selection changes, moving-stroke opposing edges, isolated video noise, six-sample coverage, immediate first-match return and cancellation during the phase wait. Runner post-input code was not modified or revalidated on device.

Device validation (2026-10-02, ordinary Probe, native media + self-written HID):

- A fully visible red source caret required three frames before clipboard staging (1.324 s including Apple checks), then one afterward (0.846 s). The screenshot showed exact `头🙂尾`, 10 UTF-8 bytes, 3 scalars and Edits=1.
- A real faded-red source screenshot (`phase-source-1.png`) exercised **temporal reconstruction** in both stages: five frames / 2.235 s before staging, four frames / 1.727 s afterward; `fieldPixelsMatch=false`, `fieldTemporalMatch=true`. The after-image again showed the exact string and Edits=1. No input replay occurred. These are individual sample timings, not a latency benchmark.
- The dynamic video fixture kept changing throughout and was excluded only outside the complete input field. After Probe's delayed field-change button, the old observation was rejected `not_dispatched` before clipboard staging. The rejection image showed `字段已经变化`, unchanged Edits=1 and no `不应输入`.
- Both temporary clipboard transactions were restored after screenshot verification. Scoped disconnect confirmed keyboard removal, media stop, receiver closure and tunnel release. No other client's session was closed.

HID action receipts remain `unknown/native_input_unacknowledged`: visual Probe counters and returned screenshots establish these successful results, not CLI exit status. Local acceptance evidence: `.local/research/text-phase-cycle-20261002/`; host logs: `.local/research/text-phase-noise-20261002/final-tests.log` and `final-release.log`.

Failures retained during development:

1. Separate Apple checks per frame missed the source phase across six ~one-second acquisitions. Pixel analysis found 475 changed pixels confined to the caret (PNG x=65...72, y=646...706). Input was not dispatched; the staged clipboard was restored. The client lost the reply with Network is down, while the scoped host journal retained the not_dispatched receipt. That IPC error was not independently root-caused. Evidence: `.local/research/text-phase-20261002/`.
2. Media bursts captured both on/off phases, but an isolated pixel on the in-field floating-control edge differed by 10/255; strict 8/255 per-pixel matching rejected. This motivated the bounded isolated-noise allowance. No clipboard write or input occurred. Evidence: `.local/research/text-phase-burst-20261002/`.
3. A half-opacity source caret never recurred within six samples even after fixing sampling and noise. This established the need for A–B–A reconstruction rather than only waiting for the exact original opacity. Again rejected before clipboard staging. Evidence: `.local/research/text-phase-noise-20261002/`.

The local `.5` archive was not rebuilt. Subsequently the [.6 candidate](native-text-candidate-acceptance.md) was built with this implementation and a Runner compilation-boundary fix. Nothing was pushed or published.

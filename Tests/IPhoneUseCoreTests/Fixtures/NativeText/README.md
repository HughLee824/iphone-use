# Controlled media text fields

These PNGs are native-pixel crops of the project's own Text Probe on 2026-10-03.
They contain only the complete test field, the controlled text `边缘验证🙂`,
its cursor, and part of a floating system control. Status bars, device metadata,
identifiers, timestamps and the rest of the screen are excluded. PNG metadata
is discarded. No personal application content or clipboard backup is included.

Each image is 1068×483 pixels, mapped to 356×161 points at scale 3. Cropping
does not resample pixels. `encoded-source` and `encoded-0`…`encoded-5` reproduce
stable field content with media pixel drift; `caret-source` and `caret-1`…`caret-6`
contain an intermediate source cursor phase and an observed blink cycle.

The native field tests load these via `Bundle.module`, need no device or local
research directory, and inject added/removed text into all current frames as
negative controls. The unedited mutation round trip is checked independently.
Local provenance: `video-rim-area-20261003/readonly-phases-v2` and `burst-capture`;
root-cause replay: `caret-root-cause-20261003`. These paths are not runtime inputs.


`blend-source`, `blend-0`, and `blend-3` are 1062×480 exact-size Apple PNG field crops captured on 2026-10-03 after the first scoped-baseline device trial. The controlled text is `第九版短上下文🙂；追加完成✅090824`. The recorded chronological sequence is capture 0 (full), 3 (partial), 6 (full). Captures 0 and 6 have identical PNG bytes (SHA-256 `4fc60bb1f47387fcc4bd2460338da0137f89e0af8e6bcce827cea998479f6f6c`), so both use `blend-0.png` in the test. This deduplicates an observed cycle; it does not invent a returning phase. All field pixels outside the 6×57 native-pixel cursor are identical to the source. Changes at different pixels have opposing RGB directions, exposing the old whole-stroke direction assumption. Private provenance: `.local/research/text-baseline-validation-20261003/`; these fixtures contain neither device identity nor other application content.

The three unique Apple blink images retain a source and two phases; the recorded returning phase shares identical bytes. Media startup-baseline selection was retired when standard observations switched to Apple PNG. Its four startup-only images were removed with that unused test; other field/caret fixtures remain for the active matcher regressions. Full-screen captures and retired evidence remain in ignored local research storage.

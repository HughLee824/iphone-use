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

Only the 14 images used by `NativeTextMediaFixtureTests` are retained.
Standard observations now use Apple PNG; the media samples remain adversarial
regressions for the field matcher, not a supported observation source. Unused
startup/blend samples and full-screen diagnostic captures are excluded.

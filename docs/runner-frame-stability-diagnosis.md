# Runner post-input stability timeout (2026-09-22)

The controlled Probe reproduced `frame_stability_timeout` after successful Chinese/emoji input. The cause in this captured sequence is the exact whole-frame stability criterion: caret fading and small keyboard-region color changes repeatedly reset the timer. The input transport, text result and command correlation succeeded; it was the subsequent image-stability wait that timed out. This diagnosis does not change product behavior.

## Evidence

Base implementation: `cbe37b5`, with documentation commit `9bc4c60`. Environment: macOS 27.0 / Xcode 27.0, paired wired iPhone 12 Pro / iOS 27.0. An ignored local copy of Runner retained each existing post-input PNG in memory and exported XCTest attachments only after the sampling loop ended. It did not change the capture interval, timeout, hashing, UI actions or stability criterion. The diagnostic build installed and connected through explicit Runner mode.

The ordinary Probe's 起始 button reset the field. One explicit `type o2:e19 --mode replace --text '头🙂尾' --observe` then reproduced the timeout. Input completed; the first retained frame already displayed EXACT UTF-8 MATCH, UTF8 10/10, Scalars 3/3, Edits 3. The subsequent observation confirmed the same text. No unknown input was replayed.

`Runner/LiveSessionTests.swift::waitForStableFrame` captures approximately every 200 ms. `packages/runner-support/Sources/IPhoneUseRunnerSupport/FrameStability.swift` requires at least three consecutive identical full-resolution sRGB pixel hashes spanning at least 400 ms, within five seconds. PNG metadata is excluded. All 25 retained frames independently reproduced their live hashes from decoded RGBA bytes and dimensions, ruling out file-metadata differences or a mismatch between analyzed pixels and live hashing in this run.

| Captured fact | Result |
| --- | --- |
| Type sampling | 25 frames, 5052.2 ms, timeout |
| Longest identical span | 207.7 ms, below the 400 ms requirement |
| Initial keyboard transition | Frames 4–6, approximately 0.96–1.38 seconds after the stability wait started |
| Differences after that transition | 493 distinct pixels across the remaining frames |
| Caret | 340 changing pixels inside PNG `[208,438,214,495)`; a 2×19-point region at 3× scale |
| Remaining differences | 153 pixels in the keyboard's upper region, within PNG `[1,1410,695,1526)`, maximum channel delta 2/255 |
| Text, Probe result labels and rest of screen after the transition | Unchanged outside those two regions |

The caret fade includes intermediate brightness values, not just fully visible/hidden states. Several otherwise identical frame pairs differed solely by the 153 keyboard-region pixels with channel deltas of one or two. Exact hashing treats either change as a completely new frame. The captured images establish where these small differences occur, but do not establish UIKit's internal rendering cause.

As a within-session comparison, the preceding fixture tap took 16 samples / 3212.7 ms to pass. It had the same classes of changes (caret and very small keyboard-region deltas), but eventually obtained three identical captures spanning 400.15 ms. This illustrates sensitivity to sampling phase; a successful action does not always yield the same stability outcome.

## Offline causal checks and repair implications

Replaying the captured frames/timestamps with the existing exact rule reproduced failure. Analysis-only counterfactuals used a fixed visually identified caret rectangle and an anchor frame for each candidate stable run:

- Ignoring only that caret would accept at frame 3, approximately 811 ms. The keyboard starts its visible transition afterward, at approximately 959 ms. Therefore simply masking the caret can declare stability before a delayed transition.
- Allowing only channel deltas up to two would accept at frame 10, approximately 2198 ms. This demonstrates the contribution of tiny pixel variations; it is not a validated general-purpose threshold or a product fix.
- Ignoring both also accepts before the delayed keyboard transition. Increasing the five-second timeout might occasionally find a favorable sampling phase, but does not address the exact-comparison problem.

A repair should separate input completion from post-input visual settling, preserve the no-replay rule and fresh observation requirement, and handle bounded caret/rendering differences without ignoring real text/layout/keyboard transitions. The native input-admission caret exception is a different stage and cannot simply be copied into this post-input whole-frame wait. The captured sequence is a useful regression fixture for both false timeouts and premature stability, but does not by itself establish a safe general solution. No global mask, threshold relaxation, timeout change, keyboard-setting change or focus change is implemented here.

## Cleanup and scope

Runner acknowledged shutdown and xcodebuild exited normally. Owned host and xcodebuild PIDs were independently confirmed absent. The diagnostic Runner on the phone was replaced with the previously signed, uninstrumented Runner using Apple's installation command; that restored artifact was not relaunched as another test. Standard-mode code, user's default mode, clipboard and system settings were untouched. No third-party device tools, remote push or release.

Raw attachments, sample timestamps, source instrumentation patch, pixel analysis, offline replay and cleanup/install evidence are retained locally in `.local/research/runner-stability-20260922/`. Host test suites were not rerun for this diagnostic/documentation-only change. The earlier uninstrumented timeout has the same symptom and sample count; its intermediate frames were not retained, so attribution of those exact prior pixels remains an inference.


## Implementation follow-up

The Runner now uses `yiq-local-caret-v1` for visual equivalence, retaining SHA-256 solely for original-image integrity. It compares against a fixed candidate with small bounded color tolerance, and permits a modeled blue-caret fade inside the validated text action target. After a tap, one bounded read-only snapshot can also supply a unique fully visible text field when the keyboard is present; ambiguity or truncation disables that exception. The post-input caret variant confines its fade model to the stroke, preserving adjacent glyphs outside it. Its outermost antialiased pixels require a stationary neutral text edge and channel changes bounded by the measured caret phase; native pre-input admission retains its original uniform-ring behavior. No generic changed-area allowance, downsampling, animation disabling or app mutation is introduced. See [action results](actions.md#执行结果) for thresholds and evidence fields.

The existing three-frame/400 ms criterion and five-second budget remain, with a minimum 1500 ms observation period. This covers the captured delayed keyboard transition; it is not a promise against later asynchronous updates. Timeout retains unknown outcome and now exports the last comparison candidate plus a raw difference image. Protocol `frameStabilityVersion=2` prevents an old Runner silently using exact comparison.

Host validation: 277 Swift tests executed (276 passed, one existing opt-in skip), 45 Python tests passed; Release CLI and signed Runner built. Actual Swift code replayed the original 25-frame sequence and accepted frame index 10 at approximately 2198 ms, with the caret exception recorded and keyboard transition frames rejected. These are host/replay results. The first physical implementation exposed additional timeout causes: unscoped carets after a fixture tap, and excessive Debug-build pixel processing time. Row-wise byte equality, preallocated RGB extraction and avoiding duplicate caret analysis reduced the host Debug replay from 7.80 to 3.16 seconds without changing its recorded-time decision. A second device run passed the fixture tap in 1616.6 ms but exposed caret/text antialias overlap: two boundary pixels did not fit a uniform-background fade. Their narrow post-input edge rule has a synthetic regression covering fading, hiding, wrong phase and adjacent text changes. These intermediate Chinese-input actions remained unknown and were not replayed; Probe nevertheless showed exact text. Final device acceptance is recorded below. Local implementation evidence is in `.local/research/runner-stability-fix-20260922/`.


Final controlled device validation (2026-09-22): the rebuilt Debug Runner completed the fixture tap in 1738.9 ms of stability observation (7 samples, 6 equivalent frames), then completed `type --mode replace --text '头🙂尾'` in 2682.0 ms (8 samples, 3 equivalent frames spanning 610.0 ms). Both final comparisons recorded the caret exception with zero significant changes, and used different original reference/current hashes. The new observation and visual inspection confirmed the exact text, `UTF8: 10/10`, `Scalars: 3/3`, and `EXACT UTF-8 MATCH`. The input was not inferred successful from process exit status. The owned session acknowledged shutdown and xcodebuild exited normally. Evidence: `.local/research/runner-stability-fix-20260922/device-final/`.

Final host validation: 278 Swift tests executed, 277 passed and one existing opt-in skip; 36 targeted tests passed. Release CLI and signed Runner built. The final offline replay still accepts frame index 10 after the recorded keyboard transition. This establishes the controlled UIKit Probe case on the connected iPhone, not arbitrary editors or a universal animation-completion guarantee. No global pixel allowance or timeout increase was used.

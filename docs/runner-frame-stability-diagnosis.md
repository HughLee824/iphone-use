# Runner post-input stability timeout (2026-09-22)

The controlled Probe reproduced `frame_stability_timeout` after successful Chinese/emoji input. The cause in this captured sequence is the exact whole-frame stability criterion: caret fading and small keyboard-region color changes repeatedly reset the timer. The input transport, text result and command correlation succeeded; it was the subsequent image-stability wait that timed out. This diagnosis does not change product behavior.

## Evidence

Base implementation: `cbe37b5`, with documentation commit `9bc4c60`. Environment: macOS 27.0 / Xcode 27.0, paired wired iPhone 12 Pro / iOS 27.0. An ignored local copy of Runner retained each existing post-input PNG in memory and exported XCTest attachments only after the sampling loop ended. It did not change the capture interval, timeout, hashing, UI actions or stability criterion. The diagnostic build installed and connected through explicit Runner mode.

The ordinary Probe's 起始 button reset the field. One explicit `type o2:e19 --mode replace --text '头🙂尾' --observe` then reproduced the timeout. Input completed; the first retained frame already displayed EXACT UTF-8 MATCH, UTF8 10/10, Scalars 3/3, Edits 3. The subsequent observation confirmed the same text. No unknown input was replayed.

`Runner/LiveSessionTests.swift::waitForStableFrame` captures approximately every 200 ms. `Sources/IPhoneUseCore/FrameStability.swift` requires at least three consecutive identical full-resolution sRGB pixel hashes spanning at least 400 ms, within five seconds. PNG metadata is excluded. All 25 retained frames independently reproduced their live hashes from decoded RGBA bytes and dimensions, ruling out file-metadata differences or a mismatch between analyzed pixels and live hashing in this run.

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

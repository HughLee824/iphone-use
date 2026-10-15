# Standalone Runner / USB acceptance

This source change replaces IDE-driven Runner startup with a background launch of the already-installed app and authenticated USB loopback commands. It does not update the released CLI, Runner payload, plugin version or release assets.

## Environment and scope

- iPhone 12 Pro, iOS 27.0.1, macOS/Xcode 27.0; USB connected, paired and unlocked.
- Original installed 0.3.1 Runner; no installation, re-signing or Wireless Data changes during acceptance. Wireless Data was visually confirmed Off before and after the Runner checks. The prepared package's 15 file hashes remained unchanged.
- Source Release CLI; offline development Probe for motion, UIKit transitions, local video and requested interface rotations. No business-app actions.
- This is a single-device validation, not evidence for every iOS/Xcode combination. Explicit setup deployment changed but was not repeated on this phone, to preserve the original installed package and its settings.

## Findings and fixes

1. Cold encoder initialization initially filled the bounded recording pixel queue. Prepare the encoder from an available preview frame before subscribing, then start the recording clock. Frames admitted after subscription are retained; queue bounds are unchanged. Empty streams still wait for their first frame.
2. A complete 90-second dynamic recording failed the old 18-second validation budget. The same file decoded fully: a diagnostic comparison took about 51.4 seconds with RGB conversion versus 23.5 seconds with YUV output under the observed load. Validation now decodes every frame as YUV, with a 15–45 second bounded budget. The original failure sample passed the production validator test in 12.7 seconds; timing varies with host load.
3. A concurrent full-test run coincided with RTP discontinuities and a preview stuck waiting for a keyframe, despite healthy media heartbeats. The new recovery detects sustained dependency loss after decoded pictures, ends any current recording and uses the existing confirmed stop/read/rebind path. Initial startup and quiet retained frames do not trigger recovery. Uncertain cleanup/start remains terminal; input is never replayed. The missing recovery branch is established from state evidence; the cause of the original packet loss is not proven solely by timing coincidence.

## Checks completed

- Swift: 468 tests, 2 conditional skips, 0 failures after the final code change. The original 90-second / 5388-frame recording also passed its opt-in full-decode fixture test.
- Python: 59 tests; Node: 37 tests; Objective-C pinch runtime and plugin sync checks passed. Release build and whitespace checks passed.
- Final Runner build: 90-second dynamic recording completed, all 5388 written frames decoded, validation 11.9 seconds. Motion, transition and local-video frames were inspected.
- Final Runner build: three sequences of left → right → left → right → portrait (15 changes) recovered automatically at the same preview URL. The recording segment ended on the first rotation with `display_changed` and passed complete file validation. Rotation recovery took approximately 2–10 seconds after the fixture's scheduled request; this is not seamless rotation recording.
- Preview, recording and USB control coexisted. A real counter tap changed A: 0 to A: 1. One post-action stability wait returned `unknown`; the visible effect was verified and the input was not replayed. A separately requested stop completed the static segment after about 41 seconds with a valid file.

Runner completed a 1800.003-second run at the same URL and USB session. Of 897 samples, one frame fetch was unavailable during the automatic continuity recovery described below; the remaining 896 succeeded. The recording started after recovery completed all 5390 frames for 90 seconds, with 12.1-second full validation. Host RSS remained approximately 48–62 MiB, without sustained growth. This passes continued operation and automatic recovery, not uninterrupted playback.

Standard completed 600.033 seconds of regression preview. All 15 requested rotations recovered; the 12 unavailable samples out of 299 occurred during rotation synchronization. A recording segment ended with `display_changed` and passed validation. A 60-second static recording completed normally, and a 90-second motion/transition/local-video recording completed with all 5293 frames decoded in 35.1 seconds, within the 45-second budget. The preview retained its shared media stream during recording finalization and validation. There were no decoder errors, queue overflows or dropped units in the final receiver. Resource-related stalls remain visible: its maximum decode-queue wait reached about 1.8 seconds, so this is functional regression acceptance, not a smooth-playback guarantee.

A standard control tap after stopping the static recording visibly changed A: 0 to A: 1 while preview remained open. Its native input acknowledgement was uncertain; the image confirmed the effect and the tap was not replayed. Standard RSS rose temporarily during PNG observation (about 327 MiB peak) and ended near 68 MiB; this short run is not a standard-mode memory endurance test.

Both modes acknowledged media/session cleanup; Runner exit was confirmed. Temporary preview tabs were closed. A final read-only check found the same original installed Runner container. Only host code and documentation changed; local recordings, screenshots and diagnostic files are excluded from the PR.

## Fault-injection limits

A 3-second pause of the owned host recovered buffered video without observed packet loss, so it did not exercise the new dependency-loss branch. A 15-second pause lost media health and correctly closed the preview; explicit reconnection was required. These injected failures are kept separate from ordinary continuous-running acceptance. These pauses did not exercise the exact healthy-heartbeat/keyframe-loss branch. During the subsequent uninjected long run, it occurred naturally at about 985.5 seconds: four RTP discontinuities, a decoder waiting for a keyframe and healthy media heartbeats. The page reported `Recovering video continuity` at 991.5 seconds and fresh decoded pictures returned at 993.5 seconds, without reopening the page or reconnecting USB. Thus hardware evidence exists for this recovery, with an approximately eight-second observed interruption rather than uninterrupted playback.

Before the fixes, one CoreDevice media attempt also failed while the Runner USB command route remained available. A later read-only lock-state query succeeded, and the owned failed session was cleaned before reconnecting. Neither that error nor a startup timeout is reported as evidence that WLAN permission is required.

Raw logs, screenshots, recordings, device identifiers and signing metadata remain in ignored local evidence, not in this repository. Stable 30 fps, flawless operation under arbitrary resource pressure, physical unplug/replug recovery and seamless rotation recording are not claimed.

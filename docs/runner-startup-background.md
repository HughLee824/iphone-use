# Runner background transition after authorization

Local investigation on 2026-10-15, using iPhone 12 Pro / iOS 27.0.1 and Xcode 27.0. The published 0.3.2 archive is unchanged. This document records the source fix and targeted hardware checks, not release-package acceptance.

## Failure and successful control

Device unified logs establish the following sequence in the failed 0.3.2 launch (local time):

| Time | Event |
| --- | --- |
| 19:31:49.698 | LocalAuthentication returns success. |
| 19:31:49.710 | testmanagerd logs `Finished enabling Automation Mode`. |
| 19:31:49.987 | SpringBoard receives Home, but logs `Transient overlay handled home button press`. |
| 19:31:50.270 | Runner transitions to the foreground. |
| 19:31:50.275 | SpringBoard unregisters the LocalAuthenticationUIService remote alert scene. |
| 19:32:20.310 | XCTest fails with Code 10300: `Failed to background test runner within 30.0s.` |

In the successful control, the same installed payload and launch configuration enable Automation Mode at 19:34:02.723 without an interactive password dialog. Home at 19:34:03.004 causes SpringBoard activation, Runner backgrounds at 19:34:03.014, and USB commands become ready. Both launches use `--no-activate`; that flag does not guarantee UIKit will already be in the background during XCTest initialization on this device/runtime.

The failure is after successful authorization, before the command server starts. The startup Home event is consumed by the departing authentication overlay instead of backgrounding Runner. This is not evidence of missing WLAN permission or an authorization-channel rejection. Wireless Data remained Off.

Inspection of the installed XCTest framework confirms that its initializer registers an application-background notification expectation, sends one `_silentPressButton:1`, and waits up to 30 seconds. It does not send a second Home when the first is consumed by an overlay. XCTestCore loads the test bundle before this initialization, which provides the insertion point for the candidate guard.

## Startup guard

`RunnerStartupGuard` installs at test-bundle load only for a host-managed, token-bearing session. It checks the runtime method signatures before replacing XCTest's startup Home implementation. For the first main-thread Home request it restores the original implementation immediately, pumps the main run loop until UIApplication has been continuously active for 350 ms, then calls the original Home exactly once. If the app has already entered the background, no Home is needed. If activation does not settle within five seconds, it sends no input and leaves XCTest's own failure authoritative.

The command test also removes any unused hook before starting its server. Non-Home buttons and subsequent user commands retain their original behavior. The guard neither bypasses authorization, changes network permissions, restarts the app, nor replays an uncertain control command. Diagnostic logs use `IPHONE_USE_STARTUP_HOME`; ping includes `startupGuard` facts.

This is a narrow adapter to a private XCTest method, with signature checks rather than an assumed cross-version ABI. The 350 ms settling interval is a mitigation for the observed dismissal race, not a public API guarantee that every system overlay has disappeared. Unsupported runtimes remain unchanged and require separate verification.

## Verification so far

- Twelve host-runtime cases pass: unmanaged launch, a short session token, active, inactive-to-active, interrupted activation, already backgrounded, backgrounded during the wait, bounded timeout, non-Home button, non-main-thread Home, unused-hook removal and incompatible method encoding. Later Home calls are checked for absence of the startup delay.
- Full host regression: 468 Swift tests, two conditional skips, no failures; 59 Python tests and 37 Node tests pass. Plugin synchronization and whitespace checks pass. The initial sandboxed Swift invocation could not create its compiler sandbox, and sandboxed Python CLI subprocesses were terminated; the reported passes are the completed host-permission reruns, not those failed attempts.
- The iPhone test bundle builds with the current Xcode SDK. A locally signed candidate replaces only the test bundle in a copy of the prepared 0.3.2 app; the original prepared files and released package are untouched.
- On the phone, a cached-authorization launch logs the guard, dispatches Home once, backgrounds successfully and accepts USB commands. Wireless Data Off is visually verified in Settings. Probe launch, a fixture-changing tap and ordinary Home work. The tap's post-action stability wait returns `unknown`; its visible effect is verified without replay.
- Real browser preview works. A concurrent ten-second recording completes and validates all 282 frames; media remains retained for preview. Fifteen preview samples over fifteen seconds all succeed. Session shutdown acknowledges Runner exit and the temporary browser tab is closed.
- Additional cached-authorization launches covered both initially active and inactive UIKit states. Lock/unlock and manually disabling Enable UI Automation did not force a password prompt in those checks. In the latter check, Settings displayed the switch off while AutomationMode logged an enabled state; the switch is not evidence of authentication expiry. Each attempt followed a user request or changed device state, and each owned session was cleaned up. These checks are not counted as interactive-authorization acceptance.

## Fresh password authorization: passed on this device

After the user rebooted the phone, the first connection attempt timed out during CoreDevice device-info lookup, before Runner launch. A read-only device-info query then succeeded with the device booted, paired and the USB tunnel connected. The following Runner launch genuinely requested `Enable UI Automation`, and the user completed the password prompt on the phone. No new build, permission change or automatic Runner relaunch was used between requesting and completing authentication.

| Local time | Candidate evidence |
| --- | --- |
| 21:22:28.248 | testmanagerd requests `Enable UI Automation`. |
| 21:23:09.021 | `User authenticated, forwarding authorization to writer daemon`. |
| 21:23:09.061 | `Finished enabling Automation Mode`. |
| 21:23:09.112 | Guard starts with UIApplication inactive (`state=1`). |
| 21:23:09.634 | Runner transitions to foreground. |
| 21:23:09.648 | SpringBoard unregisters the authentication alert scene. |
| 21:23:10.393 | The one startup Home arrives after alert dismissal. |
| 21:23:10.412 | Runner transitions to background. |
| 21:23:10.593 | Guard reports `home_dispatched`; USB readiness follows successfully. |

Unlike the original failure, Home is dispatched after the authentication overlay is gone and is not consumed by that overlay. Runner backgrounds about 1.35 seconds after Automation Mode is enabled, with no Code 10300 timeout. This supplies real-device evidence for the previously missing interactive-authorization path; cached-authorization successes above are not substituted for it. The guard's reported 1.485-second duration includes the original Home dispatch, not just the settling interval.

After this authorization, Settings visually confirmed iPhone-use Wireless Data Off. Opening apps, typing a Settings search and tapping its result worked; the search returned an uncertain post-action stability result, but its actual text and result were inspected without replay. The real in-app browser preview displayed the offline Probe. A concurrent ten-second recording completed with all 242 frames decoded by file validation, and all fifteen preview samples over fifteen seconds succeeded. Recording finalization retained media for preview. Shutdown acknowledged Runner exit and the temporary preview was closed.

This is one successful interactive-authorization run on the stated device/runtime, not a guarantee across every dismissal duration, device or XCTest version. Reboot triggered reauthorization in this experiment; this does not establish Apple's complete authentication expiry rules or make reboot a required normal workflow. The locally signed candidate remains installed; the Homebrew CLI and original prepared payload remain unchanged. No all-runtime or long-duration acceptance is claimed by these checks. Raw logs, screenshots, signing metadata and recordings remain in ignored local evidence.


## Standard regression and PR scope

The same public 0.3.2 Homebrew CLI was used for standard; this change does not modify its host source or load the Runner test bundle in standard mode. With the candidate Runner installed but stopped, a fresh standard session reported control available. The offline Probe counter visibly changed from A:0 to A:1. Portrait → left landscape → right landscape → portrait remained upright and recovered in the same browser preview. Native input acknowledgements were uncertain; each effect was inspected, with no input replay.

A twenty-second portrait recording completed with all 456 written frames decoded by validation. All 25 preview samples over 25 seconds succeeded during recording and finalization. An additional static right-landscape recording retained one frame for about 21.75 seconds and validated successfully when stopped. During that static recording, observation returned the existing `native_snapshot_freshness_unavailable` safety result without ending the recording; stopping it restored observation and allowed the return to portrait. This matches the [documented static-frame limitation](local-preview-prototype.md), not uninterrupted observation during every recording. Standard shutdown confirmed backend and media cleanup; its temporary preview tab was closed. Wireless Data was left Off throughout.

Required checks for this scoped PR are complete: fresh-password and cached-authorization Runner starts, post-start control/preview/recording, standard smoke regression, runtime guard removal and failure-path tests, host regression tests, and iPhone Runner compilation. The shipped Homebrew CLI, original prepared package, release assets and versions are unchanged. Local signing output, device logs, images and recordings are excluded from the PR. Broader device/OS compatibility and installation of a future release archive remain release validation work.

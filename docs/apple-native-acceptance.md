# Apple native M2–M3 acceptance

This procedure separates host checks, device media/lifecycle checks and visually verified input. It targets the experimental macOS/iOS 27 adapter. Run from the repository root with the installed Apple toolchain and a paired physical device. Do not run a third-party device client or start a Runner to prepare native acceptance. The product's default backend remains XCTest; every native connection below selects `apple-native` explicitly.

Keep all device identifiers, screenshots and raw protocol evidence in an ignored private directory under `.local/research/`. Use a new output directory for every run; failed or unknown results are evidence, not a reason to replay input.

## Host and compatibility checks

```sh
AGENTSOMA_NATIVE_HOST_SMOKE=1 swift test
swift build -c release
python3 -m unittest discover -s scripts/tests -v
node --test scripts/tests/test_agent_templates.mjs
python3 scripts/sync-plugin.py --check
```

The opt-in Swift check loads the installed Apple media negotiator but does not connect to a phone. The ordinary `swift test` skips that installed-framework check. These tests validate request correlation, submission/cancel ordering, stale observations, coordinates, media ownership and failure bookkeeping; they cannot prove a real tap.

For native control diagnostics, `NativeControlStatusTests` checks reason precedence, transient media health, exact rejection snapshots and recovery guidance; `HostTests` checks the actual IPC response composition. An unavailable-control error keeps its existing top-level code and adds the specific `result.controlErrorCode`. Uncertain HID state requires explicit reconnect, while a stale image requires observation. Local IPC loss only requests checking the original session and never establishes that it exited. The native-only client test uses a missing local Unix socket and saved host configuration; no device connection is made. See [the recovery contract](apple-native-backend.md#control-diagnostics-and-recovery).

For the unchanged Runner compatibility requirement, compile without signing or running:

```sh
xcodebuild build-for-testing \
  -project Runner/AgentSomaRunner.xcodeproj -scheme AgentSomaRunner \
  -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath .build/ci-runner \
  CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.0
```

## Media and lifecycle, without input

```sh
swift scripts/verify-apple-native.swift \
  --output .local/research/native-lifecycle-RUN \
  --duration 300 --cycles 3 --interval 15
```

The script uses the built release CLI, selects exactly one discovered wired iPhone, or accepts `--device ID` from `agentsoma devices`. The first cycle maintains a media session for five minutes; subsequent cycles reconnect explicitly and maintain it for one interval. Failure stops the sequence. It neither taps nor launches an app, changes settings, starts XCTest, captures the screen or uses a socket inventory.

A passing `result.json` requires native readiness, a healthy RTP/RTCP receiver, nondecreasing counters and packet progress, then acknowledged owned media stop, own tunnel assertion release, cache removal and actual host exit. Every CLI command's stdout/stderr and the session diagnostics are retained. `cycle-N-samples.json` contains optional host RSS and numeric file-descriptor counts from Apple's `ps`/`lsof`; unavailable metrics stay null. Samples help identify growth but do not prove absence of leaks. Report measured duration, cycles, counter progress and metric ranges separately.

`status` intentionally does not renew the product's idle timer. The script sets an independent session idle limit longer than the requested sampling duration. SIGINT/SIGTERM requests cleanup after the current bounded command; a failed cleanup is recorded and not retried automatically. Force-kill, malformed startup output or a lost connect response may leave cleanup unconfirmed; inspect the recorded session and logs instead of terminating unrelated processes.

To test Device Hub independence, quit it normally when idle and record that neither Device Hub nor Xcode is running. Record initial tunnel state, then use the same script. This does not establish reboot/re-pairing behavior or independence from Apple's background services.

## Screenshot → explicit tap → screenshot

1. Unlock the phone and open the controlled Probe manually. Use `agentsoma devices` to obtain the actual device identifier.
2. Connect with `.build/release/agentsoma connect --backend apple-native --device "$DEVICE_ID"`. Record the returned session, generation and capabilities. `ok=true` alone does not establish tap readiness.
3. Run `.build/release/agentsoma --session "$SESSION" observe`. Read the returned PNG, preserve it privately, and choose a Probe target from that image. Convert original image pixels to screen points using the observation's actual scale; undo any viewer resize/crop first.
4. Submit one `.build/release/agentsoma --session "$SESSION" tap "$OBSERVATION" --x "$X" --y "$Y"` while the observation is current. The 30-second age limit and pre-input screen guard remain enabled. An expired observation requires a new inspection and a new explicit action.
5. Read the action's attached after-observation. Verify the intended target counter or state, plus unchanged unrelated focus/scroll state. Retain source/after observation IDs and action ID. Native send barriers return `outcome=unknown` even when the external observer confirms the effect; do not treat the CLI's nonzero status as permission to retry.
6. Save evidence before disconnect removes the observation cache. Disconnect the exact session and inspect the cleanup acknowledgements.

This procedure requires an external human/agent to inspect the images. The scripts do not implement visual judgment or encode a reusable coordinate for an arbitrary screen.

## Coordinate swipe on the controlled Probe

Use the same explicit native connection and fresh screenshot procedure. Check `capabilities.swipe` and choose two points wholly inside the visible Probe scroll area, away from text fields, navigation edges and other controls. Convert both points from the original PNG to screen points using the captured scale. Submit one short swipe:

```sh
.build/release/agentsoma --session "$SESSION" swipe "$OBSERVATION" \
  --from-x "$START_X" --from-y "$START_Y" --to-x "$END_X" --to-y "$END_Y" \
  --velocity 500 --hold-duration 0.2
```

For this backend, velocity means original PNG pixels/second. A terminal hold can reduce momentum but does not guarantee a specific scroll distance. Keep the default screen guard; it protects the entire swipe corridor. Native input currently requires original portrait orientation and bounds planned motion to 10 seconds. Cancellation, media loss and deadline expiry attempt RELEASE at the last attempted position without a new connection or MOVE replay.

Preserve the action response and attached after-PNG. Verify the intended scroll direction using both visible rows and Probe's scroll offset, and check that target-hit/generation/focus counters did not change unexpectedly. Record the source/after observation IDs, requested motion, queued MOVE count and measured host duration separately from visual acceptance. `outcome=unknown` remains correct after local queue completion. A later swipe must be chosen from a fresh observation, never automatically repeated after uncertainty. Host cancellation/failed-MOVE tests are separate from on-device swipe interruption acceptance.

For idle USB removal, record a healthy session before asking a human to unplug, then read media counters and Apple's actual transport inventory. USB removal can switch to `localNetwork` while media continues. This verifies continuity under that event, not transport loss or release during contact. Disconnect only the owned session and preserve cleanup facts; do not disable networking or change device settings to manufacture a failure.

## Cancellation and channel-close fault host

`scripts/native-contact-fault-host.swift` is a development-only harness linked to the actual debug backend. It does not ship in the CLI and sends no input on startup. The following build command matches the validated Xcode 27 Swift build layout:

```sh
swift build
mkdir -p .local/research/native-fault-build
NATIVE_BUILD="$(swift build --show-bin-path)"
swiftc -parse-as-library -I "$NATIVE_BUILD" \
  -Xcc -fmodule-map-file=.build/out/Intermediates.noindex/GeneratedModuleMaps/AppleNativeBridge.modulemap \
  scripts/native-contact-fault-host.swift \
  "$NATIVE_BUILD/AgentSomaCore.o" "$NATIVE_BUILD/AppleNativeBridge.o" \
  -o .local/research/native-fault-build/ContactFaultHost
.local/research/native-fault-build/ContactFaultHost --help
.local/research/native-fault-build/ContactFaultHost --self-test
```

In one terminal, start an owned host with a discovered device and a new evidence directory:

```sh
.local/research/native-fault-build/ContactFaultHost \
  "$DEVICE_ID" signal-after-contact .local/research/native-signal-RUN
```

The host prints its session/directory/PID and writes `session.json`. In another terminal, wait for `agentsoma --session "$SESSION" status` to report native readiness, then follow the screenshot/explicit-tap steps above. Preserve the before-PNG before tapping: the signal run deletes the session cache on shutdown. Evidence logs are copied to the specified directory when the host exits.

- `signal-after-contact` sends real SIGTERM only after CONTACT's send barrier. Expect cancellation observed, one RELEASE queued through the original connection, an unknown action result, and scoped cleanup. Post-action screenshot capture is expected to fail because the cancellation token is active; inspect the phone through a new explicit observation session.
- `close-hid-after-contact` closes only this client's HID channel after CONTACT. Expect failed RELEASE attempts without a replacement connection, `releaseUncertain=true`, tap disabled and no further input dispatch. Explicit disconnect should still confirm owned media/tunnel/cache cleanup but must not claim overall clean shutdown. A screenshot may show the action happened despite the failed release. Preserve that uncertainty.
- `signal-after-move` and `close-hid-after-move` use the same faults after **12 successful changed-position MOVE send barriers**. Stationary reports, the initial CONTACT and failed sends cannot arm the trigger. Use a short Probe coordinate swipe long enough to reach that count, with the same fresh-image checks. A gesture ending before the trigger is not interruption acceptance. These are local queue-completion barriers, not device execution acknowledgements.

For MOVE modes, archive the source PNG and snapshot immediately after observing, before issuing the action. Do not wait until the end of the run: the observation cache retains only two entries, and signal shutdown removes it. For a returned after-observation, copy its PNG and snapshot before any further observation. For the signal mode, expect the attached capture to fail because the session is closing; wait for its scoped cleanup, explicitly open a new session and archive that new observation as the post-signal state. Keep its distinct device-session generation and observation ID.

`fault-events.jsonl` associates attempts and barriers with normalized HID coordinates. Check exactly one fault after the required MOVE barriers. Signal mode should show cancellation followed by one RELEASE barrier at the last queued MOVE coordinate. Channel-close mode can attempt the next MOVE and RELEASE, but both must fail before submission (`possiblySent=false`), with no later send barrier. RELEASE uses the last attempted coordinate conservatively. The action stays unknown, both tap/swipe capabilities are withdrawn, and a different subsequent Probe action must be rejected before dispatch. Preserve acknowledged media/tunnel/cache cleanup separately from unconfirmed release and overall shutdown. Do not treat successful visual scrolling as proof that RELEASE arrived.

The harness's `--self-test` exercises only fake-transport arming, including stationary/failed reports. The host test `testSwipeInterruptedAfterMovesKeepsReleaseAndClosedChannelFactsSeparate` also checks the production transport's closed-channel rejection. Neither is device acceptance. Normal explicit recovery uses a new ordinary session, a fresh image and a different controlled action; it never replays an interrupted swipe.

Use a different controlled target and fresh observation for any subsequent explicit recovery action. Do not replay the uncertain action. These modes verify a host signal and a client channel closure; neither substitutes for pulling the physical cable, killing the process without cleanup, or guaranteeing device touch release across link loss.

## Minimal ASCII input on Probe

Connect explicitly with `--backend apple-native`. Observe the controlled Probe, choose a focus tap from the PNG if needed, then inspect a new screenshot for the intended field and caret. Native typing never focuses implicitly. Submit one short `type "$OBSERVATION" --mode insert --text 'Ab7!?'` with the current screenshot reference, not an AX node. Keep the original portrait and default screen guard.

The first request lazily registers an owned keyboard, which can hide the soft keyboard. If the subsequent guard returns `not_dispatched`, inspect a new observation and decide explicitly whether a new input action is appropriate. Do not automatically retry. Save the before image before input evicts it, then archive the attached after-image immediately. Check exact text, case, symbols, caret and unrelated Probe counters; a queued-character count or exit status is not acceptance. Never replay text after an unknown outcome.

Disconnect the exact session and check `keyboardRemoveAcknowledged` along with media/tunnel/cache cleanup and actual host exit. The keyboard ID and unique product must match before removal; same-connection enumeration after the removal barrier must confirm absence. Preserve failures separately. Printable ASCII validation, modifier ordering, release on cancellation, lost creation/send replies and foreign ownership are host-test cases; only explicitly performed device cases can be marked accepted.

## Chinese soft-keyboard composition

On the controlled Probe, inspect the current keyboard and choose an already-installed Chinese input method through its visible globe control. Do not add keyboards or enter settings. Use fresh screenshot-coordinate taps for the visible Pinyin keys, inspect the composition and candidate row, then explicitly select the intended candidate from the new image. Candidate position and ranking are not stable identifiers. Check both the field and Probe value label after selection; underlined Pinyin/marked text is not a committed Chinese result. Preserve unrelated counters and cleanup facts as for other taps.

Report this separately from hardware-HID batch Pinyin and direct Unicode insertion. A screen-guard rejection is not a permission denial or proof of unsupported Chinese HID; preserve its not-dispatched outcome, diagnose changed pixels and do not repeatedly retry or relax the default guard to obtain a pass. The current tested sample is `你好` through soft-keyboard taps, with no submission or Return.

## HID Pinyin through a visually selected field

Confirm an existing Chinese IME and focused Probe field from the screenshot. If using `type "$OBSERVATION" --mode insert --field-rect "$X,$Y,$WIDTH,$HEIGHT" --text zhongwen`, select the complete field in that observation's screen points; never copy a rectangle from another device/page or shrink it to exclude text/caret. Omitting `--field-rect` preserves strict whole-screen comparison. Registration can hide the soft keyboard and must still fail the global guard before key dispatch.

Inspect any `pre_input_rejection` image and actual guard metrics before making a new explicit decision. It is a valid newly cached pre-input observation, not an after-action result. Preserve it and the old source immediately; no recapture is substituted and no failed action is replayed. Input-field changes, including caret animation, can still reject with zero local tolerance. Do not adjust thresholds or repeatedly submit without new evidence.

When the HID action is dispatched, inspect its after-image for composition and the intended candidate. Select the actual visible Chinese candidate with a separate screenshot-bound tap; never assume candidate 1 is correct or use Return to submit the app. Verify committed text in the field and Probe label, disappearance of composition/candidates, unchanged unrelated counters and owned cleanup. The tested sample appended `中文` using HID `zhongwen` and a visually chosen candidate. This is distinct from soft-keyboard taps and from unsupported direct Unicode insertion.

## Acceptance boundaries

The implementation evidence is summarized in [the backend report](apple-native-backend.md). Physical unplug during contact, SIGKILL, reboot/re-pairing, device coexistence, rotated/edge input and extended stress remain separate tests. Do not report them as passed based on these scripts or host fakes. No release or default-backend migration is part of M2–M3 acceptance.

## Explicit literal text and in-session clipboard completion

Use a newly built native host. Under Probe-only clipboard authorization, inspect a fresh screenshot of the focused controlled field. Send one short pure-ASCII payload with `type "$OBSERVATION" --mode insert --method paste --text ' A7!? exact'`. Confirm `textInputMethod=apple-pasteboard-hid-paste`, one paste chord, and the exact final text in the after-image; do not infer success from transport facts. Separately check a longer ASCII payload and representative combined Unicode sequences where the whole result is visibly verifiable.

After resolving any paste dialog and verifying consumption, use the current post-input screenshot in `text-finish "$OBSERVATION" --transaction "$TRANSACTION"`. Confirm restoration readback, a new observation, and that native media and keyboard remain available. A second explicit paste should allocate a new transaction and original-content backup; its cleanup must not reuse the old token. Any stale reference/transaction must fail before restoration. Never restore early based on a timer, replay unknown input, or overwrite a foreign clipboard writer. Save only ownership/type/count/match facts for original clipboard contents.

The 2026-09-20 implementation has host/CLI tests and a successful release build. Physical validation after unlock reached a healthy native session and passed input preflight, but clipboard preparation PULL timed out before any SET or paste key. Apple CLI pasteboard info independently timed out too, while screenshot capture worked. Owned cleanup succeeded. That initial attempt did not validate the additions. Subsequent explicit user authorization allowed replacing the unreadable clipboard with a disposable fixture. New device acceptance passed short ASCII literal paste, Chinese/emoji paste and two distinct in-session finish transactions, with exact independent fixture restoration and owned cleanup. Product code still refuses to overwrite an unreadable original. Long ASCII and combined Unicode sequences remain untested on device. See the backend report for evidence boundaries.


### Reproducible long-text Probe

`scripts/NativeTextProbe.xcodeproj` builds only a normal iPhone application from `scripts/native-text-probe.swift`; it has no test target, Runner, clipboard API, network channel or text-injection endpoint. Supply your own development team and provisionable bundle ID:

```sh
xcodebuild -project scripts/NativeTextProbe.xcodeproj -target NativeTextProbe \
  -configuration Debug -sdk iphoneos DEVELOPMENT_TEAM="$TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$PROBE_BUNDLE_ID" \
  SYMROOT="$PWD/.local/native-text-probe/products" \
  OBJROOT="$PWD/.local/native-text-probe/intermediates" build
xcrun devicectl device install app --device "$DEVICE_ID" \
  .local/native-text-probe/products/Debug-iphoneos/NativeTextProbe.app
```

Select a sample using a screenshot-bound tap. The button clears only the disposable input and focuses it; it never inserts the expected text. Send the corresponding source sample through native `type --method paste --stdin` without an added newline. Select the whole visible input rectangle, including its caret. Check complete received text, `EXACT UTF-8 MATCH`, byte/scalar counts and one editing event. The comparison uses UTF-8 arrays, not Swift canonical-equivalent String equality. It is a fixture assertion visible to the external agent, not a new backend semantic-verification capability. Confirm with a current screenshot and complete `text-finish` separately for every transaction.

The 2026-09-20 controlled run passed 99-byte ASCII (99 scalars), 379-byte Chinese (133 scalars), and 98-byte combined text (37 scalars). The latter includes decomposed and precomposed acute accents, a skin-tone/ZWJ profession, a ZWJ family, a regional-indicator flag, a keycap and a variation-selector heart. Each produced one edit and exact bytes; all three restorations succeeded in one media/keyboard session. All 17 observations were archived before cache eviction. The signed device build used the same source in the existing local Probe target/bundle; the checked-in standalone project separately passed an unsigned iPhoneOS build and was not installed in that run.

Input guards rejected keyboard-registration changes and blinking-caret frames. Some rejections occurred after clipboard staging but before the paste shortcut; retain that pending transaction even though input was not dispatched. One read-only pixel comparison of the rejected pair localized changed input pixels to the caret. Guards were not relaxed, and no unknown input was replayed. This demonstrates text preservation, not uniformly reliable admission timing. Near-4096-byte device input, deliberate focus races and disconnect during paste remain separate acceptance cases. Subsequent denied-permission and foreign-writer checks are recorded below.

### Denied permission, foreign ownership and preflight traces

For a controlled denied-permission case, send a single paste action from the current Probe screenshot. If iOS presents a permission dialog, inspect it and choose Don't Allow Paste using a new screenshot-bound tap. Inspect the resulting field and fixture counters, confirm that the dialog is gone, then finish the clipboard transaction using that current observation. `textVerification=caller_confirmed` acknowledges inspection of the outcome, including denial; it is not a claim that the payload was inserted. Never replay unknown input or finish while the dialog is unresolved.

The 2026-09-20 run followed this path: the field remained empty with zero edits, finish restored the original empty clipboard, an independent read confirmed empty, and scoped disconnect acknowledged owned cleanup. The permission run used an experimental preflight build, but both successful preflight stages passed on their first capture without its added waits. Later capture failures showed that the experiment's 120/280 ms waits did not reliably solve local-region rejection; those waits were removed from the final code.

The final code reports each completed `preInputChecks` comparison with stage, attempt, timing, guard metrics and deadline status. Preserve the entire trace and original source PNG, including for rejections after clipboard staging. Do not replace the original comparison baseline, shrink the field to exclude the caret, relax thresholds, or automatically resubmit text to manufacture acceptance. The trace can distinguish local changes, global changes and expired deadlines; it does not classify their semantic cause.

A separate two-connection device probe linked the final production clipboard manager. With only known disposable fixtures and a stable empty original, it verified that another native service client replacing the staged payload causes ownership rejection and skipped restoration. Exact foreign bytes and change identity survived both the first and cached close. Only the still-owned test fixture was then cleared and read back as empty. No HID or media session was used. This is manager/service acceptance, not full CLI foreign-writer completion or proof of atomic check-and-write. Preserve original-content privacy and stop without overwriting when any identity/readback differs.

Evidence: `.local/research/apple-native-preflight-cadence-20260920/RESULT.md`. Final host validation passed 180 Swift tests with one opt-in skip, 30 Python tests, and a release build. No complete device input run was repeated after removing experimental waits.

### Editing modes on a controlled selection

The Probe's sample buttons continue to clear the field and set expected text without inserting it. Its separate **Load edit fixture** row visibly loads disposable `头🙂尾`, focuses the field, selects a defined range and resets editing counters. These buttons set up a test; they do not perform the requested native edit or prove native seed entry. Verify the selected range, unchanged seed and zero edits in the current screenshot before the CLI action. Use the entire visible field rectangle, never crop out the selection/caret.

- `replace`: emoji selected at UTF-16 range 1,2; send `type oN --mode replace --method paste --text '替换🙂'` and the observed complete field rectangle. Require complete `替换🙂`, not `头替换🙂尾`.
- `append`: first Hanzi selected at 0,1; send `--mode append --method paste --text '追加'`. Require `头🙂尾追加`, preserving the selected first character.
- `insert`: emoji selected at 1,2; send `--mode insert --method paste --text '插入'`. Require `头插入尾`, retaining the first/last Hanzi and placing the caret after the inserted text.
- `clear`: emoji selected at 1,2; send `--mode replace --text ''`. Require a completely empty field, not just deletion of the emoji. No clipboard transaction should be created.

The 2026-09-20 release run passed all four cases with complete received labels, exact UTF-8 fixture checks and one native edit per action. Replace additionally used a seed entered through native paste before the visible fixture loader was added. Append/insert/clear used the later visible seed loader to separate editing semantics from repeated caret-guard failures in seed entry. These successes do not establish reliable admission of blinking carets or compatibility with other editors. Preserve not-dispatched failures, partial staging and explicit completion facts alongside successes. Finish each actual paste transaction using its inspected current after-image; clearing needs no text-finish transaction. Do not infer focus/selection confirmation from queued shortcut facts. Multiline positioning, deliberate focus changes and physical interruption during these editing sequences still need separate acceptance.

### Caret exception acceptance

Use the complete visually confirmed Probe field and a source screenshot with a visible isolated blue caret. Run one explicit type action, retaining all `preInputChecks`. Success of this new path requires a trace with nonzero raw local change, `accepted=true`, and `caretBlinkException.algorithm=source-blue-caret-fade-v1`, followed by an inspected complete received text and clipboard completion. A strict pass without that record only verifies input regression. If the source has no eligible caret, strict rejection is expected; do not crop out content, weaken thresholds, or automatically replay unknown input to force this test. Preserve source-off, text/selection/movement, global-change and expired-source negative coverage in host tests.

On 2026-09-20 archived real-image replay passed four eligible blink pairs and rejected hidden-source/text-changing pairs. Live native insert and replace passed with verified text and clipboard restoration, but neither recorded the exception. Media degradation and then leaving Probe bounded the run; live exception-path acceptance remains unverified. The final session cleaned up successfully. Private evidence: `apple-native-caret-20260920/RESULT.md`.

The missing live exception case passed on 2026-09-21 with unchanged `cab41e8`: a fresh visible-caret source yielded nonzero raw local changes in **both** clipboard preflights, each accepted through `source-blue-caret-fade-v1` on its first capture. The after-PNG showed exact `头🙂尾`, 10 UTF-8 bytes / 3 scalars and one edit. Clipboard restoration, scoped media/keyboard/tunnel cleanup and actual host exit were confirmed. This verifies one controlled UIKit case and does not broaden the stated heuristic/focus limitations. Evidence: private `apple-native-caret-20260921/ready/RESULT.md`.

## Diagnosing intermittent media health

Use a single owned native session and inspect the controlled Probe. Record `status.result.media` every few seconds for a bounded focused/caret phase and an unfocused/static phase, preserving the actual sample times, counters and source/after screenshots. Do not stop sampling solely because `healthy` becomes false: retain that failed sample and a bounded read-only follow-up, without input or automatic reconnect. `healthReason=rtp_stale` means only that no accepted RTP packet arrived within five seconds. Compare last-RTP age with peer RTCP receive age, local RTCP send/attempt ages and `displayConnection` terminal-event age/error. None of the diagnostic-only RTCP or connection fields override the input guard. Pre-dispatch rejections preserve their media sample; inspect it even if later status is healthy.

If changing phases requires an action, first inspect a fresh Probe screenshot and use ordinary native guards. When keyboard occlusion makes the visible unfocus button unavailable, restarting only the disposable ordinary Probe app through Apple devicectl is a setup alternative; keep the same media session and document that choice. Do not restart device services, disrupt other clients or weaken checks to obtain a passing sample. Archive evidence and verify owned cleanup and host exit.

The 2026-09-21 diagnostic run completed 45-second blinking and static phases, 16 healthy samples each, followed by one visually verified native focus tap and clean shutdown. The original intermittent failure was not reproduced and remains unresolved; this is diagnostic validation, not a root-cause fix. See private `apple-native-media-health-20260921/RESULT.md`.

## Text cancellation and owned HID channel closure

Build the development fault host using the command above. Its text modes use the actual backend, clipboard manager and HID adapter; there is no production fault flag. Under Probe-only clipboard authorization, inspect the focused complete field, load the disposable replace fixture, archive its source PNG/snapshot, and use `type oN --mode replace --method paste --text '替换🙂' --field-rect "$X,$Y,$WIDTH,$HEIGHT" --observe`. Preserve keyboard-registration rejections and inspect their new image before deciding on a new action. Do not reuse an expired observation or automatically replay an unknown action.

- `signal-before-key`: real SIGTERM at the text-entry clock checkpoint, after clipboard staging/preflights but before any keyboard report. Use only text and fixture taps in this mode; swipe shares the injected clock and is unsuitable. Require a ready owned clipboard transaction in the pre-cleanup exit status, zero keyboard reports, observed signal cancellation without the fallback, `not_dispatched`, and scoped restoration. A new explicit observation must show unchanged text, selection and edit count.
- `signal-after-select-all`: real SIGTERM after Command-A and its empty release report have completed local send barriers. Require three keyboard barriers (GUI, GUI+A, empty), no GUI+V, an unknown action, and no subsequent body reports. A new explicit observation should show full selection with unchanged body and zero edits. Selection itself is a device effect; this case must not be labeled not-dispatched.
- `close-hid-after-paste`: close only this client's HID channel after GUI+V's barrier, before its empty release. Require an unknown action, failed release on the original channel, `releaseUncertain=true` and no later successful report/replay. Inspect the attached image before finishing the clipboard transaction. Preserve failed keyboard removal and `shutdownAcknowledged=false` even if media stop, clipboard restoration and tunnel release succeed. Independent read-only enumeration can establish that the owned service is now absent; it cannot retroactively confirm the old release.

Archive `fault-events.jsonl`, action responses, clipboard completion, shutdown diagnostics and actual host exit. Signal shutdown removes the source cache, so save images before dispatch. New observation sessions must keep their distinct session generation/observation IDs. Record only counts, identities and matches for original clipboard data. The fake self-test checks these checkpoints through the actual HID adapter but does not validate OS signal delivery or physical input.

All three checkpoints were exercised on the controlled iPhone on 2026-09-21. The first left `头🙂尾` and range 1,2 unchanged; the second changed only selection to 0,4; both retained zero edits and restored the original empty clipboard. The third visibly produced exact `替换🙂`, 10 UTF-8 bytes / 3 scalars / one edit, while correctly retaining release/removal uncertainty. An independent service inventory subsequently found the owned keyboard absent, and a new screenshot still showed one edit. All original clipboard restorations were independently read back as empty; all four hosts exited. This is client-channel fault acceptance, **not** physical USB/network loss, SIGKILL, interruption within clipboard payload transfer, or proof of release delivery after disconnection. Private evidence: `apple-native-text-fault-20260921/RESULT.md`.

## Normal local-search workflow

Build/install the ordinary Probe as above. Open **Local search workflow** from its initial unfocused page. The page has a standard UIKit text field and a small in-memory catalog; Return is its only search trigger. No network, account, messaging, settings or clipboard API is in the Probe. Results show the complete query, byte count, search count and exact matching entries, with a visible back navigation that preserves the query.

1. In a new native session, call `text-prepare`. Require `keyboardPrepared=true`, `inputReportsSent=0`, `clipboardAccessed=false` and an attached usable new screenshot. Inspect it; preparation does not confirm field focus. Use the resulting observation to navigate/focus, then inspect the after-image.
2. Use the complete visible field rectangle and `type oN --mode replace --method paste --text '苹果' --field-rect "$RECT" --observe`. Inspect the field, complete query label, six UTF-8 bytes, one edit and zero searches. After resolving any paste permission dialog, restore the transaction with `text-finish` using its current observation. There must be no automatic Return.
3. Inspect the new focused-field image and send `press oN --key return --field-rect "$RECT" --observe`. Require an unknown action with local key/release facts and a new results screenshot showing query `苹果`, exactly one search, two matches (`苹果`, `苹果派`). Do not infer success from the return queue or command exit code.
4. Use a new screenshot-bound back tap, confirm preserved query and refocus explicitly. Replace with `香蕉`, inspect and finish the new clipboard transaction, then send a separate Return. Require exactly two cumulative searches and the two matching banana entries. Record each admission/rejection and screenshot count; no automatic replay or guard relaxation.
5. Check the same session/keyboard remains in use, both paste transactions restored, and owned cleanup and actual host exit complete. This verifies one ordinary UIKit search workflow. UITextView newline behavior, web/custom editors and broader input intent remain separate acceptance cases.

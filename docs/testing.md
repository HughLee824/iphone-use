# Testing and acceptance

Build and test the exact source you intend to distribute. Device-free checks, installation checks and physical-device acceptance establish different facts; report each separately. Raw screenshots, AX trees, device identifiers, signing information and investigation logs belong under ignored `.local/`, not in public documentation.

## Shared engineering checks

On a Mac with full Xcode selected, SwiftLint, Python 3.9+ and Node.js 22+, run:

```sh
python3 scripts/check.py
```

This is also the entry point for CI and release checks. It checks documentation links, runs strict SwiftLint, builds the CLI, runs the shared-package and Core Swift suites, Objective-C runtime doubles, Python integration tests and Node template tests, builds the unsigned iOS Runner, and checks/packages the plugin. `--jobs 2` is the default build concurrency. Missing tools or the required CLI fail the check. Root `swift test` alone does not run the dependency package's tests.

For documentation-only changes:

```sh
python3 scripts/check-docs.py
python3 -m unittest discover -s scripts/tests -p test_docs.py -v
```

The link checker checks local Markdown destinations, heading anchors and HTML resource links in non-ignored repository Markdown. It cannot verify remote URLs, client behavior or the accuracy of prose. Keep English and Chinese entry points aligned. See [architecture](architecture.md#engineering-checks) for module and fixture conventions.

## Prepare a physical test

Use a disposable field or unsaved draft. Record the source commit, CLI version/build, Mac/Xcode/iOS versions, device model and selected mode. Build a fresh CLI and follow [source Runner setup](onboarding.md#源码开发入口) to build, **explicitly install**, and connect the newly signed Runner. Supplying a new `.xctestrun` to `connect` does not install its app. Confirm the running app belongs to the installation being tested; a compatible handshake alone does not prove its binary is fresh.

Use the selected CLI consistently. Preserve each command's exit status and complete receipt, then inspect its actual PNG and relevant AX value. Copy necessary evidence before the observation cache evicts it. Do not automatically retry an input after a timeout, lost reply or `unknown`; observe and determine what happened first. Handle actual device authentication on the phone.

### Ordinary text fixture

The [NativeTextProbe project](../scripts/NativeTextProbe.xcodeproj) builds a normal app from [native-text-probe.swift](../scripts/native-text-probe.swift). It provides disposable controls and exact UTF-8 comparison. It has no XCTest target or text-injection endpoint and is not required to use iPhone-use.

With your own provisionable identifiers and signing configured:

```sh
xcodebuild -project scripts/NativeTextProbe.xcodeproj -target NativeTextProbe \
  -configuration Debug -sdk iphoneos DEVELOPMENT_TEAM="$TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$PROBE_BUNDLE_ID" \
  SYMROOT="$PWD/.local/native-text-probe/products" \
  OBJROOT="$PWD/.local/native-text-probe/intermediates" build
xcrun devicectl device install app --device "$DEVICE_ID" \
  .local/native-text-probe/products/Debug-iphoneos/NativeTextProbe.app
```

Choose a sample using a current screenshot-bound action; the sample button clears/focuses the disposable field without inserting the expected text. Send its corresponding literal sample without an extra newline. Verify complete text, byte/scalar counts and `EXACT UTF-8 MATCH`, rather than only a prefix or a visually similar string. An unsaved Contacts draft can additionally exercise several adjacent ordinary fields; discard it afterwards.

## Text and target matrix

| Scenario | Required observations |
| --- | --- |
| Settings search | Insert, append and clear; check complete final value and transaction facts after search layout changes. |
| Adjacent ordinary fields | Enter distinct values in the first and second fields; replace the first. Check both fields and an untouched neighbor, including autofocus transitions. |
| Custom search field, such as Xiaohongshu | Chinese input, append one distinct suffix, clear. Check the exact value and keyboard state; custom `TextView` exposure must use the same generic path/identity logic. |
| Stale reference | Obtain a new observation, then submit the old reference. Require rejection before input and an unchanged field. |
| Read-only convergence | Inspect `textExecution` stage/read/retry facts. Geometry retries must not add input events. Path/identity changes must still stop the transaction. |
| Text fidelity | Exercise Unicode, combining sequences and supported multiline input. Runner LF requires a text view; ordinary XCTest typing rejects CR/CRLF. |
| Clipboard methods | In standard mode or explicit touch-paste, verify the complete staged text, any system permission UI, and owned clipboard restoration with `text-finish`. Foreign content must not be overwritten. |

Use fresh observations between actions. The full AX capture must remain separate from compact presentation: verify a page with more than 200 exposed nodes and inspect a target beyond the initial display budget. Neither hidden nodes nor identical labels establish that a target is actionable. Automated path/identity, replacement, fresh-snapshot and bounded-validation tests cover adversarial cases that cannot be reliably induced manually; device tests complement them.

There must be no host/Runner replay of an uncertain command. A single XCTest call can still perform internal work or retries controlled by Apple; input-event counters do not prove a universal exactly-once delivery guarantee. Full-path and AX-identity validation also cannot eliminate the final check-to-input race or platform identity reuse. See [AX design](architecture.md#runner-路径定位与完整-ax-采集) and [action outcomes](actions.md#执行结果).

### Recorded refactor acceptance

Source `931b4b726d47605148f5c5481ba07b11bd5ff0e9` was checked using a rebuilt CLI and newly built, explicitly installed Runner on **iPhone 12 Pro / iOS 27.0.1**. This is a bounded source-build result, not a release-package or all-device certification.

| Check | Recorded result |
| --- | --- |
| Settings: insert, append, clear | All three completed; geometry converged through read-only checks, with no input replay. |
| Contacts unsaved draft: first field, second field, first-field replacement | All three completed; neighboring field content remained correct. |
| Xiaohongshu search: Chinese insert, append, clear | All three completed; suffix appeared once. |
| Reuse of an old reference | Rejected before dispatch; cleared field stayed empty. |
| AX collection | Settings exposed 371 nodes and Contacts 272, beyond the former 200-node limit. |
| Cleanup | Test text cleared, draft discarded and session disconnected. |

These nine transactions showed no wrong-field input or duplicate insertion. Fresh-snapshot and identity behavior also have automated regression coverage; the physical run alone cannot prove absence of every possible stale-cache condition. It did not revalidate native HID, every gesture, all clipboard races, sustained media performance, fresh-Mac signing or other device/OS combinations.

## Media, gestures and failures

For changes to those paths, add an affected-scope matrix rather than treating the text results as sufficient:

- Test screenshot-derived coordinates in portrait and both landscape directions, gestures on disposable controls, and fresh observations after rotation.
- Exercise dynamic content with default guards and explicitly chosen exclusions/overlay targets. A pre-dispatch rejection must preserve input facts; do not weaken guards to make acceptance pass.
- Check preview alone, recording alone and coexistence, then stop each consumer and disconnect. Decode the actual MP4 and inspect frames, orientation, timestamp continuity and cleanup. Rotation may end a segment; a playable file or target frame rate does not prove sustained fresh frames.
- Use [verify-apple-native.swift](../scripts/verify-apple-native.swift) for bounded media/lifecycle checks without UI input; run its `--help` for current options. Use a new private output directory. It does not establish text or gesture success.
- [native-contact-fault-host.swift](../scripts/native-contact-fault-host.swift) is an explicit developer fault harness. Its self-test is separate from hardware fault injection. Review its mode/help before using it on controlled UI; it is not the production client or an automatic recovery route.

The obsolete XCTest attachment recording experiment is not a supported test path. Its design limitation is retained in [recording](runner-recording.md#为什么不使用-xctest-附件录屏).

## Publish results, keep raw evidence local

A public acceptance summary should identify the exact revision/package, environment, scenarios, outcomes and remaining limitations. Do not paste a chronological terminal diary. Convert reusable cases into sanitized fixtures and regression tests. Store build receipts, screenshots, complete AX trees and session logs in `.local/`; report selected facts without personal content, device IDs, signing data or machine paths. Release-specific evidence belongs with the corresponding release or pull request.

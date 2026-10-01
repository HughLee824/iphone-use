# Native text observation revalidation

Status: implemented; host tests and controlled Release device acceptance passed (2026-10-02).

The standard-mode trial rejected three explicit text requests before clipboard or HID execution because their source screenshots were 111–134 seconds old. Returning another screenshot did not solve the cycle when the external agent again took more than 30 seconds to decide.

Native type/press now treat the current observation as a comparison baseline. Device/session binding, current-reference checks, capture source, display geometry/orientation, complete field protection and global comparison remain required. Agent thinking time does not expire that baseline. At request admission, the backend establishes a 30-second dispatch budget; each preflight has at most eight seconds. Clipboard staging is followed by another comparison against the same original baseline. Ownership checks after that capture and input dispatch share the final preflight deadline. Blocking Apple calls retain their own timeouts; these budgets prevent late dispatch, not necessarily late return. Failed validation sends no input; uncertain execution is never replayed.

`text-finish` no longer expires a current post-attempt screenshot after 30 seconds. It still requires this device/session, a finite capture time, the matching latest transaction, post-attempt capture ordering and live clipboard ownership before restoration. Caller confirmation does not prove successful text insertion.

Host validation: 356 tests, one existing optional skip, zero failures; Release build passed. New regressions cover a 120-second-old keyboard baseline, changed field rejection after clipboard preparation, separate bounded final validation, slow ownership checks, and dispatch without preflight. Existing clipboard transaction, reference, cancellation and release tests also ran.

Native type/press now accept one explicit `--ignore-rect` only together with a complete `--field-rect`. The existing ScreenGuard enforces containment, at most 25% of the screen, no overlap with the field and per-observation binding. Only the global comparison excludes the animation; all field pixels remain protected. Node input and Home reject this option.

Native admission now recognizes a green caret under the same source-anchored connected-component, width/height, uniform-background and single-fade constraints as blue/yellow carets (`source-blue-yellow-green-caret-fade-v3`). Multiple candidates, moved carets, changed shapes, text, selection and background remain rejected. A hidden source caret still supplies no anchor. Runner post-input stability explicitly retains its blue-only policy; Runner target-path validation and system-action timing are unchanged.

The ordinary Probe's optional `--dynamic-text-probe` page supplies a changing rectangle, green caret and visible delayed field-mutation button. It does not read the clipboard or expose a text injection endpoint.

## Controlled Release acceptance

The final Release CLI used standard mode and the ordinary `--dynamic-text-probe` page on the freshly discovered connected iPhone. No Runner or third-party device tool ran.

| Check | Observed result |
| --- | --- |
| Delayed Unicode input with continuous animation | Source `o3` was 121.156 seconds old. Both clipboard preflights compared it with fresh frames and passed. One HID paste produced `头🙂尾`; the viewed result showed `EXACT UTF-8 MATCH`, 10/10 UTF-8 bytes, 3/3 scalars and one edit. |
| Animation exclusion | Final preflight raw whole-screen change was 0.0390625; excluded comparison was 0.00050175 and field change was zero. Default thresholds were unchanged. |
| Delayed completion | `text-finish o4` was invoked when the post-input screenshot was 43.585 seconds old. Clipboard restoration and readback were acknowledged. |
| Changed field | The visible Probe button changed the field after eight seconds. A request using the earlier observation at age 35.609 seconds was rejected in `before_clipboard`, `not_dispatched`. Field change was 0.02473958; the attached rejection image showed only `字段已经变化`, no requested `不应输入`, and the edit count remained one. |
| Cleanup | Clipboard restoration, keyboard removal, owned media stop, tunnel release, closed connections and observation cache removal were acknowledged. No stopAll was used. |

The green caret was visible in the source/device output, but the successful input's field comparisons were zero-change: this run did not exercise the fade exception. Green fade acceptance and moved-caret/text/selection rejection are covered by host image regressions. Hidden-source carets and other custom editor behaviors remain limited by the existing source-anchor contract. Native API outcome remains `unknown`; semantic success above comes from the inspected Probe screenshot, not from HID queue acknowledgement.

An initial fixture tap was rejected because its protected touch margin intersected the animation exclusion by a few points. No input was dispatched. The subsequent explicit tap selected a different point inside the same visible sample button, with non-overlapping protection. No protection was removed to proceed.

Private logs/builds: `.local/research/text-revalidation-20261002/`. Final device screenshots, receipts, scoped cleanup and machine-readable acceptance: `.local/research/text-revalidation-aligned-20261002/`. The existing `.5` archive is unchanged; the tested executable is `.build/release/iphone-use`.

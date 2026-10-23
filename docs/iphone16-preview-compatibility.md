# iPhone 16 Pro preview compatibility

On 2026-10-23, source-build acceptance on an iPhone 16 Pro running iOS 27.0.1 identified two independent preview failures:

- CoreDevice reported `activeDimmed` while XCTest was authorized and the unlocked display remained visible. Treating only `activeOn` as lit prevented media startup. Both active states now count as lit; inactive, missing and unknown values remain rejected. Device lock checks are unchanged.
- The display bounds were 1206 × 2622, but DisplayService frame metadata reported a native rectangle of 1206 × 2624 inside a 1216 × 2656 encoded canvas. Exact height matching caused repeated geometry recovery without rendering a frame. Validation now permits only the two-row extension from a height congruent to 2 modulo 4 to the next multiple of 4. Width must still match exactly, and both active and native rectangles must fit the encoded canvas. Cropping uses Apple's actual display bounds, including for reduced-resolution preview frames.

Regression coverage checks dimmed versus inactive displays, accepted and rejected height/width combinations, an undersized encoded canvas, and identical JPEG output with aligned versus exact native metadata in portrait and both landscape orientations. These tests preserve the existing orientation, format and resolution checks.

The source build connected successfully in Runner mode with a 60-minute idle timeout, rendered the home screen in the live browser preview, and returned the same session, timeout and preview URL through `connect --reuse`. A later status check reported streaming media, more than 3,600 encoded preview frames and zero decode errors. No app search, note reading or note writing was performed. Raw device identifiers, URLs, screenshots and logs remain local.

The initial `host_start_failed` left a Runner process without an active host. Its exact PID and executable were checked before cleanup. The original process exit cause was not established and must not be attributed to these preview fixes. Subsequent source-build connections did not reproduce it.

This is source-build evidence, not acceptance of a distributed release archive. Formal publication still requires downloading the cloud-built draft, verifying its exact source and SHA-256, and completing the applicable local device checks described in [the release procedure](release-setup.md).

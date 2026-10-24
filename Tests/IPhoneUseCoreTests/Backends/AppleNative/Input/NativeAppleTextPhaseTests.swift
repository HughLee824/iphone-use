@testable import IPhoneUseRunnerSupport
import XCTest
@testable import IPhoneUseCore

final class NativeAppleTextPhaseTests: XCTestCase {
    private let context = screenTestContext()
    private let field = ScreenRect(CGRect(x: 18, y: 139, width: 354, height: 160))
    private let stroke = CGRect(x: 50, y: 150, width: 2, height: 20)

    private final class CaptureState {
        let lock = NSLock()
        var screenshots = 0
        var lockChecks = 0
        var displayChecks = 0
    }

    private func capture(
        source: Data, frames: [Data], state: CaptureState,
        changed: String? = nil, preferred: String = "coredevice_screenshot",
        deadline: TimeInterval? = nil, confirmCaret: Bool = false, ignored: ScreenRect? = nil
    ) throws -> (ScreenGuard.Check, Int) {
        let cancellation = NativeCancellation()
        let cli = AppleDeviceCLI(
            device: "fixture", cancellation: cancellation,
            reader: { args in
                state.lock.lock(); defer { state.lock.unlock() }
                if args.last == "lockState" {
                    state.lockChecks += 1
                    return ["passcodeRequired": changed == "locked" && state.screenshots > 0]
                }
                if args.last == "displays" {
                    state.displayChecks += 1
                    return [
                        "backlightState": changed == "off" && state.screenshots > 0 ? "off" : "activeOn",
                        "displays": [
                            [
                                "primary": true, "displayId": 1, "bounds": [[0, 0], [390, 844]],
                                "pointScale": 1,
                                "currentOrientation": changed == "rotated" && state.screenshots > 0
                                    ? "rot90" : "rot0",
                                "nativeOrientation": "rot0"
                            ]
                        ]
                    ]
                }
                let png = frames[min(state.screenshots, frames.count - 1)]
                state.screenshots += 1
                try png.write(to: URL(fileURLWithPath: try XCTUnwrap(args.last)))
                if changed == "cancelled" { cancellation.cancel() }
                return [:]
            })
        let guardValue = try ScreenGuard(
            png: source, context: context, rects: [field], policy: .init(), ignoring: ignored)
        let fieldGuard = try NativeTextFieldGuard(png: source, context: context, field: field)
        let caret =
            confirmCaret
            ? try NativeBoundCaretGuard(
                field: fieldGuard, caret: ScreenRect(stroke.insetBy(dx: -1, dy: -1)), observationID: "o1")
            : nil
        let end = deadline ?? ProcessInfo.processInfo.systemUptime + 8
        return try NativeInputPreflight.check(
            guard: guardValue, displayID: 1, captureSource: preferred,
            deadline: end, maximumCaptures: 6, fieldGuard: fieldGuard, caretGuard: caret,
            capture: {
                try cli.capture(
                    generation: "fixture", validateDisplay: { _, _ in ["geometryValidated": true] })
            })
    }

    func testConfirmedCaretUsesOneFrameAndRetainsContextChecks() throws {
        let source = try screenPNG(patches: [(stroke, [7, 193, 96])]), state = CaptureState()
        let result = try capture(source: source, frames: [screenPNG()], state: state, confirmCaret: true)
        XCTAssertTrue(result.0.accepted)
        XCTAssertTrue(result.0.fieldCaretMatch)
        XCTAssertEqual(result.0.caretObservationID, "o1")
        XCTAssertEqual(result.1, 1)
        XCTAssertEqual(state.screenshots, 1)
        XCTAssertEqual(state.lockChecks, 2)
        XCTAssertEqual(state.displayChecks, 2)
    }

    func testConfirmedMaskIsExcludedBeforeGlobalReductionButPageStillProtected() throws {
        let source = try screenPNG(patches: [(stroke, [7, 193, 96])])
        let hidden = try screenPNG()
        let result = try capture(source: source, frames: [hidden], state: CaptureState(), confirmCaret: true)
        XCTAssertEqual(result.0.screenChange, 0)
        XCTAssertEqual(result.0.result["fieldAlgorithm"] as? String, "field-bound-caret-exclusion-v3")
        let pageChange = try screenPNG(patches: [(CGRect(x: 0, y: 400, width: 390, height: 200), [0, 0, 0])])
        XCTAssertThrowsError(
            try capture(source: source, frames: [pageChange], state: CaptureState(), confirmCaret: true)
        ) {
            XCTAssertEqual(($0 as? ActionFailure)?.code, "screen_changed")
        }
        let textChange = try screenPNG(patches: [(CGRect(x: 100, y: 150, width: 2, height: 20), [0, 0, 0])])
        XCTAssertThrowsError(
            try capture(source: source, frames: [textChange], state: CaptureState(), confirmCaret: true)
        ) {
            XCTAssertEqual(($0 as? ActionFailure)?.code, "text_field_changed")
        }
    }

    func testCaretAndSeparateVideoExclusionsComposeWithoutHidingStaticChanges() throws {
        let video = ScreenRect(CGRect(x: 30, y: 400, width: 200, height: 200))
        let source = try screenPNG(patches: [(stroke, [7, 193, 96])])
        let frame = try screenPNG(patches: [(video.cgRect, [0, 0, 0])])
        let result = try capture(
            source: source, frames: [frame], state: CaptureState(), confirmCaret: true, ignored: video)
        XCTAssertTrue(result.0.accepted)
        XCTAssertEqual(result.0.screenChange, 0)
        XCTAssertEqual(result.0.ignoredRect, video)
        let changed = try screenPNG(patches: [
            (video.cgRect, [0, 0, 0]),
            (CGRect(x: 0, y: 650, width: 390, height: 150), [0, 0, 0])
        ])
        XCTAssertThrowsError(
            try capture(
                source: source, frames: [changed], state: CaptureState(), confirmCaret: true, ignored: video)
        ) {
            XCTAssertEqual(($0 as? ActionFailure)?.code, "screen_changed")
        }
    }

    func testMissingCaretConfirmationReturnsOneRejectedImageWithoutRetry() throws {
        let source = try screenPNG(patches: [(stroke, [7, 193, 96])]), state = CaptureState()
        let hidden = try screenPNG()
        XCTAssertThrowsError(try capture(source: source, frames: [hidden, source], state: state)) {
            let failure = $0 as? ActionFailure
            XCTAssertEqual(failure?.code, "caret_confirmation_required")
            XCTAssertEqual(failure?.possiblyExecuted, false)
            XCTAssertEqual(failure?.result?["preInputCaptures"] as? Int, 1)
            XCTAssertEqual(failure?.rejectedCapture?.screenshot, hidden)
        }
        XCTAssertEqual(state.screenshots, 1)
    }

    func testAppleBurstRetainsFinalLockDisplayAndCancellationGuards() throws {
        let png = try screenPNG()
        for changed in ["locked", "off", "rotated", "cancelled"] {
            let state = CaptureState()
            XCTAssertThrowsError(
                try capture(source: png, frames: [png], state: state, changed: changed), changed)
            XCTAssertEqual(state.screenshots, 1)
        }
    }

    func testExpiredBudgetCannotCaptureAndForeignSourceCannotPass() throws {
        let png = try screenPNG(), expired = CaptureState()
        XCTAssertThrowsError(
            try capture(
                source: png, frames: [png], state: expired,
                deadline: ProcessInfo.processInfo.systemUptime - 1))
        XCTAssertEqual(expired.screenshots, 0)
        let fallback = CaptureState()
        XCTAssertThrowsError(
            try capture(source: png, frames: [png], state: fallback, preferred: "native_media")
        ) {
            XCTAssertEqual(($0 as? ActionFailure)?.result?["captureSourceChanged"] as? Bool, true)
        }
        XCTAssertEqual(fallback.screenshots, 1)
    }
}

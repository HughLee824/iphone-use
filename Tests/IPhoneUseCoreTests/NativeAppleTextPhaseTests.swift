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

    private func capture(source: Data, frames: [Data], state: CaptureState,
                         changed: String? = nil, preferred: String = "coredevice_screenshot",
                         deadline: TimeInterval? = nil) throws -> (ScreenGuard.Check, Int) {
        let cancellation = NativeCancellation()
        let cli = AppleDeviceCLI(device: "fixture", cancellation: cancellation, reader: { args in
            state.lock.lock(); defer { state.lock.unlock() }
            if args.last == "lockState" {
                state.lockChecks += 1
                return ["passcodeRequired": changed == "locked" && state.screenshots > 0]
            }
            if args.last == "displays" {
                state.displayChecks += 1
                return ["backlightState": changed == "off" && state.screenshots > 0 ? "off" : "activeOn",
                    "displays": [["primary": true, "displayId": 1, "bounds": [[0, 0], [390, 844]], "pointScale": 1,
                        "currentOrientation": changed == "rotated" && state.screenshots > 0 ? "rot90" : "rot0",
                        "nativeOrientation": "rot0"]]]
            }
            let png = frames[min(state.screenshots, frames.count - 1)]
            state.screenshots += 1
            try png.write(to: URL(fileURLWithPath: try XCTUnwrap(args.last)))
            if changed == "cancelled" { cancellation.cancel() }
            return [:]
        })
        let guardValue = try ScreenGuard(png: source, context: context, rects: [field], policy: .init())
        let matcher = try NativeTextPhaseMatcher(field: NativeTextFieldGuard(png: source, context: context, field: field))
        let end = deadline ?? ProcessInfo.processInfo.systemUptime + 8
        return try NativeInputPreflight.check(guard: guardValue, displayID: 1, captureSource: preferred,
            deadline: end, maximumCaptures: 1, phaseMatcher: matcher) {
                try cli.capture(generation: "fixture", preferredSource: preferred,
                    textPhase: (guardValue: guardValue, field: matcher, deadline: end),
                    mediaCapture: { _, _ in (nil, ["geometryValidated": true]) })
            }
    }

    func testAppleBurstCanReachReturningPhaseWithoutRepeatingContextChecks() throws {
        let source = try screenPNG(patches: [(stroke, [128,128,128])])
        let hidden = try screenPNG(), visible = try screenPNG(patches: [(stroke, [0,0,0])])
        let state = CaptureState()
        // The failed device run had three nonmatching phases before its budget
        // expired. Those are not sufficient evidence to ignore a narrow stroke.
        let result = try capture(source: source, frames: [hidden, hidden, hidden, visible, hidden], state: state)
        XCTAssertTrue(result.0.accepted)
        XCTAssertTrue(result.0.fieldTemporalMatch)
        XCTAssertEqual(result.1, 5)
        XCTAssertEqual(state.screenshots, 5)
        XCTAssertEqual(state.lockChecks, 2)
        XCTAssertEqual(state.displayChecks, 2)
        XCTAssertEqual(result.0.policy.maxRegionChange, 0)
    }

    func testAppleBurstStillRejectsStaticStrokeChangesWithoutBlinkEvidence() throws {
        let source = try screenPNG(patches: [(stroke, [0,0,0])])
        let changed = try screenPNG() // Could be removal of text, not a blink.
        let state = CaptureState()
        XCTAssertThrowsError(try capture(source: source, frames: [changed], state: state)) {
            let failure = $0 as? ActionFailure
            XCTAssertEqual(failure?.possiblyExecuted, false)
            XCTAssertEqual(failure?.result?["preInputCaptures"] as? Int, 6)
            XCTAssertEqual(failure?.rejectedCapture?.screenshot, changed)
            let samples = failure?.rejectedCapture?.metadata["appleTextPhaseSamples"] as? [[String: Any]]
            XCTAssertEqual(samples?.count, 6)
        }
        XCTAssertEqual(state.screenshots, 6)
        XCTAssertEqual(state.lockChecks, 2)
        XCTAssertEqual(state.displayChecks, 2)
    }

    func testAppleBurstDoesNotIgnoreTextChangesAlongsideBlink() throws {
        let source = try screenPNG(patches: [(stroke, [128,128,128])])
        let newText = (CGRect(x: 90, y: 150, width: 1, height: 20), [UInt8](repeating: 0, count: 3))
        let hidden = try screenPNG(patches: [newText])
        let visible = try screenPNG(patches: [newText, (stroke, [0,0,0])])
        let state = CaptureState()
        XCTAssertThrowsError(try capture(source: source, frames: [hidden, visible, hidden, visible, hidden, visible], state: state)) {
            XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, false)
        }
    }

    func testAppleBurstRetainsFinalLockDisplayAndCancellationGuards() throws {
        let png = try screenPNG()
        for changed in ["locked", "off", "rotated", "cancelled"] {
            let state = CaptureState()
            XCTAssertThrowsError(try capture(source: png, frames: [png], state: state, changed: changed), changed)
            XCTAssertEqual(state.screenshots, 1)
        }
    }

    func testExpiredBudgetCannotCaptureOrAcceptAndMediaFallbackCannotStartAppleBurst() throws {
        let png = try screenPNG(), expired = CaptureState()
        XCTAssertThrowsError(try capture(source: png, frames: [png], state: expired,
            deadline: ProcessInfo.processInfo.systemUptime - 1))
        XCTAssertEqual(expired.screenshots, 0)
        let fallback = CaptureState()
        XCTAssertThrowsError(try capture(source: png, frames: [png], state: fallback, preferred: "native_media")) {
            XCTAssertEqual(($0 as? ActionFailure)?.result?["captureSourceChanged"] as? Bool, true)
        }
        XCTAssertEqual(fallback.screenshots, 1)
    }
}

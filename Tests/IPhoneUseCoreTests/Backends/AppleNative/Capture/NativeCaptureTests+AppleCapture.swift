import XCTest
import CoreVideo
import ImageIO
@testable import IPhoneUseCore

extension NativeCaptureTests {

    func testAppleStartsValidationOnlyAfterGeometryAndStopsExpiredReads() throws {
        let now = ProcessInfo.processInfo.systemUptime
        let budget = NativeCaptureBudget(requestDeadline: now + 30)
        let png = try screenPNG(width: 12, height: 18)
        var screenshots = 0
        let cli = AppleDeviceCLI(
            device: "fixture", cancellation: NativeCancellation(),
            reader: { arguments in
                if arguments.last == "lockState" { return ["passcodeRequired": false] }
                if arguments.last == "displays" { return self.display() }
                XCTAssertNotNil(budget.validationStartedAt)
                screenshots += 1
                try png.write(to: URL(fileURLWithPath: try XCTUnwrap(arguments.last)))
                return [:]
            })
        _ = try cli.capture(
            generation: "fixture", budget: budget,
            prepareDisplay: { _ in
                XCTAssertNil(budget.validationStartedAt)
            },
            validateDisplay: { _, _ in
                XCTAssertNil(budget.validationStartedAt)
                return [:]
            })
        XCTAssertEqual(screenshots, 1)
        let expired = NativeCaptureBudget(requestDeadline: now - 1)
        XCTAssertThrowsError(try cli.capture(generation: "fixture", budget: expired)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "input_preflight_timeout")
        }
        XCTAssertEqual(screenshots, 1)
    }
    func testIndependentChecksOverlapButJoinBeforeReturning() throws {
        let lockEntered = DispatchSemaphore(value: 0), displayEntered = DispatchSemaphore(value: 0)
        let result = try NativeCaptureChecks.read { arguments in
            if arguments.last == "lockState" {
                lockEntered.signal()
                XCTAssertEqual(displayEntered.wait(timeout: .now() + 1), .success)
                return ["passcodeRequired": false]
            }
            displayEntered.signal()
            XCTAssertEqual(lockEntered.wait(timeout: .now() + 1), .success)
            return self.display()
        }
        XCTAssertEqual(result.display.pixelWidth, 12)
        XCTAssertEqual(Set(result.timings.keys), ["lock", "display"])
    }
    func testMissingLockedOrInactiveChecksCannotYieldObservation() throws {
        for state: [String: Any] in [[:], ["passcodeRequired": true]] {
            XCTAssertThrowsError(
                try NativeCaptureChecks.read { $0.last == "lockState" ? state : self.display() })
        }
        XCTAssertThrowsError(
            try NativeCaptureChecks.read {
                $0.last == "lockState" ? ["passcodeRequired": false] : self.display(backlight: "off")
            })
        XCTAssertThrowsError(
            try NativeCaptureChecks.read { arguments in
                if arguments.last == "displays" { throw IPhoneUseError("test", "display read failed") }
                return ["passcodeRequired": false]
            })
    }
    func testPreviewChecksIgnoreBacklightButRetainLockAndGeometryRequirements() throws {
        for state: String? in ["activeOn", "activeDimmed", "off", "inactive", "futureState", nil] {
            var facts = display()
            facts["backlightState"] = state
            let reply = facts
            let result = try NativeCaptureChecks.read(requireBacklight: false) {
                $0.last == "lockState" ? ["passcodeRequired": false] : reply
            }
            XCTAssertEqual(result.display.geometry, try NativeDisplay(display()).geometry)
            if !["activeOn", "activeDimmed"].contains(state) {
                XCTAssertThrowsError(
                    try NativeCaptureChecks.read {
                        $0.last == "lockState" ? ["passcodeRequired": false] : reply
                    }, "Screenshot/input checks must still reject \(state ?? "missing")")
            }
        }
        for lock: [String: Any] in [[:], ["passcodeRequired": true]] {
            XCTAssertThrowsError(
                try NativeCaptureChecks.read(requireBacklight: false) {
                    $0.last == "lockState" ? lock : self.display(backlight: "futureState")
                }
            ) { XCTAssertEqual(($0 as? IPhoneUseError)?.code, "device_locked") }
        }
        XCTAssertThrowsError(
            try NativeCaptureChecks.read(requireBacklight: false) {
                $0.last == "lockState" ? ["passcodeRequired": false] : ["displays": []]
            }
        ) { XCTAssertEqual(($0 as? IPhoneUseError)?.code, "native_display_unavailable") }
        XCTAssertThrowsError(
            try NativeCaptureChecks.read(requireBacklight: false) { args in
                if args.last == "lockState" { throw IPhoneUseError("coredevice_timeout", "Fixture timeout") }
                return self.display(backlight: "off")
            }
        ) { XCTAssertEqual(($0 as? IPhoneUseError)?.code, "coredevice_timeout") }
    }

    func testConfirmedLockOrBacklightOffTakesPrecedenceOverSiblingTimeout() {
        for locked in [true, false] {
            XCTAssertThrowsError(
                try NativeCaptureChecks.read { arguments in
                    if locked, arguments.last == "lockState" { return ["passcodeRequired": true] }
                    if !locked, arguments.last == "displays" { return self.display(backlight: "off") }
                    throw IPhoneUseError("coredevice_timeout", "Fixture timeout")
                }
            ) {
                XCTAssertEqual(
                    ($0 as? IPhoneUseError)?.code, locked ? "device_locked" : "capture_unavailable")
            }
        }
        XCTAssertThrowsError(
            try NativeCaptureChecks.read { arguments in
                if arguments.last == "lockState" {
                    throw IPhoneUseError("coredevice_timeout", "Fixture timeout")
                }
                return self.display()
            }
        ) {
            XCTAssertEqual(
                ($0 as? IPhoneUseError)?.code, "coredevice_timeout", "Capture itself must remain strict")
        }
    }
    func testAppleRetainsPostCaptureLockGeometryAndCancellationGuards() throws {
        let png = try screenPNG(width: 12, height: 18)
        for changed in ["locked", "rotated", "off", "cancelled", "none"] {
            let state = State(), cancellation = NativeCancellation()
            let cli = AppleDeviceCLI(
                device: "fixture", cancellation: cancellation,
                reader: { arguments in
                    state.lock.lock(); defer { state.lock.unlock() }
                    if arguments.last == "lockState" {
                        return ["passcodeRequired": state.finalPhase && changed == "locked"]
                    }
                    if arguments.last == "displays" {
                        return self.display(
                            state.finalPhase && changed == "rotated" ? "rot90" : "rot0",
                            backlight: state.finalPhase && changed == "off" ? "off" : "activeOn")
                    }
                    state.screenshots += 1
                    try png.write(to: URL(fileURLWithPath: try XCTUnwrap(arguments.last)))
                    state.finalPhase = true
                    if changed == "cancelled" { cancellation.cancel() }
                    return [:]
                })
            let capture = {
                try cli.capture(
                    generation: "fixture",
                    validateDisplay: { _, _ in
                        return [:]
                    })
            }
            if changed == "none" {
                let result = try capture()
                XCTAssertEqual(result.metadata["captureSource"] as? String, "coredevice_screenshot")
                XCTAssertEqual(result.screenshot, png)
            } else {
                XCTAssertThrowsError(try capture(), changed)
            }
            XCTAssertEqual(state.screenshots, 1)
        }
    }

    func testAppleOnlyIgnoresMediaPixelsAndRetainsGeometryGuard() throws {
        let png = try screenPNG(width: 12, height: 18), state = State()
        let cli = AppleDeviceCLI(
            device: "fixture", cancellation: NativeCancellation(),
            reader: { arguments in
                if arguments.last == "lockState" { return ["passcodeRequired": false] }
                if arguments.last == "displays" { return self.display() }
                state.screenshots += 1
                try png.write(to: URL(fileURLWithPath: try XCTUnwrap(arguments.last)))
                return [:]
            })
        var geometryChecks = 0
        for verification in ["owned_media_geometry", "observation_only"] {
            let capture = try cli.capture(
                generation: "fixture",
                validateDisplay: { _, _ in
                    geometryChecks += 1
                    return ["verification": verification]
                })
            XCTAssertEqual(capture.screenshot, png)
            XCTAssertEqual(capture.metadata["captureSource"] as? String, "coredevice_screenshot")
            XCTAssertEqual(
                (capture.metadata["captureSourcePolicy"] as? [String: Any])?["strategy"] as? String,
                "coredevice_only")
            XCTAssertNil(capture.metadata["mediaSnapshot"])
        }
        XCTAssertEqual(geometryChecks, 2)
        for code in ["native_snapshot_geometry_unavailable", "native_snapshot_freshness_unavailable"] {
            XCTAssertThrowsError(
                try cli.capture(
                    generation: "fixture",
                    validateDisplay: { _, _ in
                        throw IPhoneUseError(code, "Unverified orientation")
                    }))
        }
        XCTAssertEqual(state.screenshots, 2, "Geometry must be verified before PNG acquisition")
    }
}

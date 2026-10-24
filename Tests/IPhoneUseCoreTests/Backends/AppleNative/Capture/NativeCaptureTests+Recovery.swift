@testable import IPhoneUseRunnerSupport
import XCTest
import CoreVideo
import ImageIO
@testable import IPhoneUseCore

extension NativeCaptureTests {

    func testFreshnessRecoveryAttachesNewObservationAndRejectsOldInput() throws {
        let context = screenTestContext(), png = try screenPNG()
        let guardValue = try ScreenGuard(png: png, context: context, rects: [context.screen], policy: .init())
        let original = CapturedObservation(
            nodes: [],
            metadata: [
                "displayID": UInt64(1),
                "screenContext": try jsonObject(JSONEncoder().encode(context))
            ], screenshot: png)
        var captures = 0, refreshes = 0
        XCTAssertThrowsError(
            try NativeInputPreflight.check(
                guard: guardValue, displayID: 1,
                deadline: 8, maximumCaptures: 3, now: { 0 },
                capture: {
                    try NativeCaptureChecks.withOrientationRecovery(
                        capture: { refreshed in
                            captures += 1
                            if !refreshed {
                                throw IPhoneUseError("native_snapshot_freshness_unavailable", "quiet stream")
                            }
                            return original // Even identical pixels and direction need a new decision.
                        },
                        resynchronize: {
                            refreshes += 1; return true
                        })
                })
        ) {
            let failure = $0 as? ActionFailure
            XCTAssertEqual(failure?.possiblyExecuted, false)
            XCTAssertEqual(failure?.rejectedCapture?.screenshot, png)
            XCTAssertEqual(
                failure?.rejectedCapture?.metadata["orientationResynchronizationReason"] as? String,
                "native_snapshot_freshness_unavailable")
        }
        XCTAssertEqual(captures, 2)
        XCTAssertEqual(refreshes, 1)
    }

    func testOrientationRecoveryIsBoundedAndDoesNotRetryUnrelatedErrors() throws {
        for code in ["device_locked", "native_cancelled", "capture_context_changed", "invalid_image"] {
            var captures = 0
            XCTAssertThrowsError(
                try NativeCaptureChecks.withOrientationRecovery(
                    capture: { _ in
                        captures += 1; throw IPhoneUseError(code, "fixture")
                    },
                    resynchronize: {
                        XCTFail("Do not replace media for unrelated errors"); return false
                    })
            ) {
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, code)
            }
            XCTAssertEqual(captures, 1)
        }
        for code in ["native_snapshot_geometry_unavailable", "native_snapshot_freshness_unavailable"] {
            var captures = 0, refreshes = 0
            XCTAssertThrowsError(
                try NativeCaptureChecks.withOrientationRecovery(
                    capture: { _ in
                        captures += 1; throw IPhoneUseError(code, "fixture")
                    },
                    resynchronize: {
                        refreshes += 1
                        throw IPhoneUseError("native_cancelled", "cancelled after owned stop")
                    })
            ) {
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, "native_cancelled")
            }
            XCTAssertEqual(captures, 1)
            XCTAssertEqual(refreshes, 1)
        }
        let frame = CapturedObservation(nodes: [], metadata: [:], screenshot: try screenPNG())
        let result = try NativeCaptureChecks.withOrientationRecovery(
            capture: { refreshed in
                XCTAssertFalse(refreshed); return frame
            },
            resynchronize: {
                XCTFail("Fresh capture must not restart media"); return false
            })
        XCTAssertNil(result.metadata["orientationResynchronized"])
    }

    func testQuietStreamRevalidationStillChecksOriginalSourceGeometryPixelsAndDeadline() throws {
        let context = screenTestContext(), png = try screenPNG()
        let guardValue = try ScreenGuard(png: png, context: context, rects: [context.screen], policy: .init())
        for changed in ["none", "source", "rotation", "pixels", "deadline", "conflict"] {
            var clock = 0.0, captures = 0, refreshes = 0
            let check = {
                try NativeInputPreflight.check(
                    guard: guardValue, displayID: 1, displayRotation: "rot0",
                    captureSource: "coredevice_screenshot", deadline: 8, maximumCaptures: 1, now: { clock },
                    capture: {
                        try NativeCaptureChecks.withOrientationRecovery(
                            capture: { refreshed in
                                captures += 1
                                if !refreshed {
                                    throw IPhoneUseError(
                                        changed == "conflict"
                                            ? "native_snapshot_geometry_unavailable"
                                            : "native_snapshot_freshness_unavailable", "fixture")
                                }
                                if changed == "deadline" { clock = 9 }
                                return try self.revalidationCapture(changed: changed, context: context, png: png)
                            },
                            resynchronize: {
                                refreshes += 1; return false
                            })
                    })
            }
            if changed == "none" {
                XCTAssertTrue(try check().0.accepted)
            } else {
                XCTAssertThrowsError(try check(), changed) {
                    let failure = $0 as? ActionFailure
                    XCTAssertEqual(failure?.possiblyExecuted, false)
                    XCTAssertNotNil(failure?.rejectedCapture)
                    XCTAssertEqual(
                        failure?.rejectedCapture?.metadata["orientationResynchronized"] as? Bool,
                        changed == "conflict" ? true : nil)
                }
            }
            XCTAssertEqual(captures, 2)
            XCTAssertEqual(refreshes, 1)
        }
    }

    func testRecoveryClassificationDoesNotTreatQuietPeerAsFreshGeometry() {
        func state(_ age: Double, pending: Int = 0, frameAge: Double = 10) -> [String: Any] {
            [
                "healthy": true, "lastRTPAgeSeconds": age,
                "snapshots": [
                    "pendingBytes": pending, "waitingForKeyframe": false, "lastFrameAgeSeconds": frameAge
                ]
            ]
        }
        XCTAssertEqual(
            NativeCaptureChecks.recoveryTrigger(
                error: "native_snapshot_freshness_unavailable", state: state(36)),
            "stream_quiescent")
        XCTAssertEqual(
            NativeCaptureChecks.recoveryTrigger(
                error: "native_snapshot_freshness_unavailable",
                state: state(0.006, pending: 159235, frameAge: 1.68)),
            "frame_delivery_delayed")
        XCTAssertEqual(
            NativeCaptureChecks.recoveryTrigger(
                error: "native_snapshot_geometry_unavailable", state: state(36)),
            "geometry_conflict")
        XCTAssertEqual(
            NativeCaptureChecks.recoveryTrigger(
                error: "native_snapshot_freshness_unavailable", state: ["healthy": false]),
            "connection_unavailable")
        XCTAssertEqual(
            NativeCaptureChecks.recoveryTrigger(error: "native_snapshot_freshness_unavailable", state: [:]),
            "fresh_frame_unavailable")
    }

    func testRecoveryTimeoutDoesNotBecomeOrientationFailureOrRetryCapture() throws {
        for code in ["input_preflight_timeout", "native_cancelled", "coredevice_cancelled"] {
            var captures = 0, refreshes = 0
            XCTAssertThrowsError(
                try NativeCaptureChecks.withOrientationRecovery(
                    capture: { _ in
                        captures += 1
                        throw IPhoneUseError("native_snapshot_freshness_unavailable", "quiet stream")
                    },
                    resynchronize: {
                        refreshes += 1; throw IPhoneUseError(code, "stop")
                    })
            ) { XCTAssertEqual(($0 as? IPhoneUseError)?.code, code) }
            XCTAssertEqual(captures, 1)
            XCTAssertEqual(refreshes, 1)
        }
    }
    private func revalidationCapture(changed: String, context: ScreenContext, png: Data) throws
        -> CapturedObservation {
        return CapturedObservation(
            nodes: [],
            metadata: [
                "displayID": UInt64(1),
                "captureSource": changed == "source" ? "native_media" : "coredevice_screenshot",
                "displayRotation": changed == "rotation" ? "rot270" : "rot0",
                "nativeRotation": "rot0",
                "screenContext": try jsonObject(JSONEncoder().encode(context))
            ],
            screenshot: changed == "pixels"
                ? try screenPNG(patches: [
                    (CGRect(x: 0, y: 0, width: 100, height: 100), [0, 0, 0])
                ])
                : png)
    }

}

import XCTest
@testable import IPhoneUseCore

final class RunnerSetupVerificationTests: XCTestCase {
    private let products = URL(fileURLWithPath: "/fixture/packaged-runner")

    func testPreviewAndAuthorizationProgressArriveBeforeObservationAndCleanup() throws {
        var events: [[String: Any]] = []
        var operations: [String] = []
        let url = "http://127.0.0.1:9876/v/fixture/"
        let verification = RunnerSetupVerification(connect: { device, manifest, port, report in
            XCTAssertEqual(device, "device-A")
            XCTAssertEqual(manifest.path, "/fixture/packaged-runner/Runner.xctestrun")
            XCTAssertEqual(port, 9876)
            report?(["event": "connection_progress", "previewURL": url, "phase": "starting"])
            report?(["event": "connection_progress", "previewURL": url, "requiresUserAction": true,
                     "evidence": "device_log_exact_runner_pid"])
            XCTAssertEqual(events.last?["requiresUserAction"] as? Bool, true,
                           "Forward authorization immediately, before connect returns ready")
            XCTAssertTrue(operations.isEmpty)
            return ["session": "session-A"]
        }, call: { session, operation in
            XCTAssertEqual(session, "session-A")
            operations.append(operation)
            return ["ok": true, "result": ["cleanup": ["receiverClosed": true]]]
        })
        let result = try verification.run(device: "device-A", products: products, previewPort: 9876,
                                          progress: .init(onProgress: { events.append($0) }))
        XCTAssertEqual(operations, ["observe", "disconnect"])
        XCTAssertEqual(result["verificationSession"] as? String, "session-A")
        let preview = try XCTUnwrap(result["preview"] as? [String: Any])
        XCTAssertEqual(preview["url"] as? String, url)
        XCTAssertEqual(preview["state"] as? String, "stopped")
        XCTAssertEqual(events.compactMap { $0["phase"] as? String },
                       ["verifying", "starting", "observing", "disconnecting"])
    }

    func testDisabledPreviewAndSilentProgressStillVerifyAndClose() throws {
        var operations: [String] = []
        let verification = RunnerSetupVerification(connect: { _, _, port, _ in
            XCTAssertNil(port)
            return ["session": "session-A"]
        }, call: { _, operation in operations.append(operation); return ["ok": true] })
        let result = try verification.run(device: "device-A", products: products, previewPort: nil,
                                          progress: .init(onProgress: nil))
        XCTAssertEqual(operations, ["observe", "disconnect"])
        XCTAssertEqual((result["preview"] as? [String: Any])?["state"] as? String, "disabled")
    }

    func testFastConnectionPreservesURLWhenNoProgressPollObservedIt() throws {
        let url = "http://127.0.0.1:9876/v/fixture/"
        let verification = RunnerSetupVerification(connect: { _, _, _, _ in
            ["session": "session-A", "result": ["preview": ["url": url, "state": "streaming"]]]
        }, call: { _, _ in ["ok": true] })
        let result = try verification.run(device: "device-A", products: products, previewPort: 9876,
                                          progress: .init(onProgress: nil))
        XCTAssertEqual((result["preview"] as? [String: Any])?["url"] as? String, url)
    }

    func testPreviewFailureIsReportedWithoutRetryingConnection() throws {
        var starts = 0
        var events: [[String: Any]] = []
        let verification = RunnerSetupVerification(connect: { _, _, _, report in
            starts += 1
            report?(["event": "connection_progress", "previewError": "Fixture port is occupied"])
            return ["session": "session-A"]
        }, call: { _, _ in ["ok": true] })
        let result = try verification.run(device: "device-A", products: products, previewPort: 9876,
                                          progress: .init(onProgress: { events.append($0) }))
        XCTAssertEqual(starts, 1)
        XCTAssertEqual((result["preview"] as? [String: Any])?["error"] as? String, "Fixture port is occupied")
        XCTAssertEqual(events[1]["previewError"] as? String, "Fixture port is occupied")
    }

    func testObservationFailureAlwaysDisconnectsOnce() throws {
        for throwsError in [false, true] {
            var operations: [String] = []
            let verification = RunnerSetupVerification(connect: { _, _, _, _ in ["session": "session-A"] },
                call: { _, operation in
                    operations.append(operation)
                    if operation == "observe" {
                        if throwsError { throw IPhoneUseError("fixture_capture_failed", "Fixture") }
                        return ["ok": false, "error": "Fixture capture failed"]
                    }
                    return ["ok": true]
                })
            XCTAssertThrowsError(try verification.run(device: "device-A", products: products, previewPort: 9876,
                                                     progress: .init(onProgress: nil)))
            XCTAssertEqual(operations, ["observe", "disconnect"])
        }
    }

    func testUncertainCleanupIsNotRetriedOrMarkedSuccessful() throws {
        for throwsError in [false, true] {
            var operations: [String] = []
            let verification = RunnerSetupVerification(connect: { _, _, _, _ in ["session": "session-A"] },
                call: { _, operation in
                    operations.append(operation)
                    if operation == "disconnect", throwsError { throw IPhoneUseError("fixture_timeout", "Fixture") }
                    return ["ok": false, "error": "Fixture failure"]
                })
            XCTAssertThrowsError(try verification.run(device: "device-A", products: products, previewPort: 9876,
                                                     progress: .init(onProgress: nil))) {
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, "setup_cleanup_failed")
                XCTAssertTrue(String(describing: $0).contains("Observation also failed"))
            }
            XCTAssertEqual(operations, ["observe", "disconnect"])
        }
    }

    func testStartupFailureIsNotRetriedAndDoesNotInventSessionCleanup() {
        var starts = 0
        let verification = RunnerSetupVerification(connect: { _, _, _, _ in
            starts += 1
            throw IPhoneUseError("runner_authorization_incomplete", "Fixture authorization timeout")
        }, call: { _, _ in XCTFail("No returned session to operate"); return [:] })
        XCTAssertThrowsError(try verification.run(device: "device-A", products: products, previewPort: 9876,
                                                 progress: .init(onProgress: nil))) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "runner_authorization_incomplete")
        }
        XCTAssertEqual(starts, 1)
    }
}

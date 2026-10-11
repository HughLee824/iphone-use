import XCTest
@testable import IPhoneUseCore

final class NativeControlStatusTests: XCTestCase {
    func testInactiveMediaDoesNotBlockReadyHIDOrHideUncertainInput() {
        func status(_ hid: NativeHIDAdapter.State) -> NativeControlStatus {
            NativeControlStatus.resolve(hid: hid, media: ["state": "inactive", "healthy": false], closing: false,
                                        startupCode: nil, startupError: nil, requiresMedia: false)
        }
        XCTAssertTrue(status(.ready).available)
        XCTAssertEqual(status(.releaseUncertain).code, "native_release_uncertain")
        XCTAssertEqual(status(.inputUncertain).code, "native_input_uncertain")
        XCTAssertEqual(status(.cancelled).code, "native_session_closing")
        XCTAssertEqual(status(.unprepared).code, "native_hid_unavailable")
    }
    private func control(_ hid: NativeHIDAdapter.State? = .ready, healthy: Bool = true,
                         closing: Bool = false, startup: String? = nil) -> NativeControlStatus {
        NativeControlStatus.resolve(hid: hid, media: ["healthy": healthy], closing: closing,
                                    startupCode: startup == nil ? nil : "native_protocol_unsupported", startupError: startup)
    }
    private func recovery(_ response: [String: Any]) -> [String: Any]? {
        (response["result"] as? [String: Any])?["recovery"] as? [String: Any]
    }
    func testControlPrioritizesIrreversibleFactsOverMediaAndClosing() {
        XCTAssertEqual(control(.releaseUncertain, healthy: false, closing: true).code, "native_release_uncertain")
        XCTAssertEqual(control(.inputUncertain, healthy: false, closing: true).code, "native_input_uncertain")
        XCTAssertEqual(control(.cancelled).code, "native_session_closing")
        XCTAssertEqual(control(closing: true).recovery, .reconnectAndObserve)
        for state in [NativeHIDAdapter.State.releaseUncertain, .inputUncertain, .cancelled] {
            XCTAssertFalse(control(state).available)
            XCTAssertEqual(control(state).recovery.result["requiresReconnect"] as? Bool, true)
        }
    }
    func testStartupCauseIsPreservedAndMediaRecoveryIsNotLatched() {
        let startup = control(nil, healthy: false, startup: "Unsupported installed interface")
        XCTAssertEqual(startup.code, "native_protocol_unsupported")
        XCTAssertEqual(startup.message, "Unsupported installed interface")
        XCTAssertEqual(startup.recovery, .resolveError)
        XCTAssertEqual(control(nil).code, "native_hid_unavailable")
        XCTAssertEqual(control(.contactActive).recovery, .checkSession)
        XCTAssertEqual(control(healthy: false).code, "native_media_unhealthy")
        XCTAssertEqual(control(healthy: false).recovery, .checkMediaAndObserve)
        XCTAssertFalse(control(healthy: false).recovery.result["requiresReconnect"] as! Bool)
        XCTAssertTrue(control().available)
        XCTAssertTrue(control().result["controlErrorCode"] is NSNull)
    }
    func testUncertainActionRetainsCleanupAndRequiresReconnectEvenWithAfterImage() {
        var response: [String: Any] = ["outcome": "unknown", "ok": false,
            "error": ["code": "native_input_uncertain"], "observation": ["ok": true],
            "result": ["cleanup": ["releaseUncertain": true], "sourceObservationID": "o1", "afterObservationID": "o2"]]
        NativeRecovery.enrich(&response, control: control(.releaseUncertain).result)
        let facts = response["result"] as! [String: Any]
        XCTAssertEqual(facts["controlErrorCode"] as? String, "native_release_uncertain")
        XCTAssertEqual((facts["cleanup"] as? [String: Bool])?["releaseUncertain"], true)
        XCTAssertEqual(facts["sourceObservationID"] as? String, "o1")
        XCTAssertEqual(facts["afterObservationID"] as? String, "o2")
        XCTAssertEqual(response["outcome"] as? String, "unknown")
        XCTAssertEqual(recovery(response)?["nextAction"] as? String, "reconnect_and_observe")
        XCTAssertEqual(recovery(response)?["automaticReplayAllowed"] as? Bool, false)
    }
    func testSentInputUsesExistingAfterImageOrRequestsObservationWithoutReconnect() {
        for captured in [false, true] {
            var response: [String: Any] = ["outcome": "unknown", "ok": false,
                "error": ["code": "native_input_unacknowledged"], "observation": ["ok": captured],
                "result": ["transportStatus": "sent"]]
            NativeRecovery.enrich(&response, control: control().result)
            XCTAssertEqual(recovery(response)?["nextAction"] as? String, captured ? "inspect_observation" : "observe")
            XCTAssertEqual(recovery(response)?["requiresReconnect"] as? Bool, false)
            XCTAssertEqual(response["outcome"] as? String, "unknown")
        }
    }
    func testStaleObservationOnlyRequestsCaptureAndClosedHostCannotClaimCleanup() {
        for (code, expected) in [("stale_reference", "observe"), ("stale_observation", "observe"),
                                 ("device_locked", "observe"), ("session_closed", "reconnect_and_observe"),
                                 ("session_unavailable", "check_session")] {
            var response: [String: Any] = ["ok": false, "outcome": "not_dispatched", "error": ["code": code]]
            NativeRecovery.enrich(&response, control: nil)
            XCTAssertEqual(recovery(response)?["nextAction"] as? String, expected)
            XCTAssertEqual(recovery(response)?["automaticReplayAllowed"] as? Bool, false)
            XCTAssertNil((response["result"] as? [String: Any])?["cleanup"])
        }
    }
    func testRejectionSnapshotCannotBeErasedByRecoveredMediaSample() {
        let rejected = NativeControlStatus.resolve(hid: .ready,
            media: ["healthy": false, "healthReason": "rtp_stale", "lastRTPAgeSeconds": 7.5, "rtcpReports": 10],
            closing: false, startupCode: nil, startupError: nil)
        var response: [String: Any] = ["ok": false, "outcome": "not_dispatched",
            "error": ["code": "native_control_unavailable"], "result": rejected.result]
        NativeRecovery.enrich(&response, control: control().result)
        XCTAssertEqual((response["result"] as? [String: Any])?["controlErrorCode"] as? String, "native_media_unhealthy")
        XCTAssertEqual(recovery(response)?["nextAction"] as? String, "check_media_and_observe")
        XCTAssertEqual((response["error"] as? [String: String])?["code"], "native_control_unavailable")
        let media = (response["result"] as? [String: Any])?["media"] as? [String: Any]
        XCTAssertEqual(media?["healthReason"] as? String, "rtp_stale")
        XCTAssertEqual(media?["lastRTPAgeSeconds"] as? Double, 7.5)
        XCTAssertEqual(media?["rtcpReports"] as? Int, 10)
    }
    func testClientUnavailableAddsNativeRecoveryOnlyWithoutAssumingHostExited() throws {
        for native in [false, true] {
            let session = "s" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let paths = try SessionPaths(session: session)
            try SessionPaths.secureDirectory(paths.directory)
            defer { try? FileManager.default.removeItem(at: paths.directory) }
            let config = HostConfiguration(session: session, device: "host-fixture", xctestrun: "",
                                           idleTimeoutSeconds: 30, backend: native ? "apple-native" : nil)
            try JSONEncoder().encode(config).write(to: paths.config)
            let response = try SessionClient.call(session: session, operation: "tap", fields: ["reference": "o1", "x": 1, "y": 1], timeout: 0.1)
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String, "session_unavailable")
            if native {
                XCTAssertEqual(recovery(response)?["nextAction"] as? String, "check_session")
                XCTAssertEqual(recovery(response)?["automaticReplayAllowed"] as? Bool, false)
                XCTAssertNil((response["result"] as? [String: Any])?["controlAvailable"])
                XCTAssertNil((response["result"] as? [String: Any])?["cleanup"])
            } else { XCTAssertNil(response["result"]) }
        }
    }
}

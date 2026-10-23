import XCTest
@testable import IPhoneUseCore

final class SessionDiscoveryTests: XCTestCase {
    private let session = "s" + String(repeating: "1", count: 32)

    private func candidate(mode: ControlMode = .runner) -> SessionDiscovery.Candidate {
        .init(
            config: HostConfiguration(
                session: session, device: "fixture-phone", xctestrun: "/signed/Runner.xctestrun",
                idleTimeoutSeconds: 1800, backend: mode.backend),
            paths: SessionPaths(directory: URL(fileURLWithPath: "/unused/\(session)")))
    }

    private func reply(mode: ControlMode = .runner) -> [String: Any] {
        [
            "session": session, "ok": true, "hostPid": 123, "idleRemainingSeconds": 1200,
            "result": [
                "runnerSession": "original-runner", "controlAvailable": true,
                "connection": ["phase": "ready", "requiresUserAction": false],
                "preview": ["state": "streaming", "url": "http://127.0.0.1:8765/original/"],
                "touchPaste": ["restorePending": false]
            ]
        ]
    }

    func testReuseKeepsHostPreviewAndTimeoutInBothModes() throws {
        for mode: ControlMode in [.standard, .runner] {
            var calls = 0
            let original = reply(mode: mode)
            let reused = try XCTUnwrap(
                SessionDiscovery.reuse(candidates: [candidate(mode: mode)], mode: mode) {
                    XCTAssertEqual($0, self.session); calls += 1; return original
                })
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(reused["session"] as? String, session)
            XCTAssertEqual(reused["hostPid"] as? Int, 123)
            XCTAssertEqual(reused["idleRemainingSeconds"] as? Int, 1200)
            XCTAssertEqual(reused["reused"] as? Bool, true)
            XCTAssertEqual((reused["lifecycle"] as? [String: Any])?["disconnectOnFinish"] as? Bool, false)
            XCTAssertEqual(
                try jsonData((try XCTUnwrap(reused["result"] as? [String: Any]))),
                try jsonData((try XCTUnwrap(original["result"] as? [String: Any]))))
        }
    }

    func testNoCandidateAllowsNewConnectionAndAmbiguityFailsClosed() throws {
        XCTAssertNil(
            try SessionDiscovery.reuse(candidates: [], mode: .runner) { _ in
                XCTFail("Status must not be requested"); return [:]
            })
        XCTAssertThrowsError(
            try SessionDiscovery.reuse(candidates: [candidate(), candidate()], mode: .runner) { _ in
                XCTFail("Status must not be requested"); return [:]
            }
        ) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "session_ambiguous")
        }
    }

    func testModeOrExplicitRunnerConflictDoesNotProbeOrRestart() throws {
        for (mode, runner): (ControlMode, String?) in [
            (.standard, nil), (.runner, "/different/Runner.xctestrun")
        ] {
            XCTAssertThrowsError(
                try SessionDiscovery.reuse(candidates: [candidate()], mode: mode, xctestrun: runner) { _ in
                    XCTFail("Status must not be requested"); return [:]
                }
            ) {
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, "session_configuration_conflict")
            }
        }
    }

    func testUnavailableBusyUnauthorizedAndPendingTransactionsAreNotReused() throws {
        var unavailable = reply(); unavailable["ok"] = false
        var wrong = reply(); wrong["session"] = "different"
        var busy = reply(); busy["pendingOperationsAtRequest"] = 1
        var cases: [([String: Any], String)] = [
            (unavailable, "session_not_ready"), (wrong, "session_not_ready"), (busy, "session_busy")
        ]
        struct StatusMutation {
            let key: String
            let value: Any
            let error: String
        }
        for sample in [
            .init(key: "controlAvailable", value: false, error: "session_not_ready"),
            .init(key: "runnerSession", value: "", error: "session_not_ready"),
            .init(key: "connection", value: ["phase": "starting"], error: "session_not_ready"),
            .init(key: "connection", value: ["requiresUserAction": true], error: "session_not_ready"),
            .init(key: "touchPaste", value: ["restorePending": true], error: "session_transaction_pending"),
            .init(key: "pasteboard", value: ["writeUncertain": true], error: "session_transaction_pending")
        ] as [StatusMutation] {
            let key = sample.key
            let value = sample.value
            let error = sample.error

            var valueReply = reply(), result = (try XCTUnwrap(valueReply["result"] as? [String: Any]))
            result[key] = value; valueReply["result"] = result; cases.append((valueReply, error))
        }
        for (response, code) in cases {
            XCTAssertThrowsError(
                try SessionDiscovery.reuse(candidates: [candidate()], mode: .runner) { _ in response }
            ) {
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, code)
            }
        }
    }

    func testExplicitPreviewPortCannotMoveExistingPreview() throws {
        XCTAssertThrowsError(
            try SessionDiscovery.reuse(candidates: [candidate()], mode: .runner, previewPort: 9999) { _ in
                self.reply()
            }
        ) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "preview_already_running")
        }
        XCTAssertNotNil(
            try SessionDiscovery.reuse(candidates: [candidate()], mode: .runner, previewPort: 8765) { _ in
                self.reply()
            })
    }

    func testDiscoveryIgnoresEndedInvalidAndLinkedDirectories() throws {
        let root = URL(fileURLWithPath: "/private/tmp/reuse-\(UUID().uuidString)")
        try SessionPaths.secureDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let ended = root.appendingPathComponent(session)
        try SessionPaths.secureDirectory(ended)
        try JSONEncoder().encode(candidate().config).write(to: ended.appendingPathComponent("config.json"))
        let alias = root.appendingPathComponent("s" + String(repeating: "2", count: 32))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: ended)
        XCTAssertTrue(try SessionDiscovery.candidates(root: root, device: nil).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ended.path))
        XCTAssertTrue(
            try SessionDiscovery.candidates(root: root.appendingPathComponent("missing"), device: nil).isEmpty
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
    }
}

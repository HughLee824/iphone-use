import XCTest
@testable import IPhoneUseCore

final class RunnerAuthorizationTests: XCTestCase {
    private func line(_ message: String, process: String = "testmanagerd(AutomationMode)") -> String {
        "Oct 19 10:20:07.596645 \(process)[536] <Notice>: \(message)"
    }
    func testOnlyExactSystemMessagesAreEvidence() {
        XCTAssertEqual(
            RunnerAuthorizationEvent.parse(
                line("Writer daemon requires authentication to enable automation mode.")),
            .required(manager: 536))
        XCTAssertEqual(
            RunnerAuthorizationEvent.parse(
                line("User authenticated, forwarding authorization to writer daemon.")),
            .authenticated(manager: 536))
        XCTAssertEqual(
            RunnerAuthorizationEvent.parse(
                line("Finished enabling Automation Mode", process: "testmanagerd")),
            .enabled(manager: 536))
        XCTAssertEqual(
            RunnerAuthorizationEvent.parse(
                line(
                    "Added Automation Mode client <XCTestSession: 0x123> pid 1026. Total clients: 1",
                    process: "testmanagerd")), .client(manager: 536, runner: 1026))
        for message in [
            "Enable UI Automation", "USB connection timed out", "Runner exited", "Authorization denied",
            "Camera permission requested", "Photos access authorization required",
            "Location permission requested",
            "prefix Writer daemon requires authentication to enable automation mode."
        ] {
            XCTAssertNil(RunnerAuthorizationEvent.parse(line(message)))
        }
        XCTAssertNil(
            RunnerAuthorizationEvent.parse(
                line("Writer daemon requires authentication to enable automation mode.", process: "SomeApp")))
    }

    func testRawSyslogHostnameAndAmbiguousClients() {
        let raw =
            """
            Oct 19 10:20:07 iPhone testmanagerd(AutomationMode)[536] <Notice>: Writer daemon requires\
             authentication to enable automation mode.
            """
        XCTAssertEqual(RunnerAuthorizationEvent.parse(raw), .required(manager: 536))
        XCTAssertEqual(
            RunnerAuthorizationEvent.parse(
                line(
                    "Added Automation Mode client <XCTestSession: 0x123> pid 1026. Total clients: 2",
                    process: "testmanagerd")), .client(manager: 536, runner: -1))
    }

    func testAssociationAndRecoveryAcrossLaunchRace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = RunnerAuthorization(directory: directory)
        state.receive(["kind": "monitor_ready"])
        state.receive(RunnerAuthorizationEvent.client(manager: 536, runner: 1026).wire)
        state.receive(RunnerAuthorizationEvent.required(manager: 536).wire)
        XCTAssertEqual(state.snapshot()["requiresUserAction"] as? Bool, false)
        state.bind(runnerPID: 1026)
        XCTAssertEqual(state.snapshot()["requiresUserAction"] as? Bool, true)
        XCTAssertEqual(state.snapshot()["reason"] as? String, "ui_automation_authorization_required")
        XCTAssertEqual(
            RunnerStartupDiagnostics.failure(processExited: true, authorization: state.snapshot()).code,
            "runner_authorization_incomplete")
        state.receive(RunnerAuthorizationEvent.authenticated(manager: 536).wire)
        XCTAssertEqual(state.snapshot()["requiresUserAction"] as? Bool, false)
        state.ready()
        XCTAssertEqual(state.snapshot()["phase"] as? String, "ready")
        // Authorization events remain observable while media/commands run.
        state.receive(RunnerAuthorizationEvent.required(manager: 536).wire)
        XCTAssertEqual(state.snapshot()["requiresUserAction"] as? Bool, true)
        state.receive(RunnerAuthorizationEvent.enabled(manager: 536).wire)
        XCTAssertEqual(state.snapshot()["requiresUserAction"] as? Bool, false)
        state.receive(RunnerAuthorizationEvent.required(manager: 536).wire)
        state.receive(["kind": "monitor_unavailable"])
        XCTAssertEqual(state.snapshot()["monitorAvailable"] as? Bool, false)
        XCTAssertEqual(state.snapshot()["authorization"] as? String, "unverified")
        XCTAssertEqual(state.snapshot()["requiresUserAction"] as? Bool, false)
    }

    func testOtherRunnerOrManagerAndConnectionFailuresNeverBecomeAuthorization() {
        let state = RunnerAuthorization(directory: URL(fileURLWithPath: "/nonexistent/authorization-test"))
        state.receive(["kind": "monitor_ready"]); state.bind(runnerPID: 1026)
        state.receive(RunnerAuthorizationEvent.client(manager: 536, runner: 999).wire)
        state.receive(RunnerAuthorizationEvent.required(manager: 536).wire)
        XCTAssertEqual(state.snapshot()["requiresUserAction"] as? Bool, false)
        state.receive(RunnerAuthorizationEvent.client(manager: 536, runner: 1026).wire)
        state.receive(RunnerAuthorizationEvent.required(manager: 537).wire)
        XCTAssertEqual(state.snapshot()["requiresUserAction"] as? Bool, false)
        state.failed("USB unavailable")
        XCTAssertEqual(state.snapshot()["requiresUserAction"] as? Bool, false)
        XCTAssertEqual(
            RunnerStartupDiagnostics.failure(processExited: true, authorization: state.snapshot()).code,
            "runner_start_failed")
    }
}

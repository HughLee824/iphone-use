import XCTest
import Darwin
@testable import IPhoneUseCore

final class PreviewServiceRestartTests: XCTestCase {
    private func launch(_ executable: URL, _ arguments: [String], input: Pipe? = nil,
                        environment: [String: String]? = nil) throws -> (Process, Pipe) {
        let process = Process(), output = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.environment = environment
        if let input { process.standardInput = input } else { process.standardInput = FileHandle.nullDevice }
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        addTeardownBlock {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        return (process, output)
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval = 10) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard !process.isRunning else { throw IPhoneUseError("test_timeout", "Test process did not exit") }
    }

    private func waitForOwner(_ child: Process, directory: URL) throws {
        let ready = directory.appendingPathComponent("ready")
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !FileManager.default.fileExists(atPath: ready.path), child.isRunning,
            ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard FileManager.default.fileExists(atPath: ready.path) else {
            throw IPhoneUseError("fixture_failed", "Child did not acquire ownership and install its signal handler")
        }
    }

    func testCleanupPendingBlocksAnotherLaunchUntilOwnedChildExits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-" + UUID().uuidString.prefix(8))
        try SessionPaths.secureDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        // Reserve a random port through the real listener, then release it before any daemon is launched.
        let reservation = try PreviewService(directory: root.appendingPathComponent("reservation"), port: 0)
        try reservation.start()
        let port = reservation.port
        reservation.stop()
        let directory = root.appendingPathComponent("previews/\(port)")
        let client = try PreviewServiceClient(port: port, directory: directory)
        addTeardownBlock { _ = try? client.stopAndWait() }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repository.appendingPathComponent("scripts/tests/fixtures/preview_process.py")
        let input = Pipe()
        let (child, _) = try launch(URL(fileURLWithPath: "/usr/bin/env"),
                                    ["python3", fixture.path, "unresponsive-owner", directory.path], input: input)
        try waitForOwner(child, directory: directory)

        XCTAssertThrowsError(try PreviewServiceProcess.waitForStartup(child, timeout: 0.05, terminationGrace: 0.1) {
            (try? client.call("ping")) != nil
        }) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "preview_service_cleanup_pending")
        }
        var environment = ProcessInfo.processInfo.environment
        let cli = environment["IPHONE_USE_TEST_CLI"].map { URL(fileURLWithPath: $0) }
            ?? repository.appendingPathComponent(".build/debug/iphone-use")
        environment["IPHONE_USE_CONFIG_DIR"] = root.path
        let arguments = ["preview-revoke", "--device", "missing-after-cleanup", "--port", String(port)]
        let (blocked, blockedOutput) = try launch(cli, arguments, environment: environment)
        try waitForExit(blocked)
        let failure = try jsonObject(blockedOutput.fileHandleForReading.readDataToEndOfFile())
        XCTAssertNotEqual(blocked.terminationStatus, 0)
        XCTAssertEqual((failure["error"] as? [String: Any])?["code"] as? String, "preview_service_busy")
        XCTAssertTrue(child.isRunning, "A retry must not terminate or replace the pending child")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("service.log").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ipc.sock").path))
        XCTAssertThrowsError(try DeviceLock(root: directory, device: "service")) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "device_busy")
        }

        try input.fileHandleForWriting.write(contentsOf: Data("exit\n".utf8))
        try waitForExit(child, timeout: 3)
        XCTAssertEqual(child.terminationStatus, 0)
        let (restarted, restartedOutput) = try launch(cli, arguments, environment: environment)
        try waitForExit(restarted)
        let response = try jsonObject(restartedOutput.fileHandleForReading.readDataToEndOfFile())
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String, "preview_not_found")
        XCTAssertEqual(try client.call("ping")["ok"] as? Bool, true)
        let stopped = try client.stopAndWait()
        XCTAssertEqual(stopped["exited"] as? Bool, true)
    }
}

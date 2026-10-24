import XCTest
import Darwin
@testable import IPhoneUseCore

final class PreviewServiceProcessTests: XCTestCase {
    private func child(trap: String = "exit 0", afterReady: String = "while :; do sleep 0.02; done") throws -> Process {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '\(trap)' TERM; touch \"$1\"; \(afterReady)", "preview-test", marker.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        addTeardownBlock {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: marker)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !FileManager.default.fileExists(atPath: marker.path), ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "Child must install its signal handler")
        return process
    }

    func testStartupTimeoutWaitsForDelayedChildTerminationWithoutTouchingOtherProcesses() throws {
        let process = try child(trap: "sleep 0.25; exit 0"), other = try child()
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(try PreviewServiceProcess.waitForStartup(process, timeout: 0.05, terminationGrace: 2) { false })
        XCTAssertFalse(process.isRunning)
        XCTAssertTrue(other.isRunning)
        XCTAssertGreaterThan(ProcessInfo.processInfo.systemUptime - started, 0.25)
    }

    func testUnconfirmedChildCleanupIsReportedWithinDeadline() throws {
        let process = try child(trap: "") // Deliberately ignore TERM; teardown owns the eventual forced cleanup.
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try PreviewServiceProcess.waitForStartup(process, timeout: 0.05, terminationGrace: 0.1) {
            false
        }) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "preview_service_cleanup_pending")
        }
        XCTAssertTrue(process.isRunning)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
    }

    func testReadyChildIsPreservedAndEarlyExitDoesNotWaitForStartupDeadline() throws {
        let running = try child()
        XCTAssertTrue(try PreviewServiceProcess.waitForStartup(running) { true })
        XCTAssertTrue(running.isRunning)
        let exited = try child(afterReady: "exit 7")
        exited.waitUntilExit()
        XCTAssertFalse(try PreviewServiceProcess.waitForStartup(exited) {
            XCTFail("An exited child must not be considered ready"); return true
        })
    }

    func testExitObserverDistinguishesRunningDelayedExitAndAlreadyExitedProcess() throws {
        let process = try child(trap: "sleep 0.1; exit 0")
        let observer = try PreviewProcessExit(pid: process.processIdentifier)
        XCTAssertFalse(observer.wait(timeout: 0.02))
        process.terminate()
        XCTAssertTrue(observer.wait(timeout: 2))
        process.waitUntilExit()
        XCTAssertTrue(try PreviewProcessExit(pid: process.processIdentifier).wait(timeout: 0.1))
        XCTAssertThrowsError(try PreviewProcessExit(pid: 0))
    }
}

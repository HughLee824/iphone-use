import XCTest
import Foundation
import Network
@testable import IPhoneUseCore

extension HostTests {

    func testCoordinateReferenceConflictCanBeCorrectedWithoutRecapturing() throws {
        let backend = ControlledBackend()
        let running = try host(timeout: 5, backend: backend)
        let paths = running.paths, session = running.session, finished = running.finished
        for (index, operation) in ["tap", "swipe"].enumerated() {
            _ = try call(paths, session: session, op: "observe")
            let observation = "o\(index + 1)"
            let reference = "\(observation):e1"
            var fields: [String: Any] =
                operation == "tap"
                ? ["x": 100, "y": 600]
                : ["fromX": 100, "fromY": 600, "toX": 100, "toY": 550]
            fields["reference"] = reference
            let rejected = try call(paths, session: session, op: operation, fields: fields)
            XCTAssertEqual(rejected["outcome"] as? String, "not_dispatched")
            let error = try XCTUnwrap(rejected["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "invalid_coordinates")
            let message = try XCTUnwrap(error["message"] as? String)
            XCTAssertTrue(message.contains("Element reference \(reference)"))
            XCTAssertTrue(message.contains("Use \(operation) \(observation) "))
            XCTAssertTrue(message.contains("--protect \(reference)"))
            XCTAssertEqual(backend.actionCount, index)
            XCTAssertEqual(backend.inputCount, index)

            fields["reference"] = observation
            fields["protect"] = [reference]
            let corrected = try call(paths, session: session, op: operation, fields: fields)
            XCTAssertEqual(corrected["outcome"] as? String, "completed")
            XCTAssertEqual(backend.inputCount, index + 1)
            XCTAssertEqual(backend.observeCount, index + 1)
        }
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }

    func testHealthTrafficCannotPreventIdleCleanup() throws {
        let backend = ControlledBackend()
        let running = try host(timeout: 0.4, backend: backend)
        let paths = running.paths, session = running.session, finished = running.finished
        let observed = try (try XCTUnwrap(call(paths, session: session, op: "observe")["result"] as? [String: Any]))
        let deadline = Date().addingTimeInterval(1.2)
        var checks = 0
        while Date() < deadline {
            if let reply = try? call(paths, session: session, op: "status"), reply["ok"] as? Bool == true {
                checks += 1
            } else {
                break
            }
            Thread.sleep(forTimeInterval: 0.04)
        }
        wait(for: [finished], timeout: 2)
        XCTAssertGreaterThan(checks, 2)
        XCTAssertEqual(try jsonObject(Data(contentsOf: paths.exit))["reason"] as? String, "idle_timeout")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: (try XCTUnwrap(observed["screenshot"] as? String))))
        XCTAssertThrowsError(
            try call(paths, session: session, op: "inspect", fields: ["reference": "o1", "offset": 0]))
    }

    func testInFlightCommandSurvivesTimeoutAndRenewsAtCompletion() throws {
        let backend = ControlledBackend()
        backend.blockOpen = true
        let running = try host(timeout: 0.4, backend: backend)
        let paths = running.paths, session = running.session, finished = running.finished
        let responseReceived = expectation(description: "open completed")
        DispatchQueue.global().async {
            do {
                let response = try self.call(
                    paths, session: session, op: "open", fields: ["bundleId": "fixture"])
                XCTAssertEqual(response["outcome"] as? String, "completed")
            } catch { XCTFail("\(error)") }
            responseReceived.fulfill()
        }
        XCTAssertEqual(backend.opened.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(backend.stopped.wait(timeout: .now() + 0.65), .timedOut)
        backend.releaseOpen.signal()
        wait(for: [responseReceived], timeout: 2)
        let status = try call(paths, session: session, op: "status")
        XCTAssertGreaterThan(status["idleRemainingSeconds"] as? Double ?? 0, 0.2)
        wait(for: [finished], timeout: 2)
    }

    func testDisconnectWaitsForAdmittedCommand() throws {
        let backend = ControlledBackend()
        backend.blockOpen = true
        let running = try host(timeout: 5, backend: backend)
        let paths = running.paths, session = running.session, finished = running.finished
        let action = expectation(description: "action returned")
        let disconnect = expectation(description: "disconnect returned")
        DispatchQueue.global().async {
            _ = try? self.call(paths, session: session, op: "open", fields: ["bundleId": "fixture"])
            action.fulfill()
        }
        XCTAssertEqual(backend.opened.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            do {
                let response = try self.call(paths, session: session, op: "disconnect")
                XCTAssertEqual(response["ok"] as? Bool, true)
            } catch { XCTFail("\(error)") }
            disconnect.fulfill()
        }
        XCTAssertEqual(backend.stopped.wait(timeout: .now() + 0.2), .timedOut)
        backend.releaseOpen.signal()
        wait(for: [action, disconnect, finished], timeout: 3)
        XCTAssertEqual(backend.openCount, 1)
        XCTAssertEqual(backend.stopCount, 1)
    }

    func testInvalidRequestsDoNotDispatchAndUnknownIsNotReplayed() throws {
        let backend = ControlledBackend()
        backend.loseOpenResponse = true
        let running = try host(timeout: 5, backend: backend)
        let paths = running.paths, session = running.session, finished = running.finished
        XCTAssertEqual(try call(paths, session: session, op: "open")["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(backend.openCount, 0)
        XCTAssertEqual(
            try call(paths, session: session, op: "open", fields: ["bundleId": "fixture"])["outcome"]
                as? String,
            "unknown")
        _ = try call(paths, session: session, op: "status")
        XCTAssertEqual(backend.openCount, 1)
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }

    func testDeviceLockExclusionAndRelease() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/as-lock-\(UUID().uuidString.prefix(8))")
        try SessionPaths.secureDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var first: DeviceLock? = try DeviceLock(root: directory, device: "device-1")
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try DeviceLock(root: directory, device: "device-1"))
        first = nil
        XCTAssertNoThrow(try DeviceLock(root: directory, device: "device-1"))
    }

    func testInspectDoesNotCallDeviceAndDispatchedOpenInvalidatesCachedRefs() throws {
        let backend = ControlledBackend()
        let running = try host(timeout: 5, backend: backend)
        let paths = running.paths, session = running.session, finished = running.finished
        let observed = try (try XCTUnwrap(call(paths, session: session, op: "observe")["result"] as? [String: Any]))
        let image = (try XCTUnwrap(observed["screenshot"] as? String))
        let inspect: [String: Any] = ["reference": "o1:e27", "offset": 0]
        func validity() throws -> String? {
            (try call(paths, session: session, op: "inspect", fields: inspect)["result"] as? [String: Any])?[
                "refs"]
                as? String
        }
        XCTAssertEqual(try validity(), "current")
        _ = try call(paths, session: session, op: "open") // Invalid parameter, never admitted.
        XCTAssertEqual(try validity(), "current")
        backend.rejectOpenBeforeSend = true
        XCTAssertEqual(
            try call(paths, session: session, op: "open", fields: ["bundleId": "fixture"])["outcome"]
                as? String,
            "not_dispatched")
        XCTAssertEqual(try validity(), "current")
        backend.rejectOpenBeforeSend = false
        backend.loseOpenResponse = true
        XCTAssertEqual(
            try call(paths, session: session, op: "open", fields: ["bundleId": "fixture"])["outcome"]
                as? String,
            "unknown")
        XCTAssertEqual(try validity(), "invalidated")
        XCTAssertEqual(backend.observeCount, 1)
        XCTAssertEqual(backend.openCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: image))
        _ = try call(paths, session: session, op: "observe")
        backend.loseOpenResponse = false
        _ = try call(paths, session: session, op: "open", fields: ["bundleId": "fixture"])
        let latest = try call(
            paths, session: session, op: "inspect", fields: ["reference": "o2:e27", "offset": 0])
        XCTAssertEqual((latest["result"] as? [String: Any])?["refs"] as? String, "invalidated")
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: image))
    }

    func testInspectQueryFindsLaterNodesWithoutRecapturingOrRevivingReferences() throws {
        let backend = ControlledBackend()
        let running = try host(timeout: 5, backend: backend)
        let paths = running.paths, session = running.session, finished = running.finished
        _ = try call(paths, session: session, op: "observe")
        let fields: [String: Any] = ["reference": "o1", "offset": 0, "query": "wEb iNpUt"]
        let reply = try call(paths, session: session, op: "inspect", fields: fields)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        let text = try XCTUnwrap(result["text"] as? String)
        XCTAssertEqual(result["query"] as? String, "wEb iNpUt")
        // The recorded source contains a group, its text child and the separate input.
        XCTAssertTrue(text.contains("matched_nodes=3"))
        XCTAssertTrue(text.contains("\"ref\":\"o1:e25\""))
        XCTAssertTrue(text.contains("\"ref\":\"o1:e26\""))
        XCTAssertTrue(text.contains("\"ref\":\"o1:e27\""))
        XCTAssertTrue(text.contains("\"parentRef\":"))
        XCTAssertEqual(result["refs"] as? String, "current")
        _ = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e27"])
        let stale = try call(paths, session: session, op: "inspect", fields: fields)
        XCTAssertEqual((stale["result"] as? [String: Any])?["refs"] as? String, "invalidated")
        XCTAssertEqual(backend.observeCount, 1)
        XCTAssertEqual(backend.inputCount, 1)
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }
}

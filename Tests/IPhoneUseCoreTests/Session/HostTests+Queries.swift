import XCTest
import Foundation
import Network
@testable import IPhoneUseCore

extension HostTests {

    func testInvalidInspectQueryDoesNotRenewOrChangeReferences() throws {
        let backend = ControlledBackend()
        let running = try host(timeout: 5, backend: backend)
        let paths = running.paths, session = running.session, finished = running.finished
        _ = try call(paths, session: session, op: "observe")
        let first = try (try XCTUnwrap(call(paths, session: session, op: "status")["idleRemainingSeconds"] as? Double))
        Thread.sleep(forTimeInterval: 0.1)
        for query: Any in [42, NSNull(), "", "  ", "one\ntwo", String(repeating: "a", count: 257)] {
            let reply = try call(
                paths, session: session, op: "inspect",
                fields: ["reference": "o1", "offset": 0, "query": query])
            XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? String, "invalid_inspect_query")
        }
        let afterInvalid = try
            (try XCTUnwrap(call(paths, session: session, op: "status")["idleRemainingSeconds"] as? Double))
        XCTAssertLessThan(afterInvalid, first - 0.08)
        let result = try call(
            paths, session: session, op: "inspect",
            fields: ["reference": "o1", "offset": 0, "query": "absent"])
        XCTAssertEqual((result["result"] as? [String: Any])?["refs"] as? String, "current")
        let renewed = try
            (try XCTUnwrap(call(paths, session: session, op: "status")["idleRemainingSeconds"] as? Double))
        XCTAssertGreaterThan(renewed, afterInvalid + 0.08)
        XCTAssertEqual(backend.observeCount, 1)
        XCTAssertEqual(backend.actionCount, 0)
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }

    func testObservationAndInspectRenewIdleButInvalidInspectDoesNot() throws {
        let backend = ControlledBackend()
        let running = try host(timeout: 5, backend: backend)
        let paths = running.paths, session = running.session, finished = running.finished
        _ = try call(paths, session: session, op: "observe")
        let first = try (try XCTUnwrap(call(paths, session: session, op: "status")["idleRemainingSeconds"] as? Double))
        Thread.sleep(forTimeInterval: 0.1)
        let invalid = try call(
            paths, session: session, op: "inspect", fields: ["reference": "o99", "offset": 0])
        XCTAssertEqual(invalid["ok"] as? Bool, false)
        let afterInvalid = try
            (try XCTUnwrap(call(paths, session: session, op: "status")["idleRemainingSeconds"] as? Double))
        XCTAssertLessThan(afterInvalid, first - 0.08)
        _ = try call(paths, session: session, op: "inspect", fields: ["reference": "o1", "offset": 0])
        let renewed = try
            (try XCTUnwrap(call(paths, session: session, op: "status")["idleRemainingSeconds"] as? Double))
        XCTAssertGreaterThan(renewed, afterInvalid + 0.08)
        XCTAssertEqual(backend.observeCount, 1)
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }

    func testAppDiscoveryRenewsOnlyOnSuccessAndPreservesObservationReferences() throws {
        let backend = ControlledBackend()
        let running = try host(timeout: 5, backend: backend)
        let paths = running.paths, session = running.session, finished = running.finished
        _ = try call(paths, session: session, op: "observe")
        let first = try (try XCTUnwrap(call(paths, session: session, op: "status")["idleRemainingSeconds"] as? Double))
        Thread.sleep(forTimeInterval: 0.1)
        let invalid = try call(paths, session: session, op: "apps", fields: ["offset": -1])
        XCTAssertEqual(invalid["ok"] as? Bool, false)
        XCTAssertEqual(backend.appsCount, 0)
        let pastEnd = try call(paths, session: session, op: "apps", fields: ["offset": 2])
        XCTAssertEqual(pastEnd["ok"] as? Bool, false)
        let afterInvalid = try
            (try XCTUnwrap(call(paths, session: session, op: "status")["idleRemainingSeconds"] as? Double))
        XCTAssertLessThan(afterInvalid, first - 0.08)
        let listed = try call(paths, session: session, op: "apps", fields: ["offset": 0, "query": "Fixture"])
        XCTAssertEqual((listed["result"] as? [String: Any])?["total"] as? Int, 1)
        let renewed = try
            (try XCTUnwrap(call(paths, session: session, op: "status")["idleRemainingSeconds"] as? Double))
        XCTAssertGreaterThan(renewed, afterInvalid + 0.08)
        let inspected = try call(
            paths, session: session, op: "inspect", fields: ["reference": "o1:e11", "offset": 0])
        XCTAssertEqual((inspected["result"] as? [String: Any])?["refs"] as? String, "current")
        XCTAssertEqual(backend.observeCount, 1)
        XCTAssertEqual(backend.actionCount, 0)
        for bundle in ["invalid bundle", "com.example.fixture\n"] {
            XCTAssertEqual(
                try call(paths, session: session, op: "open", fields: ["bundleId": bundle])["outcome"]
                    as? String,
                "not_dispatched")
        }
        XCTAssertEqual(backend.openCount, 0)
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }

    func testActionFactsPreserveRejectedReferencesAndInvalidateChangedOrUnknownTargets() throws {
        let backend = ControlledBackend()
        let running = try host(timeout: 5, backend: backend)
        let paths = running.paths, session = running.session, finished = running.finished
        for (index, failure) in [
            ActionFailure(
                code: "ambiguous_target", description: "Ambiguous", possiblyExecuted: false,
                requiresObservation: false),
            ActionFailure(
                code: "target_changed", description: "Changed", possiblyExecuted: false,
                requiresObservation: true),
            ActionFailure(
                code: "lost_result", description: "Unknown", possiblyExecuted: true, requiresObservation: true
            )
        ].enumerated() {
            _ = try call(paths, session: session, op: "observe")
            backend.actionFailure = failure
            let reference = "o\(index + 1):e11"
            let result = try call(paths, session: session, op: "tap", fields: ["reference": reference])
            XCTAssertEqual(
                result["outcome"] as? String, failure.possiblyExecuted ? "unknown" : "not_dispatched")
            XCTAssertTrue(
                backend.previewGestures.isEmpty, "Thrown failures must not publish inferred touches")
            let detail = try call(
                paths, session: session, op: "inspect", fields: ["reference": reference, "offset": 0])
            XCTAssertEqual(
                (detail["result"] as? [String: Any])?["refs"] as? String,
                index == 0 ? "current" : (index == 1 ? "target_changed" : "invalidated"))
        }
        XCTAssertEqual(backend.actionCount, 3)
        let stale = try call(paths, session: session, op: "tap", fields: ["reference": "o3:e11"])
        XCTAssertEqual(stale["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(backend.actionCount, 3)
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }

    func testReturnRejectsInvalidTargetsAndInvalidatesWithoutReplay() throws {
        let backend = ControlledBackend()
        let running = try host(timeout: 5, backend: backend)
        let paths = running.paths, session = running.session, finished = running.finished
        _ = try call(paths, session: session, op: "observe")
        for fields in [["reference": "o1:e27", "key": "enter"], ["reference": "o1:e11", "key": "return"]] {
            XCTAssertEqual(
                try call(paths, session: session, op: "press", fields: fields)["outcome"] as? String,
                "not_dispatched")
        }
        XCTAssertEqual(backend.actionCount, 0)
        let detail = try call(
            paths, session: session, op: "inspect", fields: ["reference": "o1", "offset": 0])
        XCTAssertEqual((detail["result"] as? [String: Any])?["refs"] as? String, "current")
        let fields = ["reference": "o1:e27", "key": "return"]
        XCTAssertEqual(
            try call(paths, session: session, op: "press", fields: fields)["outcome"] as? String, "completed")
        XCTAssertEqual(
            try call(paths, session: session, op: "press", fields: fields)["outcome"] as? String,
            "not_dispatched")
        XCTAssertEqual(backend.actionCount, 1)
        _ = try call(paths, session: session, op: "observe")
        backend.actionFailure = ActionFailure(
            code: "lost_result", description: "Unknown", possiblyExecuted: true, requiresObservation: true)
        XCTAssertEqual(
            try call(paths, session: session, op: "press", fields: ["reference": "o2:e27", "key": "return"])[
                "outcome"]
                as? String, "unknown")
        let afterUnknown = try call(
            paths, session: session, op: "inspect", fields: ["reference": "o2", "offset": 0])
        XCTAssertEqual((afterUnknown["result"] as? [String: Any])?["refs"] as? String, "invalidated")
        _ = try call(paths, session: session, op: "status")
        XCTAssertEqual(backend.actionCount, 2)
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }

    func testQueuedActionsCannotReuseAReferenceAfterTheFirstAction() throws {
        let backend = ControlledBackend()
        backend.blockAction = true
        let running = try host(timeout: 5, backend: backend)
        let paths = running.paths, session = running.session, finished = running.finished
        _ = try call(paths, session: session, op: "observe")
        let first = expectation(description: "first action")
        let second = expectation(description: "second action rejected")
        DispatchQueue.global().async {
            do {
                let result = try self.call(
                    paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
                XCTAssertEqual(result["outcome"] as? String, "completed")
            } catch { XCTFail("\(error)") }
            first.fulfill()
        }
        XCTAssertEqual(backend.actionStarted.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            do {
                let result = try self.call(
                    paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
                XCTAssertEqual(result["outcome"] as? String, "not_dispatched")
            } catch { XCTFail("\(error)") }
            second.fulfill()
        }
        backend.releaseAction.signal()
        wait(for: [first, second], timeout: 3)
        XCTAssertEqual(backend.actionCount, 1)
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }

    func testUnstableFramePreservesCompletedInputAndCannotReplayAnOldReference() throws {
        let backend = ControlledBackend()
        backend.actionFailure = ActionFailure(
            code: "frame_stability_timeout", description: "Screen still changing",
            possiblyExecuted: true, requiresObservation: true,
            result: [
                "execution": ["started": true, "inputCompleted": true, "completed": false],
                "stability": ["stable": false], "frame": ["screenshot": "/last-action.png"]
            ])
        let running = try host(timeout: 5, backend: backend)
        let paths = running.paths, session = running.session, finished = running.finished
        _ = try call(paths, session: session, op: "observe")
        let result = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
        XCTAssertEqual(result["outcome"] as? String, "unknown")
        let details = result["result"] as? [String: Any]
        XCTAssertEqual((details?["execution"] as? [String: Bool])?["inputCompleted"], true)
        XCTAssertEqual((details?["stability"] as? [String: Bool])?["stable"], false)
        let retry = try call(paths, session: session, op: "tap", fields: ["reference": "o1:e11"])
        XCTAssertEqual(retry["outcome"] as? String, "not_dispatched")
        XCTAssertEqual(backend.actionCount, 1)
        _ = try call(paths, session: session, op: "disconnect")
        wait(for: [finished], timeout: 3)
    }
}

import XCTest
@testable import IPhoneUseCore

final class RunnerLifecycleTests: XCTestCase {
    func testHomeConfirmsInputWithoutClaimingStaticDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let response: [String: Any] = [
            "ok": true,
            "execution": ["started": true, "inputCompleted": true, "completed": true],
            "result": ["kind": "home", "homePressCompleted": true, "homeScreenConfirmed": false]
        ]
        let result = try ActionReply.decode(
            XCTestCapture.actionResponse(response, directory: directory, expectedHome: true))
        XCTAssertEqual(result["homeScreenConfirmed"] as? Bool, false)
        // The exception is Home-specific: other inputs still require stability.
        XCTAssertThrowsError(try XCTestCapture.actionResponse(response, directory: directory))
        var invalid = response; invalid["result"] = ["kind": "home"]
        XCTAssertThrowsError(
            try XCTestCapture.actionResponse(invalid, directory: directory, expectedHome: true))
    }

    private func reply(relaunch: Bool, stopped: Bool) -> [String: Any] {
        [
            "ok": true, "execution": ["started": relaunch || !stopped, "completed": true],
            "result": [
                "bundleId": "com.example.probe", "operation": relaunch ? "relaunch" : "terminate",
                "alreadyStopped": stopped, "terminationRequested": !stopped,
                "terminationAcknowledged": !stopped,
                "stoppedConfirmed": true, "launchRequested": relaunch, "launchAcknowledged": relaunch,
                "foregroundConfirmed": relaunch, "appState": relaunch ? 4 : 1
            ]
        ]
    }

    func testConfirmedTransitionsAndAlreadyStoppedNoOp() throws {
        for relaunch in [false, true] {
            for stopped in [false, true] {
                let result = try XCTestBackend.lifecycleResponse(
                    reply(relaunch: relaunch, stopped: stopped), bundle: "com.example.probe",
                    relaunch: relaunch)
                XCTAssertEqual(
                    (result["execution"] as? [String: Any])?["started"] as? Bool, relaunch || !stopped)
                XCTAssertEqual(result["stoppedConfirmed"] as? Bool, true)
            }
        }
    }

    func testIncompleteOrWrongTargetFactsRemainUnknown() throws {
        for key in [
            "bundleId", "operation", "alreadyStopped", "stoppedConfirmed", "terminationAcknowledged",
            "launchAcknowledged", "foregroundConfirmed", "appState"
        ] {
            var response = reply(relaunch: true, stopped: false)
            var result = (try XCTUnwrap(response["result"] as? [String: Any]))
            result.removeValue(forKey: key)
            response["result"] = result
            XCTAssertThrowsError(
                try XCTestBackend.lifecycleResponse(response, bundle: "com.example.probe", relaunch: true)
            ) {
                XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true)
            }
        }
        XCTAssertThrowsError(
            try XCTestBackend.lifecycleResponse(
                reply(relaunch: false, stopped: true), bundle: "com.example.other", relaunch: false))
    }

    func testFailureAfterTerminationPreservesPartialFacts() {
        let response: [String: Any] = [
            "ok": false, "execution": ["started": true, "completed": false],
            "errorCode": "app_stop_unconfirmed",
            "result": ["terminationRequested": true, "launchRequested": false]
        ]
        XCTAssertThrowsError(
            try XCTestBackend.lifecycleResponse(response, bundle: "com.example.probe", relaunch: true)
        ) {
            let failure = $0 as? ActionFailure
            XCTAssertEqual(failure?.possiblyExecuted, true)
            XCTAssertEqual(failure?.result?["launchRequested"] as? Bool, false)
            XCTAssertEqual((failure?.result?["execution"] as? [String: Any])?["started"] as? Bool, true)
        }
    }

    func testHomeBindsWholeScreenAndConsumesOldObservation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        _ = try cache.store(observationFixture())
        let action = try DeviceAction(operation: "home", request: ["reference": "o1"])
        let target = try cache.resolveTarget(for: action)
        let guardValue = try XCTUnwrap(target.textGuard)
        XCTAssertEqual(guardValue.regions.map(\.rect), [guardValue.context.screen])
        let fields = try XCTestBackend.actionFields(action, target: target)
        XCTAssertNotNil(fields["screenGuard"])
        XCTAssertNil((fields["target"] as? [String: Any])?["path"])
        let changed = try screenPNG(patches: [(CGRect(x: 0, y: 0, width: 390, height: 150), [0, 0, 0])])
        XCTAssertFalse(try guardValue.check(png: changed, context: guardValue.context).accepted)
        let previous = cache.beginAction(); cache.finishAction(previous: previous, dispatched: true)
        XCTAssertThrowsError(try cache.resolveTarget(for: action))
    }
}

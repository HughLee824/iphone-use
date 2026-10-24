import XCTest
import CoreImage
@testable import IPhoneUseCore

extension NativePreviewTests {

    func testNoVideoFrameTimesOutAndRecoversOnlyWhenAValidFrameArrives() throws {
        try withPreviewReceiver { receiver, send in
            let preview = try NativePreview(port: 0)
            defer { preview.close() }
            let display = try previewDisplay(backlight: "activeOn")
            preview.attach(receiver, display: display)
            let failed = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    preview.status()["state"] as? String == "unavailable"
                }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 4), .completed)
            XCTAssertEqual(
                preview.status()["error"] as? String, "No valid video frame received within 3 seconds")
            preview.attach(receiver, display: display)
            XCTAssertEqual(
                preview.status()["state"] as? String, "unavailable",
                "Polling cannot reset the deadline or error")
            send(1)
            let recovered = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    preview.status()["state"] as? String == "streaming"
                }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [recovered], timeout: 2), .completed)
            receiver.close()
            XCTAssertNotEqual(
                preview.status()["state"] as? String, "streaming",
                "An old JPEG cannot hide a closed transport")
        }
    }

    func testDecodedFrameWithConflictingGeometryIsNotUsablePreview() throws {
        try withPreviewReceiver { receiver, send in
            let preview = try NativePreview(port: 0)
            defer { preview.close() }
            let wrongDisplay = try NativeDisplay([
                "displays": [
                    [
                        "primary": true, "displayId": 1,
                        "bounds": [[0, 0], [100, 100]], "pointScale": 1,
                        "currentOrientation": "rot0", "nativeOrientation": "rot0"
                    ]
                ]
            ])
            preview.attach(receiver, display: wrongDisplay)
            send(1)
            let rejected = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    preview.status()["state"] as? String == "unavailable"
                }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [rejected], timeout: 2), .completed)
            XCTAssertEqual(preview.status()["encodedFrames"] as? Int, 0)
            let url = try XCTUnwrap(URL(string: preview.url + "frame"))
            XCTAssertEqual(try get(url).0, 503)

            preview.attach(receiver, display: try previewDisplay(backlight: "futureState"))
            let recovered = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    preview.status()["state"] as? String == "streaming"
                }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [recovered], timeout: 2), .completed)
            XCTAssertEqual(try get(url).0, 200)
        }
    }

    func testGestureLongPollWakesOnDispatchWithoutWaitingForInputCompletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        _ = try cache.store(observationFixture())
        let action = try DeviceAction(operation: "tap", request: ["reference": "o1", "x": 100, "y": 200])
        let gesture = try XCTUnwrap(
            NativePreviewGesture(action: action, target: cache.resolveTarget(for: action)))
        try withPreviewReceiver { receiver, _ in
            let preview = try NativePreview(port: 0); defer { preview.close() }
            preview.attach(
                receiver,
                display: try NativeDisplay([
                    "backlightState": "activeOn",
                    "displays": [
                        [
                            "primary": true,
                            "displayId": 1, "bounds": [[0, 0], [390, 844]], "pointScale": 1,
                            "currentOrientation": "rot0", "nativeOrientation": "rot0"
                        ]
                    ]
                ]))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { preview.showGesture(gesture) }
            let started = ProcessInfo.processInfo.systemUptime
            let response = try get(try XCTUnwrap(URL(string: preview.url + "gestures?after=0")))
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let result = try jsonObject(response.1)
            XCTAssertEqual(response.0, 200)
            XCTAssertEqual((result["events"] as? [[String: Any]])?.count, 1)
            XCTAssertGreaterThan(elapsed, 0.1, "An idle poll must remain pending until a gesture arrives")
            XCTAssertLessThan(
                elapsed, 0.9, "Dispatch must wake the poll rather than waiting for its one-second timeout")
        }
    }

    func testSuspendedGesturePollRemainsBoundedWithoutBusyRetrying() throws {
        let preview = try NativePreview(port: 0); defer { preview.close() }
        preview.suspend("video unavailable")
        let started = ProcessInfo.processInfo.systemUptime
        let response = try get(try XCTUnwrap(URL(string: preview.url + "gestures?after=0")))
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertEqual(response.0, 200)
        XCTAssertTrue(try XCTUnwrap(jsonObject(response.1)["events"] as? [[String: Any]]).isEmpty)
        XCTAssertGreaterThanOrEqual(
            elapsed, 0.9, "Video errors must not turn gesture renewal into a busy loop")
        XCTAssertLessThan(elapsed, 2, "An idle gesture poll must still expire")
    }

    func testGestureHTTPDeliveryClearsOnRotationAndSuspendWithoutReplayingHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        _ = try cache.store(observationFixture())
        let action = try DeviceAction(operation: "tap", request: ["reference": "o1", "x": 100, "y": 200])
        let gesture = try XCTUnwrap(
            NativePreviewGesture(action: action, target: cache.resolveTarget(for: action)))
        try withPreviewReceiver { receiver, _ in
            let preview = try NativePreview(port: 0); defer { preview.close() }
            func display(_ rotation: String) throws -> NativeDisplay {
                try NativeDisplay([
                    "backlightState": "activeOn",
                    "displays": [
                        [
                            "primary": true, "displayId": 1,
                            "bounds": [[0, 0], [390, 844]], "pointScale": 1, "currentOrientation": rotation,
                            "nativeOrientation": "rot0"
                        ]
                    ]
                ])
            }
            func events(_ query: String = "?after=0") throws -> [[String: Any]] {
                let response = try get(try XCTUnwrap(URL(string: preview.url + "gestures" + query)))
                XCTAssertEqual(response.0, 200)
                let facts = try XCTUnwrap(JSONSerialization.jsonObject(with: response.1) as? [String: Any])
                return try XCTUnwrap(facts["events"] as? [[String: Any]])
            }
            preview.attach(receiver, display: try display("rot0"))
            preview.showGesture(gesture)
            XCTAssertEqual(try events().first?["kind"] as? String, "tap")
            XCTAssertTrue(try events("").isEmpty, "A new viewer must not replay existing events")
            XCTAssertTrue(try events("?after=1").isEmpty, "A delivered event must not repeat")
            preview.attach(receiver, display: try display("rot0"))
            XCTAssertEqual(try events().count, 1, "Refreshing the same binding must preserve live events")
            preview.attach(receiver, display: try display("rot90"))
            preview.showGesture(gesture)
            XCTAssertTrue(
                try events().isEmpty, "Rotation clears old events and rejects late old-direction receipts")
            preview.attach(receiver, display: try display("rot0"))
            preview.showGesture(gesture)
            XCTAssertEqual(try events().count, 1)
            preview.suspend("test suspension")
            preview.showGesture(gesture)
            XCTAssertTrue(try events().isEmpty)
            XCTAssertNil(preview.gestureRotation)
        }
    }

    func testSlowEncodingDoesNotBlockHTTPAndCannotPublishAfterSuspend() throws {
        try withPreviewReceiver { receiver, send in
            let entered = expectation(description: "encoder started"), release = DispatchSemaphore(value: 0)
            let preview = try NativePreview(
                port: 0,
                encodeFrame: { _, _, _ in
                    entered.fulfill(); _ = release.wait(timeout: .now() + 5)
                    return .init(data: Data([0xff, 0xd8, 0xff, 0xd9]))
                })
            defer { release.signal(); preview.close() }
            let display = try NativeDisplay([
                "backlightState": "activeOn",
                "displays": [
                    [
                        "primary": true, "displayId": 1,
                        "bounds": [[0, 0], [12, 18]], "pointScale": 1, "currentOrientation": "rot0",
                        "nativeOrientation": "rot0"
                    ]
                ]
            ])
            preview.attach(receiver, display: display)
            send(1)
            wait(for: [entered], timeout: 2)
            let started = ProcessInfo.processInfo.systemUptime
            let response = try get(try XCTUnwrap(URL(string: preview.url + "state")))
            XCTAssertEqual(response.0, 200)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5)
            preview.suspend("rotation changed")
            release.signal()
            let finished = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    preview.status()["encodingInFlight"] as? Bool == false
                }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 2), .completed)
            XCTAssertEqual(
                preview.status()["encodedFrames"] as? Int, 0, "Old binding pixels must not be published")
        }
    }
}

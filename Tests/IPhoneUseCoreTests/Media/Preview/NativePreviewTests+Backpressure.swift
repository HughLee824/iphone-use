import XCTest
import CoreImage
@testable import IPhoneUseCore

extension NativePreviewTests {

    func testFreshEncodingBypassesSlowFrameAndLateResultCannotReplaceIt() throws {
        try withPreviewReceiver { receiver, send in
            let entered = expectation(description: "slow encoder started"),
                release = DispatchSemaphore(value: 0)
            let preview = try NativePreview(
                port: 0,
                encodeFrame: { frame, _, _ in
                    if frame.timestamp == 1 { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
                    return .init(data: Data([0xff, 0xd8, UInt8(frame.timestamp), 0xff, 0xd9]))
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
            preview.attach(receiver, display: display); send(1)
            wait(for: [entered], timeout: 2)
            send(2)
            let published = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    preview.status()["encodedFrames"] as? Int == 1
                }, object: nil)
            XCTAssertEqual(
                XCTWaiter.wait(for: [published], timeout: 2), .completed,
                "Fresh output must not wait for the slow slot"
            )
            XCTAssertEqual(preview.status()["inFlightEncodes"] as? Int, 1)
            release.signal()
            let finished = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    preview.status()["encodingInFlight"] as? Bool == false
                }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 2), .completed)
            XCTAssertEqual(preview.status()["encodedFrames"] as? Int, 1)
            XCTAssertEqual(preview.status()["discardedEncodes"] as? Int, 1)
            let response = try get(try XCTUnwrap(URL(string: preview.url + "frame")))
            XCTAssertEqual(response.0, 200)
            XCTAssertEqual(response.1, Data([0xff, 0xd8, 2, 0xff, 0xd9]))
        }
    }
}

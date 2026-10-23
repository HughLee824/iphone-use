import XCTest
import CoreGraphics
import AppleNativeBridge
import Darwin
@testable import IPhoneUseCore

extension AppleNativeTests {

    func testRecordingRefreshReplacesOnlyOwnedStreamWithUnchangedGeometry() throws {
        let transport = ScriptedTransport(); mediaScript(transport)
        var receivers: [MediaReceiver] = []
        let binding = NativeDisplayMediaSession(
            makeSession: {
                let receiver = MediaReceiver(); receivers.append(receiver)
                return self.media(transport, receiver)
            },
            startSession: { session, display in
                try session.start(displayID: display.id, deviceAddress: "::1", offer: Data()) { _ in }
            })
        let display = try boundDisplay("rot90")
        try binding.ensureDisplay(display, mayReplace: true)
        let initial = binding.health()["mediaSessionID"] as? String
        XCTAssertThrowsError(try binding.refreshForRecording(boundDisplay("rot270"), mayReplace: true))
        XCTAssertEqual(receivers.count, 1)
        try binding.refreshForRecording(display, mayReplace: true)
        XCTAssertEqual(receivers.map(\.closes), [1, 0])
        XCTAssertNotEqual(binding.health()["mediaSessionID"] as? String, initial)
        XCTAssertEqual(binding.health()["recordingRefreshCount"] as? Int, 1)
        XCTAssertEqual(binding.health()["displayRefreshCount"] as? Int, 0)
        XCTAssertTrue(binding.matchesDisplay(display))
        let stops = transport.requests.filter {
            ($0["CoreDevice.featureIdentifier"] as? String)?.hasSuffix("stopmediastream") == true
        }
        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual((stops[0]["CoreDevice.input"] as? [String: Any])?["stopAll"] as? Bool, false)
        try binding.ensureDisplay(display, mayReplace: true)
        XCTAssertEqual(receivers.count, 2)
        let requestCount = transport.requests.count
        XCTAssertThrowsError(try binding.refreshForRecording(display, mayReplace: false))
        XCTAssertEqual(transport.requests.count, requestCount)
        XCTAssertEqual(binding.close()["mediaStopAcknowledged"] as? Bool, true)
    }

    func testRecordingRefreshDoesNotRetryUnconfirmedStop() throws {
        let transport = ScriptedTransport(); mediaScript(transport)
        var made = 0
        let binding = NativeDisplayMediaSession(
            makeSession: {
                made += 1; return self.media(transport, MediaReceiver())
            },
            startSession: { session, display in
                try session.start(displayID: display.id, deviceAddress: "::1", offer: Data()) { _ in }
            })
        let display = try boundDisplay("rot270")
        try binding.ensureDisplay(display, mayReplace: true)
        let original = transport.onRequest!
        transport.onRequest = { request in
            if (request["CoreDevice.featureIdentifier"] as? String)?.hasSuffix("stopmediastream") == true {
                throw TransportError(description: "lost stop reply", possiblySent: true)
            }
            return try original(request)
        }
        XCTAssertThrowsError(try binding.refreshForRecording(display, mayReplace: true))
        let count = transport.requests.count
        XCTAssertThrowsError(try binding.refreshForRecording(display, mayReplace: true))
        XCTAssertEqual(transport.requests.count, count); XCTAssertEqual(made, 1)
        XCTAssertFalse((try XCTUnwrap(binding.health()["healthy"] as? Bool)))
        XCTAssertEqual(binding.close()["mediaStopAcknowledged"] as? Bool, false)
    }

    func testDisplayMediaUnconfirmedStopLatchesWithoutReplacementOrRetry() throws {
        let transport = ScriptedTransport(); mediaScript(transport)
        var made = 0
        let binding = NativeDisplayMediaSession(
            makeSession: {
                made += 1; return self.media(transport, MediaReceiver())
            },
            startSession: { session, display in
                try session.start(displayID: display.id, deviceAddress: "::1", offer: Data()) { _ in }
            })
        try binding.ensureDisplay(boundDisplay("rot90"), mayReplace: true)
        let original = transport.onRequest!
        transport.onRequest = { request in
            if (request["CoreDevice.featureIdentifier"] as? String)?.hasSuffix("stopmediastream") == true {
                throw TransportError(description: "lost stop reply", possiblySent: true)
            }
            return try original(request)
        }
        XCTAssertThrowsError(try binding.ensureDisplay(boundDisplay("rot270"), mayReplace: true))
        let count = transport.requests.count
        XCTAssertThrowsError(try binding.ensureDisplay(boundDisplay("rot270"), mayReplace: true))
        XCTAssertThrowsError(try binding.ensureDisplay(boundDisplay("rot90"), mayReplace: true))
        XCTAssertEqual(binding.close()["mediaStopAcknowledged"] as? Bool, false)
        XCTAssertEqual(transport.requests.count, count); XCTAssertEqual(made, 1)
        let state = NativeControlStatus.resolve(
            hid: .ready, media: binding.health(), closing: false, startupCode: nil, startupError: nil)
        XCTAssertFalse(state.available); XCTAssertEqual(state.recovery, .reconnectAndObserve)
        XCTAssertEqual(state.code, "native_media_display_refresh_failed")
    }

    func testDisplayMediaFailedReplacementCleansNewOwnershipAndNeverRetries() throws {
        let transport = ScriptedTransport(); mediaScript(transport)
        var receivers: [MediaReceiver] = [], starts = 0
        let binding = NativeDisplayMediaSession(
            makeSession: {
                let receiver = MediaReceiver(); receivers.append(receiver)
                return self.media(transport, receiver)
            },
            startSession: { session, display in
                try session.start(displayID: display.id, deviceAddress: "::1", offer: Data()) { _ in }
                starts += 1
                if starts == 2 {
                    throw IPhoneUseError("native_cancelled", "cancelled during replacement health wait")
                }
            })
        try binding.ensureDisplay(boundDisplay("rot90"), mayReplace: true)
        XCTAssertThrowsError(try binding.ensureDisplay(boundDisplay("rot270"), mayReplace: true))
        XCTAssertFalse((try XCTUnwrap(binding.health()["healthy"] as? Bool)))
        XCTAssertEqual(receivers.map(\.closes), [1, 1])
        let count = transport.requests.count
        XCTAssertThrowsError(try binding.ensureDisplay(boundDisplay("rot270"), mayReplace: true))
        XCTAssertEqual(binding.close()["mediaStopAcknowledged"] as? Bool, true)
        XCTAssertEqual(transport.requests.count, count); XCTAssertEqual(starts, 2)
    }

    func testDisplayMediaDoesNotReplaceWhileInputStateIsUncertain() throws {
        let transport = ScriptedTransport(), receiver = MediaReceiver(); mediaScript(transport)
        let binding = NativeDisplayMediaSession(
            makeSession: { self.media(transport, receiver) },
            startSession: { session, display in
                try session.start(displayID: display.id, deviceAddress: "::1", offer: Data()) { _ in }
            })
        try binding.ensureDisplay(boundDisplay("rot90"), mayReplace: true)
        let count = transport.requests.count
        XCTAssertThrowsError(try binding.ensureDisplay(boundDisplay("rot270"), mayReplace: false))
        XCTAssertEqual(transport.requests.count, count); XCTAssertEqual(receiver.closes, 0)
        XCTAssertEqual(binding.close()["mediaStopAcknowledged"] as? Bool, true)
    }

    func testDisplayMediaReplacementRefusesAClientArrivingAfterOwnedStop() throws {
        let transport = ScriptedTransport(); mediaScript(transport)
        var made = 0
        let binding = NativeDisplayMediaSession(
            makeSession: {
                made += 1
                if made == 2 {
                    // A different client races into the gap after confirmed owned cleanup.
                    let original = transport.onRequest!
                    transport.onRequest = { request in
                        if (request["CoreDevice.featureIdentifier"] as? String)?.hasSuffix(
                            "getmediastreamserverstatus")
                            == true {
                            return ["CoreDevice.output": ["sessions": [["foreign": true]]]]
                        }
                        return try original(request)
                    }
                }
                return self.media(transport, MediaReceiver())
            },
            startSession: { session, display in
                try session.start(displayID: display.id, deviceAddress: "::1", offer: Data()) { _ in }
            })
        try binding.ensureDisplay(boundDisplay("rot90"), mayReplace: true)
        XCTAssertThrowsError(try binding.ensureDisplay(boundDisplay("rot270"), mayReplace: true)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "native_media_busy")
        }
        let count = transport.requests.count
        XCTAssertThrowsError(try binding.ensureDisplay(boundDisplay("rot270"), mayReplace: true))
        XCTAssertEqual(binding.close()["mediaStopAcknowledged"] as? Bool, true)
        XCTAssertEqual(transport.requests.count, count)
        XCTAssertEqual(
            transport.requests.filter {
                ($0["CoreDevice.featureIdentifier"] as? String)?.hasSuffix("startmediastream") == true
            }.count, 1)
        XCTAssertEqual(
            transport.requests.filter {
                ($0["CoreDevice.featureIdentifier"] as? String)?.hasSuffix("stopmediastream") == true
            }.count, 1)
    }
    func testNativeDisplayRotatesNativeBoundsIntoUnmodifiedScreenshotGeometry() throws {
        for (rotation, width, height, orientation) in [
            ("rot0", 1170, 2532, 1), ("rot90", 2532, 1170, 4), ("rot270", 2532, 1170, 3)
        ] {
            let display = try NativeDisplay([
                "backlightState": "activeOn",
                "displays": [
                    [
                        "primary": true, "displayId": 1,
                        "bounds": [[0, 0], [1170, 2532]], "pointScale": 3, "currentOrientation": rotation,
                        "nativeOrientation": "rot0"
                    ]
                ]
            ])
            XCTAssertEqual(display.pixelWidth, Double(width))
            XCTAssertEqual(display.pixelHeight, Double(height))
            XCTAssertEqual(display.screen.width, Double(width) / 3)
            XCTAssertEqual(display.screen.height, Double(height) / 3)
            XCTAssertEqual(display.context.orientation, orientation)
        }
        XCTAssertThrowsError(
            try NativeDisplay([
                "displays": [
                    [
                        "primary": true, "displayId": 1,
                        "bounds": [[0, 0], [1170, 2532]], "pointScale": 3, "currentOrientation": "rot90",
                        "nativeOrientation": "unknown"
                    ]
                ]
            ]))
    }
}

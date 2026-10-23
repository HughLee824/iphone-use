import XCTest
import CoreGraphics
import AppleNativeBridge
import Darwin
@testable import IPhoneUseCore

extension AppleNativeTests {

    func testMediaClosePreservesAClientThatStartedLater() throws {
        let transport = ScriptedTransport(), receiver = MediaReceiver()
        mediaScript(transport)
        let session = media(transport, receiver)
        try session.start(displayID: 1, deviceAddress: "::1", offer: Data()) { _ in }
        let original = transport.onRequest!
        let foreign: [String: Any] = [
            "connection": [
                "options": ["avcMediaStreamOptionClientSessionID": ["uuid": UUID()]],
                "streamConfig": ["RemoteSSRC": UInt32(888)]
            ]
        ]
        transport.onRequest = { request in
            var reply = try original(request)
            if (request["CoreDevice.featureIdentifier"] as? String)?.hasSuffix("getmediastreamserverstatus")
                == true {
                var output = (try XCTUnwrap(reply["CoreDevice.output"] as? [String: Any]))
                output["sessions"] = ((try XCTUnwrap(output["sessions"] as? [Any]))) + [foreign]
                reply["CoreDevice.output"] = output
            }
            return reply
        }
        XCTAssertEqual(session.close()["mediaStopAcknowledged"] as? Bool, true)
        let stop = try XCTUnwrap(
            transport.requests.first {
                ($0["CoreDevice.featureIdentifier"] as? String)?.hasSuffix("stopmediastream") == true
            })
        let input = (try XCTUnwrap(stop["CoreDevice.input"] as? [String: Any]))
        XCTAssertEqual((input["identifiers"] as? [ASNativeUnsigned])?.map(\.value), [123456])
        XCTAssertEqual(input["stopAll"] as? Bool, false)
    }

    func testMediaCloseRefusesChangedStreamIdentifier() throws {
        let transport = ScriptedTransport(), receiver = MediaReceiver()
        mediaScript(transport)
        let session = media(transport, receiver)
        try session.start(displayID: 1, deviceAddress: "::1", offer: Data()) { _ in }
        transport.onRequest = { request in
            XCTAssertTrue(
                (request["CoreDevice.featureIdentifier"] as? String)?.hasSuffix("getmediastreamserverstatus")
                    == true)
            return [
                "CoreDevice.output": [
                    "sessions": [
                        [
                            "connection": [
                                "options": [
                                    "avcMediaStreamOptionClientSessionID": ["uuid": session.sessionID]
                                ],
                                "streamConfig": ["RemoteSSRC": UInt32(777)]
                            ]
                        ]
                    ]
                ]
            ]
        }
        XCTAssertEqual(session.close()["mediaStopAcknowledged"] as? Bool, false)
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testNativeDisplayUsesObservedScaleAndRejectsUnknownGeometry() throws {
        let display = try NativeDisplay([
            "backlightState": "activeOn",
            "displays": [
                [
                    "primary": true, "displayId": 9,
                    "bounds": [[0, 0], [1200, 2400]], "pointScale": 4.0, "currentOrientation": "rot0",
                    "nativeOrientation": "rot0"
                ]
            ]
        ])
        XCTAssertEqual(display.screen.width, 300); XCTAssertEqual(display.screen.height, 600)
        XCTAssertTrue(display.backlightOn)
        XCTAssertThrowsError(try NativeDisplay(["displays": []]))
    }

    func testNativeDisplayAcceptsDimmedBacklightButRejectsInactiveAndUnknownStates() throws {
        let active = try boundDisplay("rot0")
        let dimmed = try boundDisplay("rot0", backlight: "activeDimmed")
        XCTAssertTrue(dimmed.backlightOn)
        XCTAssertEqual(dimmed, active, "Dimming must not invalidate unchanged display geometry")
        for state in ["off", "inactive", "unknown", ""] {
            XCTAssertFalse(try boundDisplay("rot0", backlight: state).backlightOn, state)
        }
    }

    func testDisplayMediaRebindStopsOwnedStreamBeforeStartingWithNewIdentity() throws {
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
        try binding.ensureDisplay(boundDisplay("rot90"), mayReplace: true)
        let initial = binding.health()["mediaSessionID"] as? String
        try binding.ensureDisplay(boundDisplay("rot90"), mayReplace: true)
        // Backlight alone is not a coordinate change. Capture separately refuses dark screens.
        try binding.ensureDisplay(boundDisplay("rot90", backlight: "inactive"), mayReplace: true)
        XCTAssertEqual(receivers.count, 1)
        try binding.ensureDisplay(boundDisplay("rot270"), mayReplace: true)
        XCTAssertEqual(receivers.count, 2); XCTAssertEqual(receivers[0].closes, 1)
        XCTAssertNotEqual(binding.health()["mediaSessionID"] as? String, initial)
        XCTAssertEqual(binding.health()["displayRefreshCount"] as? Int, 1)
        XCTAssertEqual(binding.health()["boundDisplayRotation"] as? String, "rot270")
        let features = transport.requests.compactMap {
            ($0["CoreDevice.featureIdentifier"] as? String)?.components(separatedBy: ".").last
        }
        XCTAssertEqual(
            features,
            [
                "getmediastreamserverstatus", "startmediastream", "getmediastreamserverstatus",
                "stopmediastream", "getmediastreamserverstatus", "getmediastreamserverstatus",
                "startmediastream"
            ])
        let stop = (try XCTUnwrap(transport.requests[3]["CoreDevice.input"] as? [String: Any]))
        XCTAssertEqual(stop["stopAll"] as? Bool, false)
        XCTAssertEqual((stop["identifiers"] as? [ASNativeUnsigned])?.map(\.value), [123456])
        // Geometry/scale changes also invalidate the media binding, not just PNG dimensions.
        try binding.ensureDisplay(boundDisplay("rot270", scale: 2), mayReplace: true)
        XCTAssertEqual(binding.health()["displayRefreshCount"] as? Int, 2)
        XCTAssertEqual(binding.close()["mediaStopAcknowledged"] as? Bool, true)
        _ = binding.close()
        XCTAssertEqual(receivers.map(\.closes), [1, 1, 1])
        XCTAssertThrowsError(try binding.ensureDisplay(boundDisplay("rot0"), mayReplace: true))
    }

    func testOrientationResyncReadsOnlyAfterOwnedStopAndStartsAtFreshDirection() throws {
        let transport = ScriptedTransport(); mediaScript(transport)
        var receivers: [MediaReceiver] = [], rotations: [String] = []
        let binding = NativeDisplayMediaSession(
            makeSession: {
                let receiver = MediaReceiver(); receivers.append(receiver)
                return self.media(transport, receiver)
            },
            startSession: { session, display in
                rotations.append(display.rotation)
                try session.start(displayID: display.id, deviceAddress: "::1", offer: Data()) { _ in }
            })
        try binding.ensureDisplay(boundDisplay("rot90"), mayReplace: true)
        let old = binding.health()["mediaSessionID"] as? String
        let geometryChanged = try binding.resynchronizeOrientation(
            mayReplace: true,
            readDisplay: {
                XCTAssertEqual(receivers.map(\.closes), [1])
                let features = transport.requests.compactMap { $0["CoreDevice.featureIdentifier"] as? String }
                XCTAssertTrue(features.contains { $0.hasSuffix("stopmediastream") })
                XCTAssertEqual(features.filter { $0.hasSuffix("startmediastream") }.count, 1)
                return try self.boundDisplay("rot270", backlight: "futureState")
            })
        XCTAssertTrue(geometryChanged)
        XCTAssertEqual(rotations, ["rot90", "rot270"])
        XCTAssertNotEqual(binding.health()["mediaSessionID"] as? String, old)
        XCTAssertEqual(binding.health()["orientationRefreshCount"] as? Int, 1)
        XCTAssertEqual(binding.health()["boundDisplayRotation"] as? String, "rot270")
        XCTAssertFalse(
            try binding.resynchronizeOrientation(
                mayReplace: true, readDisplay: { try self.boundDisplay("rot270", backlight: "off") })
        )
        XCTAssertEqual(binding.close()["mediaStopAcknowledged"] as? Bool, true)
    }

    func testOrientationResyncFailureDoesNotRetryOrStartAtStaleGeometry() throws {
        for failure in ["stop", "read", "input"] {
            let transport = ScriptedTransport(); mediaScript(transport)
            var starts = 0, reads = 0
            let binding = NativeDisplayMediaSession(
                makeSession: { self.media(transport, MediaReceiver()) },
                startSession: { session, display in
                    starts += 1
                    try session.start(displayID: display.id, deviceAddress: "::1", offer: Data()) { _ in }
                })
            try binding.ensureDisplay(boundDisplay("rot90"), mayReplace: true)
            let original = transport.onRequest!
            transport.onRequest = { request in
                if failure == "stop",
                    (request["CoreDevice.featureIdentifier"] as? String)?.hasSuffix("stopmediastream") == true {
                    throw TransportError(description: "lost reply", possiblySent: true)
                }
                return try original(request)
            }
            let recover = {
                try binding.resynchronizeOrientation(
                    mayReplace: failure != "input",
                    readDisplay: {
                        reads += 1
                        throw IPhoneUseError("native_cancelled", "cancelled after stop")
                    })
            }
            XCTAssertThrowsError(try recover())
            let count = transport.requests.count
            XCTAssertThrowsError(try recover())
            XCTAssertEqual(transport.requests.count, count)
            XCTAssertEqual(starts, 1)
            XCTAssertEqual(reads, failure == "read" ? 1 : 0)
            XCTAssertEqual(binding.close()["mediaStopAcknowledged"] as? Bool, failure != "stop")
        }
    }
}

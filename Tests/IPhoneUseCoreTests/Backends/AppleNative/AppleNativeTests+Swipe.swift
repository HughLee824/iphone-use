import XCTest
import CoreGraphics
import AppleNativeBridge
import Darwin
@testable import IPhoneUseCore

extension AppleNativeTests {
    func testSwipeInterruptedAfterMovesKeepsReleaseAndClosedChannelFactsSeparate() throws {
        let plan = try swipePlan()
        for closeChannel in [false, true] {
            let channel = TouchChannel(), cancellation = NativeCancellation()
            let transport = AppleServiceTransport(channel: channel)
            var now = 0.0, injected = false
            let hid = NativeHIDAdapter(
                transport: transport, cancellation: cancellation,
                wait: {
                    now += $0
                    if channel.reports.count >= 5 && !injected {
                        injected = true
                        if closeChannel { transport.cancel() } else { cancellation.cancel() }
                    }
                }, uptime: { now })
            try hid.prepare()
            XCTAssertThrowsError(try hid.swipe(plan)) {
                let failure = $0 as? ActionFailure
                XCTAssertEqual(failure?.possiblyExecuted, true)
                let cleanup = failure?.result?["cleanup"] as? [String: Any]
                XCTAssertEqual(cleanup?["releaseQueued"] as? Bool, !closeChannel)
                XCTAssertEqual(cleanup?["releaseUncertain"] as? Bool, closeChannel)
                XCTAssertEqual(failure?.result?["moveReportsQueued"] as? Int, 4)
            }
            XCTAssertTrue(injected)
            XCTAssertEqual(channel.reports.count, closeChannel ? 5 : 6)
            XCTAssertNotEqual(point(channel.reports[0]), point(channel.reports[4]))
            if !closeChannel {
                XCTAssertEqual(channel.reports.last?[3], 2)
                XCTAssertEqual(point(channel.reports[4]), point(channel.reports[5]))
            }
            XCTAssertFalse(hid.isAvailable)
            XCTAssertThrowsError(try hid.swipe(plan))
            _ = hid.release()
            XCTAssertEqual(channel.reports.count, closeChannel ? 5 : 6)
        }
    }
    func testCancelDuringContactStillReleasesWithoutReplay() throws {
        let transport = ScriptedTransport(), cancel = NativeCancellation()
        let hid = NativeHIDAdapter(transport: transport, cancellation: cancel, wait: { _ in cancel.cancel() })
        try hid.prepare()
        XCTAssertThrowsError(try hid.tap((1, 2))) {
            XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true)
        }
        XCTAssertEqual(reports(transport).map { $0[3] }, [0xc2, 2])
        XCTAssertThrowsError(try hid.tap((1, 2)))
        XCTAssertEqual(transport.sends.count, 2)
    }
    func testCancellationAfterContactKeepsTransportOpenForOneRelease() throws {
        let channel = TouchChannel(), cancellation = NativeCancellation()
        let transport = AppleServiceTransport(channel: channel)
        let hid = NativeHIDAdapter(
            transport: transport, cancellation: cancellation,
            wait: { _ in
                XCTAssertEqual(channel.reports.map { $0[3] }, [0xc2])
                cancellation.cancel()
            })
        try hid.prepare()
        XCTAssertTrue(hid.isAvailable)
        XCTAssertThrowsError(try hid.tap((123, 456))) {
            let failure = $0 as? ActionFailure
            XCTAssertEqual(failure?.possiblyExecuted, true)
            XCTAssertEqual(failure?.requiresObservation, true)
            let cleanup = failure?.result?["cleanup"] as? [String: Any]
            XCTAssertEqual(cleanup?["releaseQueued"] as? Bool, true)
            XCTAssertEqual(cleanup?["releaseUncertain"] as? Bool, false)
        }
        XCTAssertEqual(channel.reports.map { $0[3] }, [0xc2, 2])
        XCTAssertFalse(hid.isAvailable)
        XCTAssertEqual(hid.state, .inputUncertain)
        XCTAssertEqual(channel.cancellations, 0)
        XCTAssertThrowsError(try hid.tap((123, 456)))
        _ = hid.release()
        XCTAssertEqual(channel.reports.count, 2)
        transport.cancel()
        XCTAssertEqual(channel.cancellations, 1)
    }
    func testConnectionClosedAfterContactCannotClaimReleaseOrSendAgain() throws {
        let channel = TouchChannel()
        let transport = AppleServiceTransport(channel: channel)
        let hid = NativeHIDAdapter(
            transport: transport, cancellation: NativeCancellation(),
            wait: { _ in
                transport.cancel()
            })
        try hid.prepare()
        XCTAssertTrue(hid.isAvailable)
        XCTAssertThrowsError(try hid.tap((123, 456), hold: 0.01)) {
            let failure = $0 as? ActionFailure
            XCTAssertEqual(failure?.possiblyExecuted, true)
            let cleanup = failure?.result?["cleanup"] as? [String: Any]
            XCTAssertEqual(cleanup?["releaseQueued"] as? Bool, false)
            XCTAssertEqual(cleanup?["releaseUncertain"] as? Bool, true)
        }
        XCTAssertEqual(channel.reports.map { $0[3] }, [0xc2])
        XCTAssertTrue(hid.releaseUncertain)
        XCTAssertFalse(hid.isAvailable)
        XCTAssertEqual(hid.state, .releaseUncertain)
        XCTAssertThrowsError(try hid.tap((123, 456)))
        XCTAssertEqual(hid.release()["releaseUncertain"] as? Bool, true)
        XCTAssertEqual(channel.reports.count, 1)
        XCTAssertEqual(channel.cancellations, 1)
    }
    func testLostContactSendAttemptsReleaseAndMarksUnknown() throws {
        let transport = ScriptedTransport()
        transport.onSend = { _ in throw TransportError(description: "disconnected", possiblySent: true) }
        let hid = NativeHIDAdapter(transport: transport, cancellation: NativeCancellation())
        try hid.prepare()
        XCTAssertThrowsError(try hid.tap((1, 2))) {
            XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true)
        }
        XCTAssertEqual(reports(transport).map { $0[3] }, [0xc2, 2])
        XCTAssertTrue(hid.releaseUncertain)
        XCTAssertThrowsError(try hid.tap((1, 2)))
        XCTAssertEqual(transport.sends.count, 2)
    }
    func testUnsupportedSurfaceCannotInject() throws {
        let transport = ScriptedTransport()
        transport.onRequest = { _ in
            ["connectedServices": [["PrimaryUsagePage": 1, "PrimaryUsage": 6, "_ServiceID": 257]]]
        }
        let hid = NativeHIDAdapter(transport: transport, cancellation: NativeCancellation())
        XCTAssertThrowsError(try hid.prepare())
        XCTAssertThrowsError(try hid.tap((1, 2)))
        XCTAssertTrue(transport.sends.isEmpty)
    }
    func testMediaStopsOnlyItsOwnSessionAndRequiresConfirmation() throws {
        let transport = ScriptedTransport(), receiver = MediaReceiver()
        mediaScript(transport)
        let session = media(transport, receiver)
        try session.start(displayID: 7, deviceAddress: "::1", offer: Data([0])) {
            XCTAssertEqual($0, Data([1]))
        }
        XCTAssertTrue(receiver.configured)
        let result = session.close()
        XCTAssertEqual(result["mediaStopAcknowledged"] as? Bool, true)
        XCTAssertEqual(receiver.closes, 1)
        _ = session.close()
        XCTAssertEqual(receiver.closes, 1)
        let stops = transport.requests.filter {
            ($0["CoreDevice.featureIdentifier"] as? String)?.hasSuffix("stopmediastream") == true
        }
        XCTAssertEqual(stops.count, 1)
        let input = try XCTUnwrap(stops.first?["CoreDevice.input"] as? [String: Any])
        XCTAssertEqual(input["stopAll"] as? Bool, false)
        XCTAssertEqual((input["identifiers"] as? [ASNativeUnsigned])?.map(\.value), [123456])
        XCTAssertNil(input["avcMediaStreamOptionClientSessionID"])
        XCTAssertEqual(transport.requests.count, 5) // status, start, verify UUID ownership, scoped stop, status.
    }
    func testMediaRefusesOtherClientsWithoutStoppingThem() throws {
        let transport = ScriptedTransport(), receiver = MediaReceiver()
        mediaScript(transport, sessions: ["another-client"])
        let session = media(transport, receiver)
        XCTAssertThrowsError(try session.start(displayID: 1, deviceAddress: "::1", offer: Data()) { _ in })
        XCTAssertEqual(session.close()["mediaStopAcknowledged"] as? Bool, true)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(receiver.closes, 1)
    }
    func testUnknownMediaStartAndEOFNeverCountAsStopped() throws {
        let transport = ScriptedTransport(), receiver = MediaReceiver()
        var failed = false
        transport.onRequest = { request in
            if !failed
                && (request["CoreDevice.featureIdentifier"] as? String)?.hasSuffix(
                    "getmediastreamserverstatus") == true {
                return ["CoreDevice.output": ["sessions": [], "running": false]]
            }
            failed = true; throw TransportError(description: "EOF", possiblySent: true)
        }
        let session = media(transport, receiver)
        XCTAssertThrowsError(try session.start(displayID: 1, deviceAddress: "::1", offer: Data()) { _ in })
        XCTAssertEqual(session.close()["mediaStopAcknowledged"] as? Bool, false)
        XCTAssertEqual(transport.requests.count, 3) // No replay or guessed stop after ownership query fails.
        XCTAssertEqual(receiver.closes, 1)
    }
    func testMediaMismatchedOwnershipCleansOnlyRequestedUUID() throws {
        let transport = ScriptedTransport(), receiver = MediaReceiver()
        mediaScript(transport)
        let previous = transport.onRequest!
        transport.onRequest = { request in
            if (request["CoreDevice.featureIdentifier"] as? String)?.hasSuffix("startmediastream") == true {
                return [
                    "CoreDevice.output": [
                        "connection": [
                            "options": ["avcMediaStreamOptionClientSessionID": ["uuid": UUID()]],
                            "streamConfig": [:]
                        ], "negotiatorAnswer": Data()
                    ]
                ]
            }
            return try previous(request)
        }
        let session = media(transport, receiver)
        XCTAssertThrowsError(try session.start(displayID: 1, deviceAddress: "::1", offer: Data()) { _ in })
        XCTAssertFalse(receiver.configured)
        XCTAssertFalse(
            transport.requests.contains {
                ($0["CoreDevice.featureIdentifier"] as? String)?.hasSuffix("stopmediastream") == true
            })
        // Successful inventory confirms our UUID absent.
        XCTAssertEqual(session.close()["mediaStopAcknowledged"] as? Bool, true)
    }
}

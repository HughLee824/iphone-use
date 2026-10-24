@testable import IPhoneUseRunnerSupport
import XCTest
import CoreGraphics
import AppleNativeBridge
import Darwin
@testable import IPhoneUseCore

extension AppleNativeTests {

    func testReportLayoutUsesExplicitMachTicksAnd48BitTruncation() {
        let report = NativeTouchReport.make(
            contact: true, x: 0x1234, y: 0xabcd, timestamp: 0xffff010203040506)
        XCTAssertEqual(report.count, 58)
        XCTAssertEqual(Array(report.prefix(8)), [9, 1, 5, 0xc2, 0x34, 0x12, 0xcd, 0xab])
        XCTAssertEqual(Array(report[40..<50]), [2, 0, 0, 0, 6, 5, 4, 3, 2, 1])
        XCTAssertEqual(NativeTouchReport.make(contact: false, x: 0, y: 0, timestamp: 0)[3], 2)
    }

    func testCoordinatesBoundsAndRotation() throws {
        let screen = ScreenRect(CGRect(x: 0, y: 0, width: 390, height: 844))
        let center = try NativeCoordinateMapper.map(CGPoint(x: 195, y: 422), screen: screen, rotation: "rot0")
        XCTAssertEqual(center.0, 32768); XCTAssertEqual(center.1, 32768)
        let edge = try NativeCoordinateMapper.map(CGPoint(x: 390, y: 844), screen: screen, rotation: "rot0")
        XCTAssertEqual(edge.0, 65535); XCTAssertEqual(edge.1, 65535)
        let rotated = try NativeCoordinateMapper.map(.zero, screen: screen, rotation: "rot90")
        XCTAssertEqual(rotated.0, 0); XCTAssertEqual(rotated.1, 65535)
        XCTAssertThrowsError(
            try NativeCoordinateMapper.map(CGPoint(x: -1, y: 0), screen: screen, rotation: "rot0"))
        XCTAssertThrowsError(
            try NativeCoordinateMapper.map(CGPoint(x: Double.nan, y: 0), screen: screen, rotation: "rot0"))
    }

    func testLandscapeCornersAndAsymmetricPointUseNativeTouchAxes() throws {
        let screen = ScreenRect(CGRect(x: 0, y: 0, width: 844, height: 390))
        let points = [
            CGPoint(x: 0, y: 0), CGPoint(x: 844, y: 0), CGPoint(x: 0, y: 390), CGPoint(x: 844, y: 390),
            CGPoint(x: 211, y: 292.5)
        ]
        let expected: [String: [[UInt16]]] = [
            "rot90": [[0, 65535], [0, 0], [65535, 65535], [65535, 0], [49151, 49151]],
            "rot270": [[65535, 0], [65535, 65535], [0, 0], [0, 65535], [16384, 16384]]
        ]
        for rotation in ["rot90", "rot270"] {
            for (index, point) in points.enumerated() {
                let mapped = try NativeCoordinateMapper.map(point, screen: screen, rotation: rotation)
                XCTAssertEqual([mapped.0, mapped.1], expected[rotation]![index])
            }
            XCTAssertThrowsError(
                try NativeCoordinateMapper.map(CGPoint(x: 845, y: 100), screen: screen, rotation: rotation))
        }
    }

    func testLandscapeSwipeMapsBothEndpointsWithoutChangingPixelSpeed() throws {
        let screen = ScreenRect(CGRect(x: 0, y: 0, width: 844, height: 390))
        let context = ScreenContext(screen: screen, scope: screen, orientation: 3, keyboardCount: 0)
        let start = CGPoint(x: 211, y: 97.5), end = CGPoint(x: 633, y: 292.5)
        let guardValue = try ScreenGuard(
            png: screenPNG(width: 2532, height: 1170), context: context,
            rects: CoordinateGesture.actionRegions(start: start, end: end, screen: screen.cgRect),
            policy: .init())
        let gesture = CoordinateGesture(
            start: start, end: end, screenGuard: guardValue, motion: SwipeMotion(velocity: 600))
        let left = try NativeSwipePlan(gesture: gesture, rotation: "rot90")
        let right = try NativeSwipePlan(gesture: gesture, rotation: "rot270")
        XCTAssertEqual([left.start.0, left.start.1], [16384, 49151])
        XCTAssertEqual([left.end.0, left.end.1], [49151, 16384])
        XCTAssertEqual([right.start.0, right.start.1], [49151, 16384])
        XCTAssertEqual([right.end.0, right.end.1], [16384, 49151])
        XCTAssertEqual(left.movementDuration, hypot(1266, 585) / 600, accuracy: 0.00001)
        XCTAssertEqual(left.movementDuration, right.movementDuration)
        XCTAssertEqual(left.point(at: 0.5).0, 32768)
        XCTAssertEqual(left.point(at: 0.5).1, 32768)
    }
    func testTapDiscoversSurfaceAndSendsSingleContactRelease() throws {
        let transport = ScriptedTransport(), cancel = NativeCancellation()
        let hid = NativeHIDAdapter(transport: transport, cancellation: cancel, clock: { 12345 })
        try hid.prepare()
        var contacts = 0
        let result = try hid.tap(
            (12, 34), hold: 0.01,
            onContact: {
                contacts += 1; XCTAssertEqual(self.reports(transport).map { $0[3] }, [0xc2])
            })
        XCTAssertEqual(contacts, 1)
        XCTAssertEqual(result["transportStatus"] as? String, "sent")
        XCTAssertEqual(reports(transport).map { $0[3] }, [0xc2, 2])
        let payload =
            (try XCTUnwrap(
                ((try XCTUnwrap(transport.sends[0]["payload"] as? [String: Any])))["send"] as? [String: Any]))
        XCTAssertEqual((payload["_1"] as? ASNativeUnsigned)?.value, 987)
        XCTAssertEqual(hid.release()["releaseRequired"] as? Bool, false)
    }
    func testDoubleTapQueuesTwoTimedPairsAtOnePoint() throws {
        let transport = ScriptedTransport(); var now = 10.0, sentAt: [Double] = []
        transport.onSend = { _ in sentAt.append(now) }
        let hid = NativeHIDAdapter(
            transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now })
        try hid.prepare()
        var contacts = 0
        let result = try hid.doubleTap(
            (123, 456),
            onContact: {
                contacts += 1; XCTAssertEqual(self.reports(transport).count, 1); XCTAssertEqual(now, 10)
            })
        XCTAssertEqual(contacts, 1)
        let values = reports(transport)
        XCTAssertEqual(values.map { $0[3] }, [0xc2, 2, 0xc2, 2])
        XCTAssertTrue(values.allSatisfy { Array($0[4...7]) == [123, 0, 200, 1] })
        XCTAssertEqual(sentAt[1] - sentAt[0], 0.06, accuracy: 0.001)
        XCTAssertEqual(sentAt[2] - sentAt[1], 0.10, accuracy: 0.001)
        XCTAssertEqual(sentAt[3] - sentAt[2], 0.06, accuracy: 0.001)
        XCTAssertEqual(result["tapPairsQueued"] as? Int, 2)
        XCTAssertEqual(result["verificationStatus"] as? String, "not_checked")
        XCTAssertEqual(hid.release()["releaseRequired"] as? Bool, false)
    }

    func testDoubleTapCancellationAtEachPhaseReleasesWithoutSecondAttemptOrReplay() throws {
        for cancelAfter in 0...4 {
            let transport = ScriptedTransport(), cancel = NativeCancellation(); var now = 0.0
            let hid = NativeHIDAdapter(
                transport: transport, cancellation: cancel, wait: { now += $0 }, uptime: { now })
            try hid.prepare()
            if cancelAfter == 0 { cancel.cancel() }
            transport.onSend = { _ in if transport.sends.count == cancelAfter { cancel.cancel() } }
            XCTAssertThrowsError(try hid.doubleTap((12, 34))) {
                if cancelAfter > 0 { XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true) }
            }
            let values = reports(transport)
            XCTAssertEqual(
                values.filter { $0[3] == 0xc2 }.count, cancelAfter == 0 ? 0 : cancelAfter <= 2 ? 1 : 2)
            if cancelAfter > 0 { XCTAssertEqual(values.last?[3], 2) }
            let count = values.count
            XCTAssertThrowsError(try hid.doubleTap((12, 34))); XCTAssertEqual(reports(transport).count, count)
        }
    }

    func testDoubleTapSendFailureAtEachReportRemainsUnknownAndReleases() throws {
        for failAt in 1...4 {
            let transport = ScriptedTransport(); var now = 0.0
            let hid = NativeHIDAdapter(
                transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now }
            )
            try hid.prepare()
            transport.onSend = { _ in
                if transport.sends.count == failAt {
                    throw TransportError(description: "test lost write", possiblySent: true)
                }
            }
            XCTAssertThrowsError(try hid.doubleTap((12, 34))) {
                XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true)
                XCTAssertEqual(($0 as? ActionFailure)?.result?["tapPairsQueued"] as? Int, failAt <= 2 ? 0 : 1)
            }
            XCTAssertEqual(reports(transport).last?[3], 2)
            let count = reports(transport).count
            XCTAssertThrowsError(try hid.doubleTap((12, 34))); XCTAssertEqual(reports(transport).count, count)
        }
    }

    func testDoubleTapDelayOrMediaLossBetweenContactsNeverSendsSecondContact() throws {
        for delay in [false, true] {
            let transport = ScriptedTransport(); var now = 0.0
            let hid = NativeHIDAdapter(
                transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now }
            )
            try hid.prepare()
            transport.onSend = { _ in if delay && transport.sends.count == 2 { now += 0.31 } }
            XCTAssertThrowsError(
                try hid.doubleTap((12, 34)) {
                    if !delay && transport.sends.count == 2 {
                        throw IPhoneUseError("native_media_unhealthy", "test")
                    }
                }
            ) { XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true) }
            XCTAssertEqual(reports(transport).map { $0[3] }, [0xc2, 2])
            XCTAssertFalse(hid.isAvailable)
        }
    }

    func testDoubleTapObservationGuardsAndRotationMapping() throws {
        for (rotation, orientation, width, height) in [
            ("rot0", 1, 390, 844), ("rot90", 4, 844, 390), ("rot270", 3, 844, 390)
        ] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let cache = ObservationCache(directory: directory)
            let screen = ScreenRect(CGRect(x: 0, y: 0, width: width, height: height))
            let context = ScreenContext(
                screen: screen, scope: screen, orientation: orientation, keyboardCount: 0)
            let png = try screenPNG(width: width, height: height)
            let capture = CapturedObservation(
                nodes: [],
                metadata: [
                    "backend": "apple-native", "screenContext": try jsonObject(JSONEncoder().encode(context))
                ],
                screenshot: png)
            _ = try cache.store(capture)
            let action = try DeviceAction(
                operation: "double-tap", request: ["reference": "o1", "x": 100, "y": 150],
                allowScreenText: true)
            let gesture = try XCTUnwrap(cache.resolveTarget(for: action).gesture)
            try gesture.validate(kind: "double-tap")
            let mapped = try NativeCoordinateMapper.map(gesture.start, screen: screen, rotation: rotation)
            XCTAssertNotEqual(mapped.0, mapped.1)
            let changed = try screenPNG(
                width: width, height: height,
                patches: [(CGRect(x: 90, y: 140, width: 20, height: 20), [0, 0, 0])])
            XCTAssertFalse(try gesture.screenGuard.check(png: changed, context: context).accepted)
            _ = try cache.store(capture)
            XCTAssertThrowsError(try cache.resolveTarget(for: action))
        }
    }

    func testLongPressHoldsSingleContactAndChecksHealth() throws {
        let transport = ScriptedTransport(), cancel = NativeCancellation()
        var now = 10.0, checks = 0
        let hid = NativeHIDAdapter(
            transport: transport, cancellation: cancel, wait: { now += $0 }, uptime: { now })
        try hid.prepare()
        let facts = try hid.tap((120, 340), hold: 0.8) { checks += 1 }
        XCTAssertGreaterThanOrEqual(now, 10.8)
        XCTAssertGreaterThan(checks, 100)
        XCTAssertEqual(reports(transport).map { $0[3] }, [0xc2, 2])
        XCTAssertEqual(facts["pressDuration"] as? Double, 0.8)
    }
}

import XCTest
import CoreGraphics
import AppleNativeBridge
import Darwin
@testable import IPhoneUseCore

extension AppleNativeTests {

    func testLongPressHealthLossReleasesAndBlocksReplay() throws {
        let transport = ScriptedTransport(), cancel = NativeCancellation()
        var now = 10.0
        let hid = NativeHIDAdapter(
            transport: transport, cancellation: cancel, wait: { now += $0 }, uptime: { now })
        try hid.prepare()
        XCTAssertThrowsError(
            try hid.tap((120, 340), hold: 0.8) {
                if now > 10.2 { throw IPhoneUseError("native_media_unhealthy", "test") }
            }
        ) { XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true) }
        XCTAssertEqual(reports(transport).map { $0[3] }, [0xc2, 2])
        XCTAssertThrowsError(try hid.tap((120, 340)))
        XCTAssertEqual(transport.sends.count, 2)
    }

    func testHomeQueuesButtonPairWithoutTouchOrKeyboard() throws {
        let touch = ScriptedTransport(), button = ScriptedTransport(), cancel = NativeCancellation()
        var now = 10.0
        let hid = NativeHIDAdapter(
            transport: touch, cancellation: cancel, wait: { now += $0 }, uptime: { now })
        try hid.prepare()
        let facts = try hid.home(using: button)
        XCTAssertTrue(touch.sends.isEmpty)
        XCTAssertEqual(button.sends.count, 2)
        for (index, message) in button.sends.enumerated() {
            XCTAssertEqual(message["messageType"] as? String, "IndigoButtonEvent")
            let payload = (try XCTUnwrap(message["payload"] as? [String: Any]))
            XCTAssertEqual((payload["state"] as? ASNativeUnsigned)?.value, UInt64(index + 1))
            XCTAssertEqual((payload["usagePage"] as? ASNativeUnsigned)?.value, 0x0c)
            XCTAssertEqual((payload["usageCode"] as? ASNativeUnsigned)?.value, 0x40)
        }
        XCTAssertEqual(facts["verificationStatus"] as? String, "not_checked")
        XCTAssertEqual(facts["buttonReleaseQueued"] as? Bool, true)
        XCTAssertEqual(hid.state, .ready)
    }

    func testHomeCancellationReleasesOnSameChannelWithoutReplay() throws {
        let touch = ScriptedTransport(), button = ScriptedTransport(), cancel = NativeCancellation()
        var now = 10.0
        let hid = NativeHIDAdapter(
            transport: touch, cancellation: cancel,
            wait: {
                now += $0; cancel.cancel()
            }, uptime: { now })
        try hid.prepare()
        XCTAssertThrowsError(try hid.home(using: button)) {
            XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true)
        }
        XCTAssertEqual(button.sends.count, 2)
        XCTAssertEqual(
            ((button.sends.last?["payload"] as? [String: Any])?["state"] as? ASNativeUnsigned)?.value, 2)
        XCTAssertThrowsError(try hid.home(using: button))
        XCTAssertEqual(button.sends.count, 2)
        XCTAssertEqual(hid.release()["buttonReleaseRequired"] as? Bool, false)
    }

    func testSwipePlanUsesOriginalPixelsAndExactMappedEndpoints() throws {
        let plan = try swipePlan()
        XCTAssertEqual(plan.movementDuration, 0.6, accuracy: 0.00001)
        XCTAssertEqual(try swipePlan(scale: 1).movementDuration, 0.2, accuracy: 0.00001)
        XCTAssertEqual(plan.point(at: 0).0, plan.start.0)
        XCTAssertEqual(plan.point(at: 1).1, plan.end.1)
        XCTAssertEqual(
            plan.point(at: 0.5).1, UInt16(((Double(plan.start.1) + Double(plan.end.1)) / 2).rounded()))
        XCTAssertThrowsError(try swipePlan(end: CGPoint(x: 195, y: -1)))
        XCTAssertThrowsError(try swipePlan(end: CGPoint(x: 195, y: 600)))
        XCTAssertThrowsError(try swipePlan(motion: SwipeMotion(velocity: 1)))
        XCTAssertThrowsError(try swipePlan(motion: SwipeMotion(velocity: .nan)))
    }
    func testSwipeReportsMonotonicPathHoldsAndOneRelease() throws {
        let transport = ScriptedTransport(),
            plan = try swipePlan(motion: SwipeMotion(velocity: 500, pressDuration: 0.1, holdDuration: 0.2))
        var now = 100.0, times: [Double] = []
        transport.onSend = { _ in times.append(now) }
        let hid = NativeHIDAdapter(
            transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now })
        try hid.prepare()
        var contacts = 0
        let result = try hid.swipe(
            plan,
            onContact: {
                contacts += 1; XCTAssertEqual(self.reports(transport).count, 1); XCTAssertEqual(now, 100)
            })
        XCTAssertEqual(contacts, 1)
        let packets = reports(transport), points = packets.map(point)
        XCTAssertEqual(points.first, [Int(plan.start.0), Int(plan.start.1)])
        XCTAssertEqual(
            points.suffix(2), [[Int(plan.end.0), Int(plan.end.1)], [Int(plan.end.0), Int(plan.end.1)]])
        XCTAssertTrue(zip(points, points.dropFirst()).allSatisfy { $0[0] == $1[0] && $0[1] >= $1[1] })
        XCTAssertTrue(packets.dropLast().allSatisfy { $0[3] == 0xc2 })
        XCTAssertEqual(packets.last?[3], 2)
        XCTAssertGreaterThanOrEqual(times[1] - times[0], 0.1)
        XCTAssertEqual(times.last! - times[times.count - 2], 0.2, accuracy: 0.00001)
        XCTAssertEqual(now - 100, 0.9, accuracy: 0.00001)
        XCTAssertEqual((result["motion"] as? [String: Double])?["velocity"], 500)
        XCTAssertEqual(result["motionVelocityUnit"] as? String, "original_screenshot_pixels_per_second")
        XCTAssertEqual(result["moveReportsQueued"] as? Int, packets.count - 2)
        XCTAssertTrue(hid.isAvailable)
        XCTAssertEqual(hid.release()["releaseRequired"] as? Bool, false)
    }
    func testSlowSwipeSendSkipsMissedSamplesWithoutBurstOrReplay() throws {
        let transport = ScriptedTransport(), plan = try swipePlan()
        var now = 10.0, times: [Double] = []
        transport.onSend = { _ in
            times.append(now); now += 0.07
        }
        let hid = NativeHIDAdapter(
            transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now })
        try hid.prepare()
        _ = try hid.swipe(plan)
        XCTAssertLessThan(reports(transport).count, 15)
        XCTAssertTrue(zip(times, times.dropFirst()).allSatisfy { $1 - $0 >= 0.069 })
        XCTAssertEqual(point(reports(transport).last!), [Int(plan.end.0), Int(plan.end.1)])
    }
    func testSwipeCancellationDuringPressMoveAndHoldReleasesLastPosition() throws {
        let plan = try swipePlan(motion: SwipeMotion(velocity: 500, pressDuration: 0.1, holdDuration: 0.2))
        for phase in [0, 1, 2] {
            let transport = ScriptedTransport(), cancel = NativeCancellation()
            var now = 0.0, contacts = 0, reachedEnd = false
            transport.onSend = { message in
                let data =
                    (try XCTUnwrap(
                        ((try XCTUnwrap(
                            ((try XCTUnwrap(message["payload"] as? [String: Any])))["send"] as? [String: Any])))[
                                "_0"]
                            as? Data))
                if data[3] == 0xc2 {
                    contacts += 1; reachedEnd = self.point(data) == [Int(plan.end.0), Int(plan.end.1)]
                }
            }
            let hid = NativeHIDAdapter(
                transport: transport, cancellation: cancel,
                wait: {
                    now += $0
                    if (phase == 0 && contacts == 1) || (phase == 1 && contacts >= 3)
                        || (phase == 2 && reachedEnd) {
                        cancel.cancel()
                    }
                }, uptime: { now })
            try hid.prepare()
            XCTAssertThrowsError(try hid.swipe(plan)) {
                XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true)
                XCTAssertEqual(($0 as? ActionFailure)?.result?["transportStatus"] as? String, "uncertain")
            }
            let packets = reports(transport)
            XCTAssertEqual(packets.last?[3], 2)
            XCTAssertEqual(point(packets.last!), point(packets[packets.count - 2]))
            let count = packets.count
            XCTAssertFalse(hid.isAvailable)
            XCTAssertThrowsError(try hid.swipe(plan))
            _ = hid.release()
            XCTAssertEqual(transport.sends.count, count)
        }
    }
    func testFailedMoveReleasesAttemptedPositionAndWithdrawsCapability() throws {
        let transport = ScriptedTransport(), plan = try swipePlan()
        var now = 0.0
        transport.onSend = { _ in
            if transport.sends.count == 3 {
                throw TransportError(description: "lost MOVE reply", possiblySent: true)
            }
        }
        let hid = NativeHIDAdapter(
            transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now })
        try hid.prepare()
        XCTAssertThrowsError(try hid.swipe(plan)) {
            let cleanup = ($0 as? ActionFailure)?.result?["cleanup"] as? [String: Any]
            XCTAssertEqual(cleanup?["releaseQueued"] as? Bool, true)
        }
        let packets = reports(transport)
        XCTAssertEqual(packets.count, 4)
        XCTAssertEqual(point(packets[2]), point(packets[3]))
        XCTAssertFalse(hid.isAvailable)
        XCTAssertThrowsError(try hid.tap((1, 2)))
        XCTAssertEqual(transport.sends.count, 4)
    }
    func testSwipeMediaFailureAndDeadlineAttemptReleaseWithoutContinuing() throws {
        let plan = try swipePlan()
        for deadline in [false, true] {
            let transport = ScriptedTransport()
            var now = 0.0
            let hid = NativeHIDAdapter(
                transport: transport, cancellation: NativeCancellation(),
                wait: {
                    now += deadline ? 11 : $0
                }, uptime: { now })
            try hid.prepare()
            XCTAssertThrowsError(
                try hid.swipe(plan) {
                    if !deadline && !transport.sends.isEmpty {
                        throw IPhoneUseError("native_media_unhealthy", "test media loss")
                    }
                }
            ) { XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true) }
            XCTAssertEqual(reports(transport).map { $0[3] }, [0xc2, 2])
            XCTAssertFalse(hid.isAvailable)
        }
    }
    func testSwipePreflightFailureSendsNothing() throws {
        let plan = try swipePlan(), transport = ScriptedTransport(), cancel = NativeCancellation()
        let hid = NativeHIDAdapter(transport: transport, cancellation: cancel)
        try hid.prepare()
        XCTAssertThrowsError(try hid.swipe(plan) { throw IPhoneUseError("native_media_unhealthy", "test") })
        cancel.cancel()
        XCTAssertThrowsError(try hid.swipe(plan))
        XCTAssertTrue(transport.sends.isEmpty)
    }
}

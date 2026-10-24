@testable import IPhoneUseRunnerSupport
import XCTest
import CoreGraphics
@testable import IPhoneUseCore

private final class PinchTransport: NativeTransport {
    var reports: [Data] = []
    var onSend: (() throws -> Void)?
    func request(_ message: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        [
            "connectedServices": [
                [
                    "PrimaryUsagePage": 13, "PrimaryUsage": 4, "UniversalControlBuiltIn": true,
                    "_ServiceID": 735
                ]
            ]
        ]
    }
    func send(_ message: [String: Any], timeout: TimeInterval) throws {
        let payload = (try XCTUnwrap(message["payload"] as? [String: Any]))
        reports.append((try XCTUnwrap(((try XCTUnwrap(payload["send"] as? [String: Any])))["_0"] as? Data)))
        try onSend?()
    }
    func cancel() {}
}

final class NativePinchTests: XCTestCase {
    private func action(_ changes: [String: Any] = [:], native: Bool = true) throws -> DeviceAction {
        try DeviceAction(
            operation: "pinch",
            request: [
                "reference": "o1", "x": 195.0, "y": 300.0,
                "fromDistance": 80.0, "toDistance": 200.0, "duration": 0.2
            ].merging(changes) { _, new in new }, allowScreenText: native)
    }
    private func gesture(rotation: String = "rot0") throws -> CoordinateGesture {
        let width = rotation == "rot0" ? 390 : 844, height = rotation == "rot0" ? 844 : 390
        let screen = ScreenRect(CGRect(x: 0, y: 0, width: width, height: height))
        let context = ScreenContext(
            screen: screen, scope: screen, orientation: rotation == "rot0" ? 1 : rotation == "rot90" ? 4 : 3,
            keyboardCount: 0)
        let center = CGPoint(x: 195, y: 200),
            motion = PinchMotion(fromDistance: 80, toDistance: 200, duration: 0.2)
        let guardValue = try ScreenGuard(
            png: screenPNG(width: width, height: height), context: context,
            rects: motion.regions(center: center, screen: screen.cgRect), policy: .init())
        return CoordinateGesture(start: center, end: nil, screenGuard: guardValue, pinch: motion)
    }
    func testAdmissionAcceptsBothModesAndRejectsInvalidMotionAndElementCoordinates() throws {
        XCTAssertNoThrow(try action(native: false))
        for bad: [String: Any] in [
            ["reference": "o1:e1"], ["fromDistance": 0], ["toDistance": 80],
            ["duration": 0.01], ["duration": 5.1], ["fromDistance": true], ["toDistance": Double.infinity],
            ["velocity": 100], ["direction": "in"], ["fromX": 10]
        ] {
            XCTAssertThrowsError(try action(bad), "\(bad)")
        }
        XCTAssertEqual(try action().pinchMotion?.duration, 0.2)
        XCTAssertThrowsError(
            try DeviceAction(
                operation: "tap", request: ["reference": "o1", "x": 1, "y": 2, "fromDistance": 20]))
    }
    func testTwoIndependentSlotsReleaseAndFullTimestamp() {
        let down = NativePinchReport.make(
            contact: true, points: [(0x1234, 0x5678), (0x9abc, 0xdef0)], timestamp: 0x0102030405060708)
        XCTAssertEqual(down.count, 58)
        XCTAssertEqual(
            Array(down.prefix(13)), [9, 2, 5, 0xc2, 0x34, 0x12, 0x78, 0x56, 0xc3, 0xbc, 0x9a, 0xf0, 0xde])
        XCTAssertEqual(Array(down[40...44]), [2, 3, 0, 0, 0])
        XCTAssertEqual(Array(down[45...52]), [8, 7, 6, 5, 4, 3, 2, 1])
        let releasePoints = NativePinchReport.make(contact: false, points: [(1, 2), (3, 4)], timestamp: 0)
        XCTAssertEqual(releasePoints[1], 2); XCTAssertEqual(releasePoints[3], 2)
        XCTAssertEqual(releasePoints[8], 3)
        XCTAssertEqual(Array(releasePoints[40...41]), [2, 3])
    }
    func testBothPathsGuardedAndMappedInThreeOrientations() throws {
        for rotation in ["rot0", "rot90", "rot270"] {
            let gesture = try gesture(rotation: rotation),
                plan = try NativePinchPlan(gesture: gesture, rotation: rotation)
            for index in 0..<2 {
                let point = gesture.pinch!.points(center: gesture.start, ending: false)[index]
                let mapped = try NativeCoordinateMapper.map(
                    point, screen: gesture.screenGuard.context.screen, rotation: rotation)
                XCTAssertEqual(plan.start[index].0, mapped.0); XCTAssertEqual(plan.start[index].1, mapped.1)
                let rect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
                let changed = try screenPNG(
                    width: gesture.screenGuard.pixelWidth, height: gesture.screenGuard.pixelHeight,
                    patches: [(rect, [0, 0, 0])])
                XCTAssertFalse(
                    try gesture.screenGuard.check(png: changed, context: gesture.screenGuard.context).accepted
                )
            }
            let half = plan.points(at: 0.5)
            XCTAssertEqual(
                Double(half[0].0), (Double(plan.start[0].0) + Double(plan.end[0].0)) / 2, accuracy: 1)
            XCTAssertEqual(
                Double(half[1].1), (Double(plan.start[1].1) + Double(plan.end[1].1)) / 2, accuracy: 1)
        }
        let gesture = try gesture()
        let invalid = CoordinateGesture(
            start: CGPoint(x: 5, y: 200), end: nil, screenGuard: gesture.screenGuard, pinch: gesture.pinch)
        XCTAssertThrowsError(try NativePinchPlan(gesture: invalid, rotation: "rot0"))
        var wrong = gesture; wrong.pinch = PinchMotion(fromDistance: 80, toDistance: 300, duration: 0.2)
        XCTAssertThrowsError(try wrong.validate(kind: "pinch")) // Different corridor cannot reuse protection.
    }
    func testObservationRejectsOutOfBoundsAndInvalidatesOldReference() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory), gesture = try gesture()
        let capture = CapturedObservation(
            nodes: [],
            metadata: [
                "backend": "apple-native",
                "screenContext": try jsonObject(JSONEncoder().encode(gesture.screenGuard.context))
            ], screenshot: try screenPNG())
        _ = try cache.store(capture)
        let valid = try action()
        let resolved = try XCTUnwrap(cache.resolveTarget(for: valid).gesture)
        try resolved.validate(kind: "pinch")
        XCTAssertEqual(resolved.screenGuard.regions.count, 2)
        XCTAssertThrowsError(try cache.resolveTarget(for: action(["x": 30])))
        XCTAssertThrowsError(
            try cache.resolveTarget(for: action(["toDistance": Double.greatestFiniteMagnitude])))
        _ = try cache.store(capture)
        XCTAssertThrowsError(try cache.resolveTarget(for: valid))
    }
    func testPinchMovesBothIdentitiesTogetherAndReleases() throws {
        let transport = PinchTransport(); var now = 10.0, times: [Double] = []
        transport.onSend = { times.append(now) }
        let hid = NativeHIDAdapter(
            transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now })
        try hid.prepare()
        var contacts = 0
        let result = try hid.pinch(
            NativePinchPlan(gesture: gesture(), rotation: "rot0"),
            onContact: {
                contacts += 1; XCTAssertEqual(transport.reports.count, 1); XCTAssertEqual(now, 10)
            })
        XCTAssertEqual(contacts, 1)
        XCTAssertGreaterThan(transport.reports.count, 4)
        XCTAssertTrue(
            transport.reports.dropLast().allSatisfy {
                $0[1] == 2 && $0[3] == 0xc2 && $0[8] == 0xc3 && $0[40] == 2 && $0[41] == 3
            })
        XCTAssertEqual(transport.reports.last?[3], 2); XCTAssertEqual(transport.reports.last?[8], 3)
        XCTAssertGreaterThanOrEqual(times.last! - times.first!, 0.32 - 0.001)
        XCTAssertEqual(result["contactCount"] as? Int, 2)
        XCTAssertEqual(result["moveReportsQueued"] as? Int, transport.reports.count - 2)
        XCTAssertEqual(result["verificationStatus"] as? String, "not_checked")
        XCTAssertEqual(hid.release()["releaseRequired"] as? Bool, false)
        XCTAssertTrue(hid.isAvailable)
    }
    func testCancelOrFailedSendReleasesBothAndNeverReplays() throws {
        let plan = try NativePinchPlan(gesture: gesture(), rotation: "rot0")
        for mode in ["cancel", "send", "media", "deadline"] {
            for phase in [0, 1, 4] {
                let transport = PinchTransport(), cancel = NativeCancellation(); var now = 0.0
                let hid = NativeHIDAdapter(
                    transport: transport, cancellation: cancel, wait: { now += $0 }, uptime: { now })
                try hid.prepare()
                if phase == 0 { cancel.cancel() }
                transport.onSend = {
                    if transport.reports.count == phase {
                        if mode == "cancel" { cancel.cancel() }
                        if mode == "send" { throw IPhoneUseError("lost_reply", "test") }
                        if mode == "deadline" { now += 7 }
                    }
                }
                XCTAssertThrowsError(
                    try hid.pinch(plan) {
                        if mode == "media", phase > 0, transport.reports.count == phase {
                            throw IPhoneUseError("media_lost", "test")
                        }
                    }
                ) { error in
                    if phase > 0 { XCTAssertEqual((error as? ActionFailure)?.possiblyExecuted, true) }
                }
                if phase == 0 {
                    XCTAssertTrue(transport.reports.isEmpty)
                } else {
                    XCTAssertEqual(transport.reports.last?[3], 2)
                    XCTAssertEqual(transport.reports.last?[8], 3)
                }
                let count = transport.reports.count
                XCTAssertThrowsError(try hid.pinch(plan)); XCTAssertEqual(transport.reports.count, count)
            }
        }
    }
    func testFailedReleaseRemainsUncertainAndSlowSendsSkipSamples() throws {
        let plan = try NativePinchPlan(gesture: gesture(), rotation: "rot0")
        let transport = PinchTransport(); var now = 0.0
        let hid = NativeHIDAdapter(
            transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now })
        try hid.prepare()
        transport.onSend = {
            now += 0.09
            if transport.reports.last![3] == 2 { throw IPhoneUseError("release_failed", "test") }
        }
        XCTAssertThrowsError(try hid.pinch(plan)) { error in
            let facts = (error as? ActionFailure)?.result?["cleanup"] as? [String: Any]
            XCTAssertEqual(facts?["contactsToRelease"] as? Int, 2)
            XCTAssertEqual(facts?["releaseQueued"] as? Bool, false)
        }
        XCTAssertTrue(hid.releaseUncertain); XCTAssertFalse(hid.isAvailable)
        XCTAssertLessThan(transport.reports.count, 10)
        XCTAssertEqual(transport.reports.suffix(2).map { $0[8] }, [3, 3])
        XCTAssertEqual(hid.release()["releaseUncertain"] as? Bool, true)
    }
}

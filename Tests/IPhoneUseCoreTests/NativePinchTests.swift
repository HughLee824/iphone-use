import XCTest
import CoreGraphics
@testable import IPhoneUseCore

private final class PinchTransport: NativeTransport {
    var reports: [Data] = []
    var onSend: (() throws -> Void)?
    func request(_ message: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        ["connectedServices": [["PrimaryUsagePage": 13, "PrimaryUsage": 4, "UniversalControlBuiltIn": true, "_ServiceID": 735]]]
    }
    func send(_ message: [String: Any], timeout: TimeInterval) throws {
        let payload = message["payload"] as! [String: Any]
        reports.append((payload["send"] as! [String: Any])["_0"] as! Data)
        try onSend?()
    }
    func cancel() {}
}

final class NativePinchTests: XCTestCase {
    private func action(_ changes: [String: Any] = [:], native: Bool = true) throws -> DeviceAction {
        try DeviceAction(operation: "pinch", request: ["reference": "o1", "x": 195.0, "y": 300.0,
            "fromDistance": 80.0, "toDistance": 200.0, "duration": 0.2].merging(changes) { _, new in new }, allowScreenText: native)
    }
    private func gesture(rotation: String = "rot0") throws -> CoordinateGesture {
        let width = rotation == "rot0" ? 390 : 844, height = rotation == "rot0" ? 844 : 390
        let screen = ScreenRect(CGRect(x: 0, y: 0, width: width, height: height))
        let context = ScreenContext(screen: screen, scope: screen, orientation: rotation == "rot0" ? 1 : rotation == "rot90" ? 4 : 3, keyboardCount: 0)
        let center = CGPoint(x: 195, y: 200), motion = PinchMotion(fromDistance: 80, toDistance: 200, duration: 0.2)
        let guardValue = try ScreenGuard(png: screenPNG(width: width, height: height), context: context,
            rects: motion.regions(center: center, screen: screen.cgRect), policy: .init())
        return CoordinateGesture(start: center, end: nil, screenGuard: guardValue, pinch: motion)
    }
    func testAdmissionRejectsRunnerInvalidMotionAndElementCoordinates() throws {
        XCTAssertThrowsError(try action(native: false))
        for bad: [String: Any] in [["reference": "o1:e1"], ["fromDistance": 0], ["toDistance": 80],
            ["duration": 0.01], ["duration": 5.1], ["fromDistance": true], ["toDistance": Double.infinity],
            ["velocity": 100], ["direction": "in"], ["fromX": 10]] {
            XCTAssertThrowsError(try action(bad), "\(bad)")
        }
        XCTAssertEqual(try action().pinchMotion?.duration, 0.2)
        XCTAssertThrowsError(try DeviceAction(operation: "tap", request: ["reference": "o1", "x": 1, "y": 2, "fromDistance": 20]))
    }
    func testTwoIndependentSlotsReleaseAndFullTimestamp() {
        let down = NativePinchReport.make(contact: true, points: [(0x1234, 0x5678), (0x9abc, 0xdef0)], timestamp: 0x0102030405060708)
        XCTAssertEqual(down.count, 58)
        XCTAssertEqual(Array(down.prefix(13)), [9,2,5,0xc2,0x34,0x12,0x78,0x56,0xc3,0xbc,0x9a,0xf0,0xde])
        XCTAssertEqual(Array(down[40...44]), [2,3,0,0,0])
        XCTAssertEqual(Array(down[45...52]), [8,7,6,5,4,3,2,1])
        let up = NativePinchReport.make(contact: false, points: [(1,2),(3,4)], timestamp: 0)
        XCTAssertEqual(up[1], 2); XCTAssertEqual(up[3], 2); XCTAssertEqual(up[8], 3)
        XCTAssertEqual(Array(up[40...41]), [2,3])
    }
    func testBothPathsGuardedAndMappedInThreeOrientations() throws {
        for rotation in ["rot0", "rot90", "rot270"] {
            let g = try gesture(rotation: rotation), plan = try NativePinchPlan(gesture: g, rotation: rotation)
            for i in 0..<2 {
                let p = g.pinch!.points(center: g.start, ending: false)[i]
                let mapped = try NativeCoordinateMapper.map(p, screen: g.screenGuard.context.screen, rotation: rotation)
                XCTAssertEqual(plan.start[i].0, mapped.0); XCTAssertEqual(plan.start[i].1, mapped.1)
                let rect = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                let changed = try screenPNG(width: g.screenGuard.pixelWidth, height: g.screenGuard.pixelHeight, patches: [(rect,[0,0,0])])
                XCTAssertFalse(try g.screenGuard.check(png: changed, context: g.screenGuard.context).accepted)
            }
            let half = plan.points(at: 0.5)
            XCTAssertEqual(Double(half[0].0), (Double(plan.start[0].0) + Double(plan.end[0].0)) / 2, accuracy: 1)
            XCTAssertEqual(Double(half[1].1), (Double(plan.start[1].1) + Double(plan.end[1].1)) / 2, accuracy: 1)
        }
        let g = try gesture()
        let invalid = CoordinateGesture(start: CGPoint(x: 5, y: 200), end: nil, screenGuard: g.screenGuard, pinch: g.pinch)
        XCTAssertThrowsError(try NativePinchPlan(gesture: invalid, rotation: "rot0"))
        var wrong = g; wrong.pinch = PinchMotion(fromDistance: 80, toDistance: 300, duration: 0.2)
        XCTAssertThrowsError(try wrong.validate(kind: "pinch")) // Different corridor cannot reuse protection.
    }
    func testObservationRejectsOutOfBoundsAndInvalidatesOldReference() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory), g = try gesture()
        let capture = CapturedObservation(nodes: [], metadata: ["backend": "apple-native", "screenContext": try jsonObject(JSONEncoder().encode(g.screenGuard.context))], screenshot: try screenPNG())
        _ = try cache.store(capture)
        let valid = try action()
        let resolved = try XCTUnwrap(cache.resolveTarget(for: valid).gesture)
        try resolved.validate(kind: "pinch")
        XCTAssertEqual(resolved.screenGuard.regions.count, 2)
        XCTAssertThrowsError(try cache.resolveTarget(for: action(["x": 30])))
        XCTAssertThrowsError(try cache.resolveTarget(for: action(["toDistance": Double.greatestFiniteMagnitude])))
        _ = try cache.store(capture)
        XCTAssertThrowsError(try cache.resolveTarget(for: valid))
    }
    func testPinchMovesBothIdentitiesTogetherAndReleases() throws {
        let t = PinchTransport(); var now = 10.0, times: [Double] = []
        t.onSend = { times.append(now) }
        let hid = NativeHIDAdapter(transport: t, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now })
        try hid.prepare()
        let result = try hid.pinch(NativePinchPlan(gesture: gesture(), rotation: "rot0"))
        XCTAssertGreaterThan(t.reports.count, 4)
        XCTAssertTrue(t.reports.dropLast().allSatisfy { $0[1] == 2 && $0[3] == 0xc2 && $0[8] == 0xc3 && $0[40] == 2 && $0[41] == 3 })
        XCTAssertEqual(t.reports.last?[3], 2); XCTAssertEqual(t.reports.last?[8], 3)
        XCTAssertGreaterThanOrEqual(times.last! - times.first!, 0.32 - 0.001)
        XCTAssertEqual(result["contactCount"] as? Int, 2)
        XCTAssertEqual(result["moveReportsQueued"] as? Int, t.reports.count - 2)
        XCTAssertEqual(result["verificationStatus"] as? String, "not_checked")
        XCTAssertEqual(hid.release()["releaseRequired"] as? Bool, false)
        XCTAssertTrue(hid.isAvailable)
    }
    func testCancelOrFailedSendReleasesBothAndNeverReplays() throws {
        let plan = try NativePinchPlan(gesture: gesture(), rotation: "rot0")
        for mode in ["cancel", "send", "media", "deadline"] {
            for phase in [0,1,4] {
                let t = PinchTransport(), cancel = NativeCancellation(); var now = 0.0
                let hid = NativeHIDAdapter(transport: t, cancellation: cancel, wait: { now += $0 }, uptime: { now })
                try hid.prepare()
                if phase == 0 { cancel.cancel() }
                t.onSend = {
                    if t.reports.count == phase {
                        if mode == "cancel" { cancel.cancel() }
                        if mode == "send" { throw IPhoneUseError("lost_reply", "test") }
                        if mode == "deadline" { now += 7 }
                    }
                }
                XCTAssertThrowsError(try hid.pinch(plan) {
                    if mode == "media", phase > 0, t.reports.count == phase { throw IPhoneUseError("media_lost", "test") }
                }) { error in
                    if phase > 0 { XCTAssertEqual((error as? ActionFailure)?.possiblyExecuted, true) }
                }
                if phase == 0 { XCTAssertTrue(t.reports.isEmpty) }
                else { XCTAssertEqual(t.reports.last?[3], 2); XCTAssertEqual(t.reports.last?[8], 3) }
                let count = t.reports.count
                XCTAssertThrowsError(try hid.pinch(plan)); XCTAssertEqual(t.reports.count, count)
            }
        }
    }
    func testFailedReleaseRemainsUncertainAndSlowSendsSkipSamples() throws {
        let plan = try NativePinchPlan(gesture: gesture(), rotation: "rot0")
        let t = PinchTransport(); var now = 0.0
        let hid = NativeHIDAdapter(transport: t, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now })
        try hid.prepare()
        t.onSend = {
            now += 0.09
            if t.reports.last![3] == 2 { throw IPhoneUseError("release_failed", "test") }
        }
        XCTAssertThrowsError(try hid.pinch(plan)) { error in
            let facts = (error as? ActionFailure)?.result?["cleanup"] as? [String: Any]
            XCTAssertEqual(facts?["contactsToRelease"] as? Int, 2)
            XCTAssertEqual(facts?["releaseQueued"] as? Bool, false)
        }
        XCTAssertTrue(hid.releaseUncertain); XCTAssertFalse(hid.isAvailable)
        XCTAssertLessThan(t.reports.count, 10)
        XCTAssertEqual(t.reports.suffix(2).map { $0[8] }, [3,3])
        XCTAssertEqual(hid.release()["releaseUncertain"] as? Bool, true)
    }
}

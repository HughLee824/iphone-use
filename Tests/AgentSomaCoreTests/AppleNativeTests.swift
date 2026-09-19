import XCTest
import CoreGraphics
import AppleNativeBridge
import Darwin
@testable import AgentSomaCore

private final class ReplyChannel: NativeChannel {
    let lock = NSLock()
    var callbacks: [Int: ([String: Any]?, Error?) -> Void] = [:]
    var submitted: ((Int) -> Void)?
    var cancellations = 0
    var onCancel: (() -> Void)?
    var sends = 0
    func request(_ message: [String: Any], completion: @escaping ([String: Any]?, Error?) -> Void) {
        let id = message["id"] as! Int
        lock.lock(); callbacks[id] = completion; let notify = submitted; lock.unlock()
        notify?(id)
    }
    func reply(_ id: Int, value: Int) {
        lock.lock(); let callback = callbacks[id]; lock.unlock()
        callback?(["value": value], nil)
    }
    func send(_ message: [String: Any], completion: @escaping (Error?) -> Void) { sends += 1; completion(nil) }
    func cancel() { lock.lock(); cancellations += 1; lock.unlock(); onCancel?() }
}

private final class ScriptedTransport: NativeTransport {
    var requests: [[String: Any]] = []
    var sends: [[String: Any]] = []
    var cancellations = 0
    var onRequest: (([String: Any]) throws -> [String: Any])?
    var onSend: (([String: Any]) throws -> Void)?
    func request(_ message: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        requests.append(message)
        return try onRequest?(message) ?? ["connectedServices": [["PrimaryUsagePage": 13, "PrimaryUsage": 4,
            "UniversalControlBuiltIn": true, "_ServiceID": 987]]]
    }
    func send(_ message: [String: Any], timeout: TimeInterval) throws { sends.append(message); try onSend?(message) }
    func cancel() { cancellations += 1 }
}

private final class MediaReceiver: NativeMediaReceiver {
    let address = "::1"
    let port: UInt16 = 3456
    var closes = 0
    var configured = false
    func configure(_ configuration: [String: Any]) throws { configured = true }
    func health() -> [String: Any] { ["healthy": configured] }
    func close() { closes += 1 }
}

private final class TouchChannel: NativeChannel {
    var reports: [Data] = []
    var cancellations = 0
    func request(_ message: [String: Any], completion: @escaping ([String: Any]?, Error?) -> Void) {
        completion(["connectedServices": [["PrimaryUsagePage": 13, "PrimaryUsage": 4,
            "UniversalControlBuiltIn": true, "_ServiceID": 987]]], nil)
    }
    func send(_ message: [String: Any], completion: @escaping (Error?) -> Void) {
        let payload = message["payload"] as! [String: Any]
        reports.append((payload["send"] as! [String: Any])["_0"] as! Data)
        completion(nil)
    }
    func cancel() { cancellations += 1 }
}

final class AppleNativeTests: XCTestCase {
    func testBrokerSocketRejectsNonDeviceSocketAndConsumesOnlyOwnedDescriptor() throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { close(sockets[1]) }
        XCTAssertThrowsError(try ASNativeChannel(connectedFileDescriptor: sockets[0], deviceAddress: "::1", versionFlags: 1 << 56))
        XCTAssertEqual(fcntl(sockets[0], F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
        XCTAssertNotEqual(fcntl(sockets[1], F_GETFD), -1)
    }

    func testBrokerSocketRejectsWrongDeviceAndUnknownVersionWithoutLeaking() throws {
        let listener = socket(AF_INET6, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        XCTAssertEqual(inet_pton(AF_INET6, "::1", &address.sin6_addr), 1)
        XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
        } }, 0)
        XCTAssertEqual(listen(listener, 4), 0)
        var size = socklen_t(MemoryLayout<sockaddr_in6>.size)
        XCTAssertEqual(withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(listener, $0, &size)
        } }, 0)
        for (expectedAddress, flags) in [("::2", UInt64(1) << 56), ("::1", UInt64(0)), ("::1", UInt64(2))] {
            let client = socket(AF_INET6, SOCK_STREAM, 0)
            XCTAssertGreaterThanOrEqual(client, 0)
            XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            } }, 0)
            let peer = accept(listener, nil, nil)
            defer { close(peer) }
            XCTAssertThrowsError(try ASNativeChannel(connectedFileDescriptor: client, deviceAddress: expectedAddress, versionFlags: flags))
            XCTAssertEqual(fcntl(client, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF)
        }
    }

    func testLaunchOptionsPrecedeBundleSoTheyCannotBecomeAppArguments() {
        let bundle = "com.example.probe"
        let arguments = CoreDevice.commandArguments(["device", "process", "launch", "--activate", "--device", "test-device"],
            output: URL(fileURLWithPath: "/tmp/result.json"), trailingArguments: [bundle])
        XCTAssertEqual(arguments.last, bundle)
        XCTAssertEqual(arguments.firstIndex(of: "--device"), 5)
        XCTAssertLessThan(arguments.firstIndex(of: "--json-output")!, arguments.firstIndex(of: bundle)!)
        XCTAssertEqual(arguments.filter { $0 == bundle }.count, 1)
    }
    func testReplyCorrelationOutOfOrderAndSameConnectionReuse() throws {
        let channel = ReplyChannel()
        let client = AppleServiceTransport(channel: channel)
        let submitted = expectation(description: "two requests"); submitted.expectedFulfillmentCount = 2
        channel.submitted = { _ in submitted.fulfill() }
        let completed = expectation(description: "matching replies"); completed.expectedFulfillmentCount = 2
        for id in [1, 2] {
            DispatchQueue.global().async {
                do {
                    let reply = try client.request(["id": id], timeout: 2)
                    XCTAssertEqual(reply["value"] as? Int, id * 10)
                }
                catch { XCTFail("\(error)") }
                completed.fulfill()
            }
        }
        wait(for: [submitted], timeout: 1)
        channel.reply(2, value: 20); channel.reply(1, value: 10)
        wait(for: [completed], timeout: 1)
        channel.submitted = { id in channel.reply(id, value: id) }
        for id in 3...12 { XCTAssertEqual(try client.request(["id": id], timeout: 1)["value"] as? Int, id) }
        XCTAssertEqual(channel.cancellations, 0)
    }

    func testTimeoutPoisonsConnectionAndLateReplyDoesNotReplay() throws {
        let channel = ReplyChannel(), client: AppleServiceTransport
        client = AppleServiceTransport(channel: channel)
        XCTAssertThrowsError(try client.request(["id": 1], timeout: 0.01)) { XCTAssertEqual(($0 as? TransportError)?.possiblySent, true) }
        channel.reply(1, value: 123)
        XCTAssertThrowsError(try client.request(["id": 2], timeout: 1)) { XCTAssertEqual(($0 as? TransportError)?.possiblySent, false) }
        XCTAssertThrowsError(try client.send([:], timeout: 1))
        XCTAssertEqual(channel.callbacks.count, 1)
        XCTAssertEqual(channel.sends, 0)
        XCTAssertEqual(channel.cancellations, 1)
    }

    func testCancellationWakesAllPendingRequests() throws {
        let channel = ReplyChannel(), client: AppleServiceTransport
        client = AppleServiceTransport(channel: channel)
        let submitted = expectation(description: "request admitted")
        channel.submitted = { _ in submitted.fulfill() }
        let done = expectation(description: "cancel delivered")
        DispatchQueue.global().async {
            do {
                _ = try client.request(["id": 1], timeout: 5)
                XCTFail("Cancelled request must fail")
            } catch { XCTAssertEqual((error as? TransportError)?.possiblySent, true) }
            done.fulfill()
        }
        wait(for: [submitted], timeout: 1)
        client.cancel()
        wait(for: [done], timeout: 1)
        XCTAssertEqual(channel.cancellations, 1)
    }

    func testCancellationCannotOvertakeAdmittedChannelSubmission() throws {
        let channel = ReplyChannel(), entered = DispatchSemaphore(value: 0)
        let finishSubmission = DispatchSemaphore(value: 0), cancelled = DispatchSemaphore(value: 0)
        let cancelling = DispatchSemaphore(value: 0)
        let client = AppleServiceTransport(channel: channel)
        channel.submitted = { _ in
            entered.signal()
            XCTAssertEqual(finishSubmission.wait(timeout: .now() + 2), .success)
        }
        channel.onCancel = { cancelled.signal() }
        let requestDone = expectation(description: "request cancelled")
        let cancelDone = expectation(description: "cancellation returned")
        DispatchQueue.global().async {
            do { _ = try client.request(["id": 1], timeout: 3); XCTFail("Cancelled request must fail") }
            catch { XCTAssertEqual((error as? TransportError)?.possiblySent, true) }
            requestDone.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            cancelling.signal(); client.cancel(); cancelDone.fulfill()
        }
        XCTAssertEqual(cancelling.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(cancelled.wait(timeout: .now() + 0.05), .timedOut)
        finishSubmission.signal()
        wait(for: [requestDone, cancelDone], timeout: 2)
        XCTAssertEqual(cancelled.wait(timeout: .now() + 1), .success)
        XCTAssertThrowsError(try client.request(["id": 2], timeout: 1))
        XCTAssertEqual(channel.callbacks.count, 1)
        XCTAssertEqual(channel.cancellations, 1)
    }

    func testReplyAfterDeadlineDuringSubmissionCannotBecomeSuccess() throws {
        let channel = ReplyChannel()
        let client = AppleServiceTransport(channel: channel)
        channel.submitted = { id in
            Thread.sleep(forTimeInterval: 0.03)
            channel.reply(id, value: 123)
        }
        XCTAssertThrowsError(try client.request(["id": 1], timeout: 0.005)) {
            XCTAssertEqual(($0 as? TransportError)?.possiblySent, true)
        }
        XCTAssertThrowsError(try client.request(["id": 2], timeout: 1)) {
            XCTAssertEqual(($0 as? TransportError)?.possiblySent, false)
        }
        XCTAssertEqual(channel.callbacks.count, 1)
        XCTAssertEqual(channel.cancellations, 1)
    }

    func testFeatureReplyInvocationMismatchPoisonsTransport() throws {
        let transport = ScriptedTransport()
        transport.onRequest = { _ in ["CoreDevice.invocationIdentifier": "wrong", "CoreDevice.output": [:]] }
        let client = NativeFeatureClient(transport: transport, deviceIdentifier: "test-device", version: "642.16")
        XCTAssertThrowsError(try client.invoke("getmediasupportinfo", action: "mediastreamgetsupportinfo"))
        XCTAssertEqual(transport.cancellations, 1)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testXPCValueRoundTripPreservesUUIDBinaryAndIntegerRange() throws {
        let uuid = UUID()
        let input: [String: Any] = ["uuid": uuid as NSUUID, "bytes": Data([0, 255, 1]), "signed": Int64(-3),
            "unsigned": nativeUInt(UInt64.max), "smallUnsigned": nativeUInt(1), "bool": true, "array": ["a", NSNull()] as [Any]]
        var error: NSError?
        let output = try XCTUnwrap(ASNativeRoundTrip(input, &error))
        XCTAssertNil(error)
        XCTAssertEqual(output["uuid"] as? UUID, uuid)
        XCTAssertEqual(output["bytes"] as? Data, Data([0, 255, 1]))
        XCTAssertEqual((output["unsigned"] as? NSNumber)?.uint64Value, UInt64.max)
        XCTAssertEqual((output["smallUnsigned"] as? NSNumber)?.uint64Value, 1)
        XCTAssertEqual(output["signed"] as? Int64, -3)
        XCTAssertEqual(output["bool"] as? Bool, true)
        XCTAssertNil(ASNativeRoundTrip(["unsupported": Date()], &error))
        XCTAssertNotNil(error)
    }

    func testReportLayoutUsesExplicitMachTicksAnd48BitTruncation() {
        let report = NativeTouchReport.make(contact: true, x: 0x1234, y: 0xabcd, timestamp: 0xffff010203040506)
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
        XCTAssertThrowsError(try NativeCoordinateMapper.map(CGPoint(x: -1, y: 0), screen: screen, rotation: "rot0"))
        XCTAssertThrowsError(try NativeCoordinateMapper.map(CGPoint(x: Double.nan, y: 0), screen: screen, rotation: "rot0"))
    }

    private func reports(_ transport: ScriptedTransport) -> [Data] {
        transport.sends.compactMap { (($0["payload"] as? [String: Any])?["send"] as? [String: Any])?["_0"] as? Data }
    }
    func testTapDiscoversSurfaceAndSendsSingleContactRelease() throws {
        let transport = ScriptedTransport(), cancel = NativeCancellation()
        let hid = NativeHIDAdapter(transport: transport, cancellation: cancel, clock: { 12345 })
        try hid.prepare()
        let result = try hid.tap((12, 34), hold: 0.01)
        XCTAssertEqual(result["transportStatus"] as? String, "sent")
        XCTAssertEqual(reports(transport).map { $0[3] }, [0xc2, 2])
        let payload = (transport.sends[0]["payload"] as! [String: Any])["send"] as! [String: Any]
        XCTAssertEqual((payload["_1"] as? ASNativeUnsigned)?.value, 987)
        XCTAssertEqual(hid.release()["releaseRequired"] as? Bool, false)
    }
    private func swipePlan(start: CGPoint = CGPoint(x: 195, y: 600), end: CGPoint = CGPoint(x: 195, y: 500),
                           motion: SwipeMotion = SwipeMotion(), scale: Int = 3) throws -> NativeSwipePlan {
        let context = screenTestContext()
        let guardValue = try ScreenGuard(png: screenPNG(width: 390 * scale, height: 844 * scale), context: context,
            rects: CoordinateGesture.actionRegions(start: start, end: end, screen: context.screen.cgRect), policy: .init())
        return try NativeSwipePlan(gesture: CoordinateGesture(start: start, end: end, screenGuard: guardValue, motion: motion))
    }
    private func point(_ data: Data) -> [Int] { [Int(data[4]) | Int(data[5]) << 8, Int(data[6]) | Int(data[7]) << 8] }

    func testSwipePlanUsesOriginalPixelsAndExactMappedEndpoints() throws {
        let plan = try swipePlan()
        XCTAssertEqual(plan.movementDuration, 0.6, accuracy: 0.00001)
        XCTAssertEqual(try swipePlan(scale: 1).movementDuration, 0.2, accuracy: 0.00001)
        XCTAssertEqual(plan.point(at: 0).0, plan.start.0)
        XCTAssertEqual(plan.point(at: 1).1, plan.end.1)
        XCTAssertEqual(plan.point(at: 0.5).1, UInt16(((Double(plan.start.1) + Double(plan.end.1)) / 2).rounded()))
        XCTAssertThrowsError(try swipePlan(end: CGPoint(x: 195, y: -1)))
        XCTAssertThrowsError(try swipePlan(end: CGPoint(x: 195, y: 600)))
        XCTAssertThrowsError(try swipePlan(motion: SwipeMotion(velocity: 1)))
        XCTAssertThrowsError(try swipePlan(motion: SwipeMotion(velocity: .nan)))
    }
    func testSwipeReportsMonotonicPathHoldsAndOneRelease() throws {
        let transport = ScriptedTransport(), plan = try swipePlan(motion: SwipeMotion(velocity: 500, pressDuration: 0.1, holdDuration: 0.2))
        var now = 100.0, times: [Double] = []
        transport.onSend = { _ in times.append(now) }
        let hid = NativeHIDAdapter(transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now })
        try hid.prepare()
        let result = try hid.swipe(plan)
        let packets = reports(transport), points = packets.map(point)
        XCTAssertEqual(points.first, [Int(plan.start.0), Int(plan.start.1)])
        XCTAssertEqual(points.suffix(2), [[Int(plan.end.0), Int(plan.end.1)], [Int(plan.end.0), Int(plan.end.1)]])
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
        transport.onSend = { _ in times.append(now); now += 0.07 }
        let hid = NativeHIDAdapter(transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now })
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
                let data = ((message["payload"] as! [String: Any])["send"] as! [String: Any])["_0"] as! Data
                if data[3] == 0xc2 { contacts += 1; reachedEnd = self.point(data) == [Int(plan.end.0), Int(plan.end.1)] }
            }
            let hid = NativeHIDAdapter(transport: transport, cancellation: cancel, wait: {
                now += $0
                if (phase == 0 && contacts == 1) || (phase == 1 && contacts >= 3) || (phase == 2 && reachedEnd) { cancel.cancel() }
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
            if transport.sends.count == 3 { throw TransportError(description: "lost MOVE reply", possiblySent: true) }
        }
        let hid = NativeHIDAdapter(transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now })
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
            let hid = NativeHIDAdapter(transport: transport, cancellation: NativeCancellation(), wait: {
                now += deadline ? 11 : $0
            }, uptime: { now })
            try hid.prepare()
            XCTAssertThrowsError(try hid.swipe(plan) {
                if !deadline && !transport.sends.isEmpty { throw SomaError("native_media_unhealthy", "test media loss") }
            }) { XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true) }
            XCTAssertEqual(reports(transport).map { $0[3] }, [0xc2, 2])
            XCTAssertFalse(hid.isAvailable)
        }
    }
    func testSwipePreflightFailureSendsNothing() throws {
        let plan = try swipePlan(), transport = ScriptedTransport(), cancel = NativeCancellation()
        let hid = NativeHIDAdapter(transport: transport, cancellation: cancel)
        try hid.prepare()
        XCTAssertThrowsError(try hid.swipe(plan) { throw SomaError("native_media_unhealthy", "test") })
        cancel.cancel()
        XCTAssertThrowsError(try hid.swipe(plan))
        XCTAssertTrue(transport.sends.isEmpty)
    }
    func testCancelDuringContactStillReleasesWithoutReplay() throws {
        let transport = ScriptedTransport(), cancel = NativeCancellation()
        let hid = NativeHIDAdapter(transport: transport, cancellation: cancel, wait: { _ in cancel.cancel() })
        try hid.prepare()
        XCTAssertThrowsError(try hid.tap((1, 2))) { XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true) }
        XCTAssertEqual(reports(transport).map { $0[3] }, [0xc2, 2])
        XCTAssertThrowsError(try hid.tap((1, 2)))
        XCTAssertEqual(transport.sends.count, 2)
    }
    func testCancellationAfterContactKeepsTransportOpenForOneRelease() throws {
        let channel = TouchChannel(), cancellation = NativeCancellation()
        let transport = AppleServiceTransport(channel: channel)
        let hid = NativeHIDAdapter(transport: transport, cancellation: cancellation, wait: { _ in
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
        let hid = NativeHIDAdapter(transport: transport, cancellation: NativeCancellation(), wait: { _ in
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
        XCTAssertThrowsError(try hid.tap((1, 2))) { XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true) }
        XCTAssertEqual(reports(transport).map { $0[3] }, [0xc2, 2])
        XCTAssertTrue(hid.releaseUncertain)
        XCTAssertThrowsError(try hid.tap((1, 2)))
        XCTAssertEqual(transport.sends.count, 2)
    }
    func testUnsupportedSurfaceCannotInject() throws {
        let transport = ScriptedTransport()
        transport.onRequest = { _ in ["connectedServices": [["PrimaryUsagePage": 1, "PrimaryUsage": 6, "_ServiceID": 257]]] }
        let hid = NativeHIDAdapter(transport: transport, cancellation: NativeCancellation())
        XCTAssertThrowsError(try hid.prepare())
        XCTAssertThrowsError(try hid.tap((1, 2)))
        XCTAssertTrue(transport.sends.isEmpty)
    }

    private func mediaScript(_ transport: ScriptedTransport, sessions: [Any] = []) {
        var active = sessions
        transport.onRequest = { request in
            let feature = request["CoreDevice.featureIdentifier"] as! String
            // Actual iOS 27 status output is flat; serverInfo belongs to the stop reply.
            if feature.hasSuffix("getmediastreamserverstatus") { return ["CoreDevice.output": ["sessions": active, "running": !active.isEmpty]] }
            if feature.hasSuffix("startmediastream") {
                let input = request["CoreDevice.input"] as! [String: Any]
                let connection: [String: Any] = ["options": input["options"]!, "streamConfig": ["RemoteSSRC": UInt32(123456)]]
                active.append(["connection": connection])
                return ["CoreDevice.output": ["connection": connection, "negotiatorAnswer": Data([1])]]
            }
            if feature.hasSuffix("stopmediastream") { active = [] }
            return ["CoreDevice.output": [:]]
        }
    }
    private func media(_ transport: ScriptedTransport, _ receiver: MediaReceiver) -> NativeMediaSession {
        NativeMediaSession(client: NativeFeatureClient(transport: transport, deviceIdentifier: "test", version: "642.16"), receiver: receiver)
    }
    func testMediaStopsOnlyItsOwnSessionAndRequiresConfirmation() throws {
        let transport = ScriptedTransport(), receiver = MediaReceiver()
        mediaScript(transport)
        let session = media(transport, receiver)
        try session.start(displayID: 7, deviceAddress: "::1", offer: Data([0])) { XCTAssertEqual($0, Data([1])) }
        XCTAssertTrue(receiver.configured)
        let result = session.close()
        XCTAssertEqual(result["mediaStopAcknowledged"] as? Bool, true)
        XCTAssertEqual(receiver.closes, 1)
        _ = session.close()
        XCTAssertEqual(receiver.closes, 1)
        let stops = transport.requests.filter { ($0["CoreDevice.featureIdentifier"] as? String)?.hasSuffix("stopmediastream") == true }
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
            if !failed && (request["CoreDevice.featureIdentifier"] as? String)?.hasSuffix("getmediastreamserverstatus") == true {
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
                return ["CoreDevice.output": ["connection": ["options": ["avcMediaStreamOptionClientSessionID": ["uuid": UUID()]], "streamConfig": [:]], "negotiatorAnswer": Data()]]
            }
            return try previous(request)
        }
        let session = media(transport, receiver)
        XCTAssertThrowsError(try session.start(displayID: 1, deviceAddress: "::1", offer: Data()) { _ in })
        XCTAssertFalse(receiver.configured)
        XCTAssertFalse(transport.requests.contains { ($0["CoreDevice.featureIdentifier"] as? String)?.hasSuffix("stopmediastream") == true })
        XCTAssertEqual(session.close()["mediaStopAcknowledged"] as? Bool, true) // Successful inventory confirms our UUID absent.
    }

    func testMediaClosePreservesAClientThatStartedLater() throws {
        let transport = ScriptedTransport(), receiver = MediaReceiver()
        mediaScript(transport)
        let session = media(transport, receiver)
        try session.start(displayID: 1, deviceAddress: "::1", offer: Data()) { _ in }
        let original = transport.onRequest!
        let foreign: [String: Any] = ["connection": ["options": ["avcMediaStreamOptionClientSessionID": ["uuid": UUID()]],
            "streamConfig": ["RemoteSSRC": UInt32(888)]]]
        transport.onRequest = { request in
            var reply = try original(request)
            if (request["CoreDevice.featureIdentifier"] as? String)?.hasSuffix("getmediastreamserverstatus") == true {
                var output = reply["CoreDevice.output"] as! [String: Any]
                output["sessions"] = (output["sessions"] as! [Any]) + [foreign]
                reply["CoreDevice.output"] = output
            }
            return reply
        }
        XCTAssertEqual(session.close()["mediaStopAcknowledged"] as? Bool, true)
        let stop = try XCTUnwrap(transport.requests.first { ($0["CoreDevice.featureIdentifier"] as? String)?.hasSuffix("stopmediastream") == true })
        let input = stop["CoreDevice.input"] as! [String: Any]
        XCTAssertEqual((input["identifiers"] as? [ASNativeUnsigned])?.map(\.value), [123456])
        XCTAssertEqual(input["stopAll"] as? Bool, false)
    }

    func testMediaCloseRefusesChangedStreamIdentifier() throws {
        let transport = ScriptedTransport(), receiver = MediaReceiver()
        mediaScript(transport)
        let session = media(transport, receiver)
        try session.start(displayID: 1, deviceAddress: "::1", offer: Data()) { _ in }
        transport.onRequest = { request in
            XCTAssertTrue((request["CoreDevice.featureIdentifier"] as? String)?.hasSuffix("getmediastreamserverstatus") == true)
            return ["CoreDevice.output": ["sessions": [["connection": ["options": ["avcMediaStreamOptionClientSessionID": ["uuid": session.sessionID]],
                "streamConfig": ["RemoteSSRC": UInt32(777)]]]]]]
        }
        XCTAssertEqual(session.close()["mediaStopAcknowledged"] as? Bool, false)
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testNativeDisplayUsesObservedScaleAndRejectsUnknownGeometry() throws {
        let display = try NativeDisplay(["backlightState": "activeOn", "displays": [["primary": true, "displayId": 9,
            "bounds": [[0, 0], [1200, 2400]], "pointScale": 4.0, "currentOrientation": "rot0", "nativeOrientation": "rot0"]]])
        XCTAssertEqual(display.screen.width, 300); XCTAssertEqual(display.screen.height, 600)
        XCTAssertTrue(display.backlightOn)
        XCTAssertThrowsError(try NativeDisplay(["displays": []]))
    }
    func testNativeScreenshotReferencesDoNotRequireAXAndBecomeStale() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/native-observation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        let context = screenTestContext()
        let capture = CapturedObservation(nodes: [], metadata: ["backend": "apple-native", "scope": "screen",
            "screenContext": try jsonObject(JSONEncoder().encode(context))], screenshot: try screenPNG())
        _ = try cache.store(capture)
        let action = try DeviceAction(operation: "tap", request: ["reference": "o1", "x": 195, "y": 422])
        XCTAssertNotNil(try cache.resolveTarget(for: action).gesture)
        _ = try cache.store(capture)
        XCTAssertThrowsError(try cache.resolveTarget(for: action)) { XCTAssertEqual(($0 as? SomaError)?.code, "stale_reference") }
        let swipe = try DeviceAction(operation: "swipe", request: ["reference": "o2", "fromX": 100, "fromY": 400, "toX": 100, "toY": 200])
        let target = try cache.resolveTarget(for: swipe)
        XCTAssertEqual(target.gesture?.end, CGPoint(x: 100, y: 200))
        XCTAssertEqual(target.gesture?.screenGuard.regions.count, 2)
        _ = try cache.store(capture)
        XCTAssertThrowsError(try cache.resolveTarget(for: swipe)) { XCTAssertEqual(($0 as? SomaError)?.code, "stale_reference") }
    }
    func testNativeEmbeddedObservationDoesNotRecaptureOrReplay() {
        let response: [String: Any] = ["session": "test", "ok": false, "outcome": "unknown",
            "observation": ["ok": true, "result": ["observation": "o2"]]]
        let result = SessionClient.observing(session: "test", action: response) { XCTFail("Already captured atomically"); return [:] }
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(((result["observation"] as? [String: Any])?["result"] as? [String: Any])?["observation"] as? String, "o2")
    }
    func testRTPReceiverBindsDrainsAndSendsRTCPOnOwnedSocket() throws {
        let sender = socket(AF_INET6, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(sender, 0)
        defer { Darwin.close(sender) }
        var endpoint = sockaddr_in6()
        endpoint.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        endpoint.sin6_family = sa_family_t(AF_INET6)
        XCTAssertEqual(inet_pton(AF_INET6, "::1", &endpoint.sin6_addr), 1)
        let bound = withUnsafePointer(to: &endpoint) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(sender, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
        } }
        XCTAssertEqual(bound, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        XCTAssertEqual(withUnsafeMutablePointer(to: &endpoint) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(sender, $0, &length)
        } }, 0)
        let receiver = try NativeRTPReceiver(deviceAddress: "::1")
        defer { receiver.close() }
        let sourcePort = UInt16(bigEndian: endpoint.sin6_port)
        try receiver.configure(["SourcePort": sourcePort, "LocalSSRC": UInt32(123), "RemoteSSRC": UInt32(456),
            "RTCPEnabled": true, "RTCPSendInterval": 0.02, "SRTPCipherSuite": 0])
        endpoint.sin6_port = receiver.port.bigEndian
        let packet: [UInt8] = [0x80, 100, 0, 1, 0, 0, 0, 0, 0, 0, 0, 123, 1]
        let count = packet.withUnsafeBytes { bytes in withUnsafePointer(to: &endpoint) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(sender, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        } }
        XCTAssertEqual(count, packet.count)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while receiver.health()["healthy"] as? Bool != true && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(receiver.health()["rtpPackets"] as? Int, 1)
        XCTAssertEqual(receiver.health()["healthy"] as? Bool, true)
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(sender, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var bytes = [UInt8](repeating: 0, count: 256)
        let received = recv(sender, &bytes, bytes.count, 0)
        XCTAssertGreaterThan(received, 32)
        XCTAssertEqual(Array(bytes.prefix(4)), [0x81, 201, 0, 7])
        XCTAssertEqual(bytes[33], 202)
        receiver.close()
        XCTAssertEqual(receiver.health()["healthy"] as? Bool, false)
    }

    func testInstalledAppleMediaOfferWhenExplicitlyRequested() throws {
        guard ProcessInfo.processInfo.environment["AGENTSOMA_NATIVE_HOST_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in installed-framework check, not a portable device test")
        }
        let negotiator = try ASMediaNegotiator(error: ())
        XCTAssertGreaterThan(negotiator.offer.count, 0)
        XCTAssertNoThrow(try PropertyListSerialization.propertyList(from: negotiator.offer, format: nil))
    }

    func testEndpointInventoryMatchesCompleteIPv6AndOwner() {
        let inventory = """
        tcp6 0 0 fd00::2.4000 fd00::1.5000 ESTABLISHED 10 20 30 40 remoted:123 00000
        tcp6 0 0 fd00::2.4001 fd00::3.6000 ESTABLISHED 10 20 30 40 remoted:123 00000
        tcp6 0 0 fd00::2.4002 fd00::1.7000 ESTABLISHED 10 20 30 40 another:456 00000
        tcp6 0 0 fd00::1.8000 *.* LISTEN 0 0 30 40 remoted:123 00000
        tcp6 0 0 fd00::2.4000 fd00:0:0:0:0:0:0:1.5000 ESTABLISHED 10 20 30 40 remoted:123 00000
        """
        XCTAssertEqual(ASNativeRSDPorts(inventory, "fd00::1"), [5000])
        XCTAssertEqual(ASNativeRSDPorts(inventory, "fd00::3"), [6000])
        XCTAssertTrue(ASNativeRSDPorts(inventory, "invalid").isEmpty)
    }

    func testEndpointInventoryRejectsTruncatedMalformedAndAmbiguousEndpoints() {
        func row(_ endpoint: String, _ owner: String = "remoted:1") -> String {
            "tcp6 0 0 fd00::2.1234 \(endpoint) ESTABLISHED 0 0 0 0 \(owner)\n"
        }
        for endpoint in ["fd00::.123", "fd00::1.0", "fd00::1.65536", "fd00::1.-1", "fd00::1.123oops", "*.*"] {
            XCTAssertTrue(ASNativeRSDPorts(row(endpoint), "fd00::1").isEmpty)
        }
        XCTAssertTrue(ASNativeRSDPorts(row("fd00::1.123", "remoted:bad"), "fd00::1").isEmpty)
        // Caller must reject count != 1; never select the first of ambiguous endpoints.
        XCTAssertEqual(ASNativeRSDPorts(row("fd00::1.123") + row("fd00::1.124"), "fd00::1"), [123, 124])
    }

    func testEndpointInventoryRequiresRecentRegularFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("inventory")
        try Data("netstat-output".utf8).write(to: file)
        let now = Date()
        XCTAssertEqual(try NativeEndpointInventory.read(path: file.path, now: now), "netstat-output")
        XCTAssertThrowsError(try NativeEndpointInventory.read(path: file.path, now: now.addingTimeInterval(31)))
        XCTAssertThrowsError(try NativeEndpointInventory.read(path: file.path, now: now.addingTimeInterval(-1)))
        XCTAssertThrowsError(try NativeEndpointInventory.read(path: directory.path))
        XCTAssertNil(try NativeEndpointInventory.read(path: nil))
    }

}

import XCTest
import CoreGraphics
import AppleNativeBridge
import Darwin
@testable import IPhoneUseCore

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

private final class MediaTestClock {
    private let lock = NSLock()
    private var value = 10.0
    func read() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Double) { lock.lock(); self.value = value; lock.unlock() }
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

    func testLandscapeCornersAndAsymmetricPointUseNativeTouchAxes() throws {
        let screen = ScreenRect(CGRect(x: 0, y: 0, width: 844, height: 390))
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 844, y: 0), CGPoint(x: 0, y: 390), CGPoint(x: 844, y: 390), CGPoint(x: 211, y: 292.5)]
        let expected: [String: [[UInt16]]] = [
            "rot90": [[0,65535], [0,0], [65535,65535], [65535,0], [49151,49151]],
            "rot270": [[65535,0], [65535,65535], [0,0], [0,65535], [16384,16384]]]
        for rotation in ["rot90", "rot270"] {
            for (index, point) in points.enumerated() {
                let mapped = try NativeCoordinateMapper.map(point, screen: screen, rotation: rotation)
                XCTAssertEqual([mapped.0, mapped.1], expected[rotation]![index])
            }
            XCTAssertThrowsError(try NativeCoordinateMapper.map(CGPoint(x: 845, y: 100), screen: screen, rotation: rotation))
        }
    }

    func testLandscapeSwipeMapsBothEndpointsWithoutChangingPixelSpeed() throws {
        let screen = ScreenRect(CGRect(x: 0, y: 0, width: 844, height: 390))
        let context = ScreenContext(screen: screen, scope: screen, orientation: 3, keyboardCount: 0)
        let start = CGPoint(x: 211, y: 97.5), end = CGPoint(x: 633, y: 292.5)
        let guardValue = try ScreenGuard(png: screenPNG(width: 2532, height: 1170), context: context,
            rects: CoordinateGesture.actionRegions(start: start, end: end, screen: screen.cgRect), policy: .init())
        let gesture = CoordinateGesture(start: start, end: end, screenGuard: guardValue, motion: SwipeMotion(velocity: 600))
        let left = try NativeSwipePlan(gesture: gesture, rotation: "rot90")
        let right = try NativeSwipePlan(gesture: gesture, rotation: "rot270")
        XCTAssertEqual([left.start.0, left.start.1], [16384,49151])
        XCTAssertEqual([left.end.0, left.end.1], [49151,16384])
        XCTAssertEqual([right.start.0, right.start.1], [49151,16384])
        XCTAssertEqual([right.end.0, right.end.1], [16384,49151])
        XCTAssertEqual(left.movementDuration, hypot(1266, 585) / 600, accuracy: 0.00001)
        XCTAssertEqual(left.movementDuration, right.movementDuration)
        XCTAssertEqual(left.point(at: 0.5).0, 32768)
        XCTAssertEqual(left.point(at: 0.5).1, 32768)
    }

    private func reports(_ transport: ScriptedTransport) -> [Data] {
        transport.sends.compactMap { (($0["payload"] as? [String: Any])?["send"] as? [String: Any])?["_0"] as? Data }
    }
    func testTapDiscoversSurfaceAndSendsSingleContactRelease() throws {
        let transport = ScriptedTransport(), cancel = NativeCancellation()
        let hid = NativeHIDAdapter(transport: transport, cancellation: cancel, clock: { 12345 })
        try hid.prepare()
        var contacts = 0
        let result = try hid.tap((12, 34), hold: 0.01, onContact: {
            contacts += 1; XCTAssertEqual(self.reports(transport).map { $0[3] }, [0xc2])
        })
        XCTAssertEqual(contacts, 1)
        XCTAssertEqual(result["transportStatus"] as? String, "sent")
        XCTAssertEqual(reports(transport).map { $0[3] }, [0xc2, 2])
        let payload = (transport.sends[0]["payload"] as! [String: Any])["send"] as! [String: Any]
        XCTAssertEqual((payload["_1"] as? ASNativeUnsigned)?.value, 987)
        XCTAssertEqual(hid.release()["releaseRequired"] as? Bool, false)
    }
    func testDoubleTapQueuesTwoTimedPairsAtOnePoint() throws {
        let transport = ScriptedTransport(); var now = 10.0, sentAt: [Double] = []
        transport.onSend = { _ in sentAt.append(now) }
        let hid = NativeHIDAdapter(transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now })
        try hid.prepare()
        var contacts = 0
        let result = try hid.doubleTap((123, 456), onContact: {
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
            let hid = NativeHIDAdapter(transport: transport, cancellation: cancel, wait: { now += $0 }, uptime: { now })
            try hid.prepare()
            if cancelAfter == 0 { cancel.cancel() }
            transport.onSend = { _ in if transport.sends.count == cancelAfter { cancel.cancel() } }
            XCTAssertThrowsError(try hid.doubleTap((12, 34))) {
                if cancelAfter > 0 { XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true) }
            }
            let values = reports(transport)
            XCTAssertEqual(values.filter { $0[3] == 0xc2 }.count, cancelAfter == 0 ? 0 : cancelAfter <= 2 ? 1 : 2)
            if cancelAfter > 0 { XCTAssertEqual(values.last?[3], 2) }
            let count = values.count
            XCTAssertThrowsError(try hid.doubleTap((12, 34))); XCTAssertEqual(reports(transport).count, count)
        }
    }

    func testDoubleTapSendFailureAtEachReportRemainsUnknownAndReleases() throws {
        for failAt in 1...4 {
            let transport = ScriptedTransport(); var now = 0.0
            let hid = NativeHIDAdapter(transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now })
            try hid.prepare()
            transport.onSend = { _ in
                if transport.sends.count == failAt { throw TransportError(description: "test lost write", possiblySent: true) }
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
            let hid = NativeHIDAdapter(transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now })
            try hid.prepare()
            transport.onSend = { _ in if delay && transport.sends.count == 2 { now += 0.31 } }
            XCTAssertThrowsError(try hid.doubleTap((12, 34)) {
                if !delay && transport.sends.count == 2 { throw IPhoneUseError("native_media_unhealthy", "test") }
            }) { XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true) }
            XCTAssertEqual(reports(transport).map { $0[3] }, [0xc2, 2])
            XCTAssertFalse(hid.isAvailable)
        }
    }

    func testDoubleTapObservationGuardsAndRotationMapping() throws {
        for (rotation, orientation, width, height) in [("rot0", 1, 390, 844), ("rot90", 4, 844, 390), ("rot270", 3, 844, 390)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let cache = ObservationCache(directory: directory)
            let screen = ScreenRect(CGRect(x: 0, y: 0, width: width, height: height))
            let context = ScreenContext(screen: screen, scope: screen, orientation: orientation, keyboardCount: 0)
            let png = try screenPNG(width: width, height: height)
            let capture = CapturedObservation(nodes: [], metadata: ["backend": "apple-native", "screenContext": try jsonObject(JSONEncoder().encode(context))], screenshot: png)
            _ = try cache.store(capture)
            let action = try DeviceAction(operation: "double-tap", request: ["reference": "o1", "x": 100, "y": 150], allowScreenText: true)
            let gesture = try XCTUnwrap(cache.resolveTarget(for: action).gesture)
            try gesture.validate(kind: "double-tap")
            let mapped = try NativeCoordinateMapper.map(gesture.start, screen: screen, rotation: rotation)
            XCTAssertNotEqual(mapped.0, mapped.1)
            let changed = try screenPNG(width: width, height: height, patches: [(CGRect(x: 90, y: 140, width: 20, height: 20), [0,0,0])])
            XCTAssertFalse(try gesture.screenGuard.check(png: changed, context: context).accepted)
            _ = try cache.store(capture)
            XCTAssertThrowsError(try cache.resolveTarget(for: action))
        }
    }

    func testLongPressHoldsSingleContactAndChecksHealth() throws {
        let transport = ScriptedTransport(), cancel = NativeCancellation()
        var now = 10.0, checks = 0
        let hid = NativeHIDAdapter(transport: transport, cancellation: cancel, wait: { now += $0 }, uptime: { now })
        try hid.prepare()
        let facts = try hid.tap((120, 340), hold: 0.8) { checks += 1 }
        XCTAssertGreaterThanOrEqual(now, 10.8)
        XCTAssertGreaterThan(checks, 100)
        XCTAssertEqual(reports(transport).map { $0[3] }, [0xc2, 2])
        XCTAssertEqual(facts["pressDuration"] as? Double, 0.8)
    }

    func testLongPressHealthLossReleasesAndBlocksReplay() throws {
        let transport = ScriptedTransport(), cancel = NativeCancellation()
        var now = 10.0
        let hid = NativeHIDAdapter(transport: transport, cancellation: cancel, wait: { now += $0 }, uptime: { now })
        try hid.prepare()
        XCTAssertThrowsError(try hid.tap((120, 340), hold: 0.8) {
            if now > 10.2 { throw IPhoneUseError("native_media_unhealthy", "test") }
        }) { XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true) }
        XCTAssertEqual(reports(transport).map { $0[3] }, [0xc2, 2])
        XCTAssertThrowsError(try hid.tap((120, 340)))
        XCTAssertEqual(transport.sends.count, 2)
    }

    func testHomeQueuesButtonPairWithoutTouchOrKeyboard() throws {
        let touch = ScriptedTransport(), button = ScriptedTransport(), cancel = NativeCancellation()
        var now = 10.0
        let hid = NativeHIDAdapter(transport: touch, cancellation: cancel, wait: { now += $0 }, uptime: { now })
        try hid.prepare()
        let facts = try hid.home(using: button)
        XCTAssertTrue(touch.sends.isEmpty)
        XCTAssertEqual(button.sends.count, 2)
        for (index, message) in button.sends.enumerated() {
            XCTAssertEqual(message["messageType"] as? String, "IndigoButtonEvent")
            let payload = message["payload"] as! [String: Any]
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
        let hid = NativeHIDAdapter(transport: touch, cancellation: cancel, wait: { now += $0; cancel.cancel() }, uptime: { now })
        try hid.prepare()
        XCTAssertThrowsError(try hid.home(using: button)) { XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true) }
        XCTAssertEqual(button.sends.count, 2)
        XCTAssertEqual(((button.sends.last?["payload"] as? [String: Any])?["state"] as? ASNativeUnsigned)?.value, 2)
        XCTAssertThrowsError(try hid.home(using: button))
        XCTAssertEqual(button.sends.count, 2)
        XCTAssertEqual(hid.release()["buttonReleaseRequired"] as? Bool, false)
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
        var contacts = 0
        let result = try hid.swipe(plan, onContact: {
            contacts += 1; XCTAssertEqual(self.reports(transport).count, 1); XCTAssertEqual(now, 100)
        })
        XCTAssertEqual(contacts, 1)
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
                if !deadline && !transport.sends.isEmpty { throw IPhoneUseError("native_media_unhealthy", "test media loss") }
            }) { XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true) }
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
    func testSwipeInterruptedAfterMovesKeepsReleaseAndClosedChannelFactsSeparate() throws {
        let plan = try swipePlan()
        for closeChannel in [false, true] {
            let channel = TouchChannel(), cancellation = NativeCancellation()
            let transport = AppleServiceTransport(channel: channel)
            var now = 0.0, injected = false
            let hid = NativeHIDAdapter(transport: transport, cancellation: cancellation, wait: {
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

    func testNativeDisplayAcceptsDimmedBacklightButRejectsInactiveAndUnknownStates() throws {
        let active = try boundDisplay("rot0")
        let dimmed = try boundDisplay("rot0", backlight: "activeDimmed")
        XCTAssertTrue(dimmed.backlightOn)
        XCTAssertEqual(dimmed, active, "Dimming must not invalidate unchanged display geometry")
        for state in ["off", "inactive", "unknown", ""] {
            XCTAssertFalse(try boundDisplay("rot0", backlight: state).backlightOn, state)
        }
    }

    private func boundDisplay(_ rotation: String, scale: Double = 3, backlight: String = "activeOn") throws -> NativeDisplay {
        try NativeDisplay(["backlightState": backlight, "displays": [["primary": true, "displayId": 1,
            "bounds": [[0, 0], [1170, 2532]], "pointScale": scale, "currentOrientation": rotation, "nativeOrientation": "rot0"]]])
    }

    func testDisplayMediaRebindStopsOwnedStreamBeforeStartingWithNewIdentity() throws {
        let transport = ScriptedTransport(); mediaScript(transport)
        var receivers: [MediaReceiver] = []
        let binding = NativeDisplayMediaSession(makeSession: {
            let receiver = MediaReceiver(); receivers.append(receiver)
            return self.media(transport, receiver)
        }, startSession: { session, display in
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
        let features = transport.requests.compactMap { ($0["CoreDevice.featureIdentifier"] as? String)?.components(separatedBy: ".").last }
        XCTAssertEqual(features, ["getmediastreamserverstatus", "startmediastream", "getmediastreamserverstatus",
            "stopmediastream", "getmediastreamserverstatus", "getmediastreamserverstatus", "startmediastream"])
        let stop = transport.requests[3]["CoreDevice.input"] as! [String: Any]
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
        let binding = NativeDisplayMediaSession(makeSession: {
            let receiver = MediaReceiver(); receivers.append(receiver); return self.media(transport, receiver)
        }, startSession: { session, display in
            rotations.append(display.rotation)
            try session.start(displayID: display.id, deviceAddress: "::1", offer: Data()) { _ in }
        })
        try binding.ensureDisplay(boundDisplay("rot90"), mayReplace: true)
        let old = binding.health()["mediaSessionID"] as? String
        let geometryChanged = try binding.resynchronizeOrientation(mayReplace: true) {
            XCTAssertEqual(receivers.map(\.closes), [1])
            let features = transport.requests.compactMap { $0["CoreDevice.featureIdentifier"] as? String }
            XCTAssertTrue(features.contains { $0.hasSuffix("stopmediastream") })
            XCTAssertEqual(features.filter { $0.hasSuffix("startmediastream") }.count, 1)
            return try self.boundDisplay("rot270", backlight: "futureState")
        }
        XCTAssertTrue(geometryChanged)
        XCTAssertEqual(rotations, ["rot90", "rot270"])
        XCTAssertNotEqual(binding.health()["mediaSessionID"] as? String, old)
        XCTAssertEqual(binding.health()["orientationRefreshCount"] as? Int, 1)
        XCTAssertEqual(binding.health()["boundDisplayRotation"] as? String, "rot270")
        XCTAssertFalse(try binding.resynchronizeOrientation(mayReplace: true) { try self.boundDisplay("rot270", backlight: "off") })
        XCTAssertEqual(binding.close()["mediaStopAcknowledged"] as? Bool, true)
    }

    func testOrientationResyncFailureDoesNotRetryOrStartAtStaleGeometry() throws {
        for failure in ["stop", "read", "input"] {
            let transport = ScriptedTransport(); mediaScript(transport)
            var starts = 0, reads = 0
            let binding = NativeDisplayMediaSession(makeSession: { self.media(transport, MediaReceiver()) }, startSession: { session, display in
                starts += 1
                try session.start(displayID: display.id, deviceAddress: "::1", offer: Data()) { _ in }
            })
            try binding.ensureDisplay(boundDisplay("rot90"), mayReplace: true)
            let original = transport.onRequest!
            transport.onRequest = { request in
                if failure == "stop", (request["CoreDevice.featureIdentifier"] as? String)?.hasSuffix("stopmediastream") == true {
                    throw TransportError(description: "lost reply", possiblySent: true)
                }
                return try original(request)
            }
            let recover = {
                try binding.resynchronizeOrientation(mayReplace: failure != "input") {
                    reads += 1
                    throw IPhoneUseError("native_cancelled", "cancelled after stop")
                }
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

    func testRecordingRefreshReplacesOnlyOwnedStreamWithUnchangedGeometry() throws {
        let transport = ScriptedTransport(); mediaScript(transport)
        var receivers: [MediaReceiver] = []
        let binding = NativeDisplayMediaSession(makeSession: {
            let receiver = MediaReceiver(); receivers.append(receiver); return self.media(transport, receiver)
        }, startSession: { session, display in
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
        let stops = transport.requests.filter { ($0["CoreDevice.featureIdentifier"] as? String)?.hasSuffix("stopmediastream") == true }
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
        let binding = NativeDisplayMediaSession(makeSession: {
            made += 1; return self.media(transport, MediaReceiver())
        }, startSession: { session, display in
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
        XCTAssertFalse(binding.health()["healthy"] as! Bool)
        XCTAssertEqual(binding.close()["mediaStopAcknowledged"] as? Bool, false)
    }

    func testDisplayMediaUnconfirmedStopLatchesWithoutReplacementOrRetry() throws {
        let transport = ScriptedTransport(); mediaScript(transport)
        var made = 0
        let binding = NativeDisplayMediaSession(makeSession: {
            made += 1; return self.media(transport, MediaReceiver())
        }, startSession: { session, display in
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
        let state = NativeControlStatus.resolve(hid: .ready, media: binding.health(), closing: false, startupCode: nil, startupError: nil)
        XCTAssertFalse(state.available); XCTAssertEqual(state.recovery, .reconnectAndObserve)
        XCTAssertEqual(state.code, "native_media_display_refresh_failed")
    }

    func testDisplayMediaFailedReplacementCleansNewOwnershipAndNeverRetries() throws {
        let transport = ScriptedTransport(); mediaScript(transport)
        var receivers: [MediaReceiver] = [], starts = 0
        let binding = NativeDisplayMediaSession(makeSession: {
            let receiver = MediaReceiver(); receivers.append(receiver); return self.media(transport, receiver)
        }, startSession: { session, display in
            try session.start(displayID: display.id, deviceAddress: "::1", offer: Data()) { _ in }
            starts += 1
            if starts == 2 { throw IPhoneUseError("native_cancelled", "cancelled during replacement health wait") }
        })
        try binding.ensureDisplay(boundDisplay("rot90"), mayReplace: true)
        XCTAssertThrowsError(try binding.ensureDisplay(boundDisplay("rot270"), mayReplace: true))
        XCTAssertFalse(binding.health()["healthy"] as! Bool)
        XCTAssertEqual(receivers.map(\.closes), [1, 1])
        let count = transport.requests.count
        XCTAssertThrowsError(try binding.ensureDisplay(boundDisplay("rot270"), mayReplace: true))
        XCTAssertEqual(binding.close()["mediaStopAcknowledged"] as? Bool, true)
        XCTAssertEqual(transport.requests.count, count); XCTAssertEqual(starts, 2)
    }

    func testDisplayMediaDoesNotReplaceWhileInputStateIsUncertain() throws {
        let transport = ScriptedTransport(), receiver = MediaReceiver(); mediaScript(transport)
        let binding = NativeDisplayMediaSession(makeSession: { self.media(transport, receiver) }, startSession: { session, display in
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
        let binding = NativeDisplayMediaSession(makeSession: {
            made += 1
            if made == 2 {
                // A different client races into the gap after confirmed owned cleanup.
                let original = transport.onRequest!
                transport.onRequest = { request in
                    if (request["CoreDevice.featureIdentifier"] as? String)?.hasSuffix("getmediastreamserverstatus") == true {
                        return ["CoreDevice.output": ["sessions": [["foreign": true]]]]
                    }
                    return try original(request)
                }
            }
            return self.media(transport, MediaReceiver())
        }, startSession: { session, display in
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
        XCTAssertEqual(transport.requests.filter { ($0["CoreDevice.featureIdentifier"] as? String)?.hasSuffix("startmediastream") == true }.count, 1)
        XCTAssertEqual(transport.requests.filter { ($0["CoreDevice.featureIdentifier"] as? String)?.hasSuffix("stopmediastream") == true }.count, 1)
    }
    func testNativeDisplayRotatesNativeBoundsIntoUnmodifiedScreenshotGeometry() throws {
        for (rotation, width, height, orientation) in [("rot0", 1170, 2532, 1), ("rot90", 2532, 1170, 4), ("rot270", 2532, 1170, 3)] {
            let display = try NativeDisplay(["backlightState": "activeOn", "displays": [["primary": true, "displayId": 1,
                "bounds": [[0, 0], [1170, 2532]], "pointScale": 3, "currentOrientation": rotation, "nativeOrientation": "rot0"]]])
            XCTAssertEqual(display.pixelWidth, Double(width)); XCTAssertEqual(display.pixelHeight, Double(height))
            XCTAssertEqual(display.screen.width, Double(width) / 3); XCTAssertEqual(display.screen.height, Double(height) / 3)
            XCTAssertEqual(display.context.orientation, orientation)
        }
        XCTAssertThrowsError(try NativeDisplay(["displays": [["primary": true, "displayId": 1,
            "bounds": [[0, 0], [1170, 2532]], "pointScale": 3, "currentOrientation": "rot90", "nativeOrientation": "unknown"]]]))
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
        let home = try DeviceAction(operation: "home", request: ["reference": "o1"], allowScreenText: true)
        let press = try DeviceAction(operation: "long-press", request: ["reference": "o1", "x": 195, "y": 422], allowScreenText: true)
        XCTAssertEqual(try cache.resolveTarget(for: home).textGuard?.regions.map(\.rect), [context.screen])
        XCTAssertNoThrow(try cache.resolveTarget(for: press).gesture?.validate(kind: "long-press"))
        _ = try cache.store(capture)
        XCTAssertThrowsError(try cache.resolveTarget(for: home))
        XCTAssertThrowsError(try cache.resolveTarget(for: press))
        XCTAssertThrowsError(try cache.resolveTarget(for: action)) { XCTAssertEqual(($0 as? IPhoneUseError)?.code, "stale_reference") }
        let swipe = try DeviceAction(operation: "swipe", request: ["reference": "o2", "fromX": 100, "fromY": 400, "toX": 100, "toY": 200])
        let target = try cache.resolveTarget(for: swipe)
        XCTAssertEqual(target.gesture?.end, CGPoint(x: 100, y: 200))
        XCTAssertEqual(target.gesture?.screenGuard.regions.count, 2)
        _ = try cache.store(capture)
        XCTAssertThrowsError(try cache.resolveTarget(for: swipe)) { XCTAssertEqual(($0 as? IPhoneUseError)?.code, "stale_reference") }
    }
    func testNativeEmbeddedObservationDoesNotRecaptureOrReplay() {
        let response: [String: Any] = ["session": "test", "ok": false, "outcome": "unknown",
            "observation": ["ok": true, "result": ["observation": "o2"]]]
        let result = SessionClient.observing(session: "test", action: response) { XCTFail("Already captured atomically"); return [:] }
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(((result["observation"] as? [String: Any])?["result"] as? [String: Any])?["observation"] as? String, "o2")
    }
    func testRTCPReportRequiresNegotiatedSourceAndCompleteFraming() {
        let rr: [UInt8] = [0x80, 201, 0, 1, 0, 0, 0, 123]
        let sr: [UInt8] = [0x80, 200, 0, 6, 0, 0, 0, 123] + Array(repeating: 0, count: 20)
        XCTAssertEqual(NativeRTCPReport.parse(rr, expectedSSRC: 123), .report)
        XCTAssertEqual(NativeRTCPReport.parse(sr, expectedSSRC: 123), .report)
        XCTAssertNil(NativeRTCPReport.parse(sr, expectedSSRC: 456))
        for malformed: [UInt8] in [[], Array(sr.dropLast()), Array(sr.prefix(8)),
                                  [0x81, 201, 0, 1, 0, 0, 0, 123],
                                  [0x40, 201, 0, 1, 0, 0, 0, 123],
                                  [0xa0, 201, 0, 2, 0, 0, 0, 123, 0, 0, 0, 0],
                                  rr + [0x80, 202, 0, 8], rr + [0],
                                  [0x80, 204, 0, 1, 0, 0, 0, 123]] {
            XCTAssertNil(NativeRTCPReport.parse(malformed, expectedSSRC: 123))
        }
        let padded: [UInt8] = [0xa0, 201, 0, 2, 0, 0, 0, 123, 0, 0, 0, 4]
        XCTAssertEqual(NativeRTCPReport.parse(padded, expectedSSRC: 123), .report)
        XCTAssertNil(NativeRTCPReport.parse(padded + rr, expectedSSRC: 123))
        let bye: [UInt8] = [0x81, 203, 0, 1, 0, 0, 0, 123]
        XCTAssertEqual(NativeRTCPReport.parse(rr + bye, expectedSSRC: 123), .goodbye)
        XCTAssertEqual(NativeRTCPReport.parse(bye, expectedSSRC: 123), .goodbye)
        XCTAssertNil(NativeRTCPReport.parse(bye, expectedSSRC: 456))
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
        let clock = MediaTestClock()
        let receiver = try NativeRTPReceiver(deviceAddress: "::1", now: clock.read)
        defer { receiver.close() }
        XCTAssertEqual(receiver.health()["healthReason"] as? String, "not_configured")
        XCTAssertTrue(receiver.health()["lastRTPAgeSeconds"] is NSNull)
        let sourcePort = UInt16(bigEndian: endpoint.sin6_port)
        try receiver.configure(["SourcePort": sourcePort, "LocalSSRC": UInt32(123), "RemoteSSRC": UInt32(456),
            "RTCPEnabled": true, "RTCPSendInterval": 0.02, "SRTPCipherSuite": 0])
        endpoint.sin6_port = receiver.port.bigEndian
        func send(_ packet: [UInt8]) {
            _ = packet.withUnsafeBytes { bytes in withUnsafePointer(to: &endpoint) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sender, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            } }
        }
        let report: [UInt8] = [0x80, 200, 0, 6, 0, 0, 0, 123] + Array(repeating: 0, count: 20)
        send(report)
        let startupDeadline = ProcessInfo.processInfo.systemUptime + 1
        while (receiver.health()["validatedRTCPReports"] as? Int ?? 0) == 0 && ProcessInfo.processInfo.systemUptime < startupDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(receiver.health()["validatedRTCPReports"] as? Int, 1)
        XCTAssertEqual(receiver.health()["healthy"] as? Bool, false, "RTCP alone cannot establish startup readiness")
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
        XCTAssertEqual(receiver.health()["lastRTPAgeSeconds"] as? Double, 0)
        XCTAssertEqual(receiver.health()["lastRTCPSendAgeSeconds"] as? Double, 0)
        clock.set(15)
        XCTAssertEqual(receiver.health()["healthy"] as? Bool, false)
        XCTAssertEqual(receiver.health()["healthReason"] as? String, "rtp_stale")
        XCTAssertEqual(receiver.health()["lastRTPAgeSeconds"] as? Double, 5)
        // Truncated RTCP and rejected RTP cannot refresh session health.
        for diagnosticPacket: [UInt8] in [[0x80, 200, 0, 1, 0, 0, 0, 123],
                                         [0x80, 100, 0, 2, 0, 0, 0, 0, 0, 0, 0, 124]] {
            _ = diagnosticPacket.withUnsafeBytes { bytes in withUnsafePointer(to: &endpoint) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sender, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            } }
        }
        let diagnosticDeadline = ProcessInfo.processInfo.systemUptime + 1
        while (receiver.health()["datagramsReceived"] as? Int ?? 0) < 4 && ProcessInfo.processInfo.systemUptime < diagnosticDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(receiver.health()["rtcpPacketsReceived"] as? Int, 2)
        XCTAssertEqual(receiver.health()["rejectedDatagrams"] as? Int, 2)
        XCTAssertEqual(receiver.health()["rtpPackets"] as? Int, 1)
        XCTAssertEqual(receiver.health()["healthReason"] as? String, "rtp_stale")
        XCTAssertEqual(receiver.health()["lastRTCPReceiveAgeSeconds"] as? Double, 0)
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(sender, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var bytes = [UInt8](repeating: 0, count: 256)
        let received = recv(sender, &bytes, bytes.count, 0)
        XCTAssertGreaterThan(received, 32)
        XCTAssertEqual(Array(bytes.prefix(4)), [0x81, 201, 0, 7])
        XCTAssertEqual(bytes[33], 202)
        send(report)
        let reportDeadline = ProcessInfo.processInfo.systemUptime + 1
        while receiver.health()["healthy"] as? Bool != true && ProcessInfo.processInfo.systemUptime < reportDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(receiver.health()["healthReason"] as? String, "recent_peer_report")
        XCTAssertEqual(receiver.health()["videoFlowing"] as? Bool, false)
        XCTAssertEqual(receiver.health()["validatedRTCPReports"] as? Int, 2)
        XCTAssertEqual(receiver.health()["rtpPackets"] as? Int, 1)
        clock.set(20)
        XCTAssertEqual(receiver.health()["healthy"] as? Bool, false)
        XCTAssertEqual(receiver.health()["healthReason"] as? String, "rtp_stale")
        send(report + [0x81, 203, 0, 1, 0, 0, 0, 123])
        let byeDeadline = ProcessInfo.processInfo.systemUptime + 1
        while receiver.health()["peerEnded"] as? Bool != true && ProcessInfo.processInfo.systemUptime < byeDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(receiver.health()["healthReason"] as? String, "peer_ended")
        XCTAssertEqual(receiver.health()["healthy"] as? Bool, false)
        receiver.close()
        XCTAssertEqual(receiver.health()["healthy"] as? Bool, false)
        XCTAssertEqual(receiver.health()["healthReason"] as? String, "receiver_closed")
        XCTAssertEqual(receiver.health()["receiverOpen"] as? Bool, false)
    }

    func testTransportDiagnosticsDoNotSendRequestsOrReopenAfterCancellation() {
        let channel = ReplyChannel()
        let observed = AppleServiceTransport(channel: channel)
        XCTAssertEqual(observed.diagnostics["locallyClosed"] as? Bool, false)
        observed.cancel()
        XCTAssertEqual(observed.diagnostics["locallyClosed"] as? Bool, true)
        XCTAssertTrue(channel.callbacks.isEmpty)
        XCTAssertEqual(channel.sends, 0)
        XCTAssertEqual(channel.cancellations, 1)
    }

    func testInstalledAppleMediaOfferWhenExplicitlyRequested() throws {
        guard ProcessInfo.processInfo.environment["IPHONE_USE_NATIVE_HOST_SMOKE"] == "1" else {
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

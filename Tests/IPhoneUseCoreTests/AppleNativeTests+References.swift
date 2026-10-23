import XCTest
import CoreGraphics
import AppleNativeBridge
import Darwin
@testable import IPhoneUseCore

extension AppleNativeTests {

    func testNativeScreenshotReferencesDoNotRequireAXAndBecomeStale() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/native-observation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        let context = screenTestContext()
        let capture = CapturedObservation(
            nodes: [],
            metadata: [
                "backend": "apple-native", "scope": "screen",
                "screenContext": try jsonObject(JSONEncoder().encode(context))
            ], screenshot: try screenPNG())
        _ = try cache.store(capture)
        let action = try DeviceAction(operation: "tap", request: ["reference": "o1", "x": 195, "y": 422])
        XCTAssertNotNil(try cache.resolveTarget(for: action).gesture)
        let home = try DeviceAction(operation: "home", request: ["reference": "o1"], allowScreenText: true)
        let press = try DeviceAction(
            operation: "long-press", request: ["reference": "o1", "x": 195, "y": 422], allowScreenText: true)
        XCTAssertEqual(try cache.resolveTarget(for: home).textGuard?.regions.map(\.rect), [context.screen])
        XCTAssertNoThrow(try cache.resolveTarget(for: press).gesture?.validate(kind: "long-press"))
        _ = try cache.store(capture)
        XCTAssertThrowsError(try cache.resolveTarget(for: home))
        XCTAssertThrowsError(try cache.resolveTarget(for: press))
        XCTAssertThrowsError(try cache.resolveTarget(for: action)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "stale_reference")
        }
        let swipe = try DeviceAction(
            operation: "swipe", request: ["reference": "o2", "fromX": 100, "fromY": 400, "toX": 100, "toY": 200])
        let target = try cache.resolveTarget(for: swipe)
        XCTAssertEqual(target.gesture?.end, CGPoint(x: 100, y: 200))
        XCTAssertEqual(target.gesture?.screenGuard.regions.count, 2)
        _ = try cache.store(capture)
        XCTAssertThrowsError(try cache.resolveTarget(for: swipe)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "stale_reference")
        }
    }
    func testNativeEmbeddedObservationDoesNotRecaptureOrReplay() {
        let response: [String: Any] = [
            "session": "test", "ok": false, "outcome": "unknown",
            "observation": ["ok": true, "result": ["observation": "o2"]]
        ]
        let result = SessionClient.observing(session: "test", action: response) {
            XCTFail("Already captured atomically")
            return [:]
        }
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(
            ((result["observation"] as? [String: Any])?["result"] as? [String: Any])?["observation"] as? String, "o2")
    }
    func testRTCPReportRequiresNegotiatedSourceAndCompleteFraming() {
        let readResult: [UInt8] = [0x80, 201, 0, 1, 0, 0, 0, 123]
        let stopResult: [UInt8] = [0x80, 200, 0, 6, 0, 0, 0, 123] + Array(repeating: 0, count: 20)
        XCTAssertEqual(NativeRTCPReport.parse(readResult, expectedSSRC: 123), .report)
        XCTAssertEqual(NativeRTCPReport.parse(stopResult, expectedSSRC: 123), .report)
        XCTAssertNil(NativeRTCPReport.parse(stopResult, expectedSSRC: 456))
        for malformed: [UInt8] in [
            [], Array(stopResult.dropLast()), Array(stopResult.prefix(8)), [0x81, 201, 0, 1, 0, 0, 0, 123],
            [0x40, 201, 0, 1, 0, 0, 0, 123], [0xa0, 201, 0, 2, 0, 0, 0, 123, 0, 0, 0, 0],
            readResult + [0x80, 202, 0, 8], readResult + [0], [0x80, 204, 0, 1, 0, 0, 0, 123]
        ] { XCTAssertNil(NativeRTCPReport.parse(malformed, expectedSSRC: 123)) }
        let padded: [UInt8] = [0xa0, 201, 0, 2, 0, 0, 0, 123, 0, 0, 0, 4]
        XCTAssertEqual(NativeRTCPReport.parse(padded, expectedSSRC: 123), .report)
        XCTAssertNil(NativeRTCPReport.parse(padded + readResult, expectedSSRC: 123))
        let bye: [UInt8] = [0x81, 203, 0, 1, 0, 0, 0, 123]
        XCTAssertEqual(NativeRTCPReport.parse(readResult + bye, expectedSSRC: 123), .goodbye)
        XCTAssertEqual(NativeRTCPReport.parse(bye, expectedSSRC: 123), .goodbye)
        XCTAssertNil(NativeRTCPReport.parse(bye, expectedSSRC: 456))
    }

    func testRTPReceiverBindsDrainsAndSendsRTCPOnOwnedSocket() throws {
        let socket = try FixtureUDPSocket()
        let sender = socket.descriptor
        var endpoint = socket.endpoint
        defer { socket.close() }
        let clock = MediaTestClock()
        let receiver = try NativeRTPReceiver(deviceAddress: "::1", now: clock.read)
        defer { receiver.close() }
        XCTAssertEqual(receiver.health()["healthReason"] as? String, "not_configured")
        XCTAssertTrue(receiver.health()["lastRTPAgeSeconds"] is NSNull)
        let sourcePort = UInt16(bigEndian: endpoint.sin6_port)
        try receiver.configure([
            "SourcePort": sourcePort, "LocalSSRC": UInt32(123), "RemoteSSRC": UInt32(456), "RTCPEnabled": true,
            "RTCPSendInterval": 0.02, "SRTPCipherSuite": 0
        ])
        endpoint.sin6_port = receiver.port.bigEndian
        let send: ([UInt8]) -> Void = { self.sendPacket($0, sender: sender, endpoint: &endpoint) }
        let report: [UInt8] = [0x80, 200, 0, 6, 0, 0, 0, 123] + Array(repeating: 0, count: 20)
        send(report)
        let startupDeadline = ProcessInfo.processInfo.systemUptime + 1
        while (receiver.health()["validatedRTCPReports"] as? Int ?? 0) == 0
            && ProcessInfo.processInfo.systemUptime < startupDeadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(receiver.health()["validatedRTCPReports"] as? Int, 1)
        XCTAssertEqual(receiver.health()["healthy"] as? Bool, false, "RTCP alone cannot establish startup readiness")
        let packet: [UInt8] = [0x80, 100, 0, 1, 0, 0, 0, 0, 0, 0, 0, 123, 1]
        let count = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &endpoint) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sender, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        XCTAssertEqual(count, packet.count)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while receiver.health()["healthy"] as? Bool != true && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(receiver.health()["rtpPackets"] as? Int, 1)
        XCTAssertEqual(receiver.health()["healthy"] as? Bool, true)
        XCTAssertEqual(receiver.health()["lastRTPAgeSeconds"] as? Double, 0)
        XCTAssertEqual(receiver.health()["lastRTCPSendAgeSeconds"] as? Double, 0)
        verifyReceiverLiveness(receiver, clock: clock, sender: sender, report: report, send: send)
    }
    private func verifyReceiverLiveness(
        _ receiver: NativeRTPReceiver, clock: MediaTestClock, sender: Int32, report: [UInt8], send: ([UInt8]) -> Void
    ) {
        clock.set(15)
        XCTAssertEqual(receiver.health()["healthy"] as? Bool, false)
        XCTAssertEqual(receiver.health()["healthReason"] as? String, "rtp_stale")
        XCTAssertEqual(receiver.health()["lastRTPAgeSeconds"] as? Double, 5)
        // Truncated RTCP and rejected RTP cannot refresh session health.
        for diagnosticPacket: [UInt8] in [
            [0x80, 200, 0, 1, 0, 0, 0, 123], [0x80, 100, 0, 2, 0, 0, 0, 0, 0, 0, 0, 124]
        ] { send(diagnosticPacket) }
        let diagnosticDeadline = ProcessInfo.processInfo.systemUptime + 1
        while (receiver.health()["datagramsReceived"] as? Int ?? 0) < 4
            && ProcessInfo.processInfo.systemUptime < diagnosticDeadline { Thread.sleep(forTimeInterval: 0.01) }
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

    private func sendPacket(_ packet: [UInt8], sender: Int32, endpoint: inout sockaddr_in6) {
        _ = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &endpoint) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sender, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
    }

}

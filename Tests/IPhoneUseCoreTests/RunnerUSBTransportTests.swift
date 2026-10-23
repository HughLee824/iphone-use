import XCTest
import Darwin
@testable import IPhoneUseCore

final class RunnerUSBTransportTests: XCTestCase {
    private func device(_ type: String = "USB", serial: String = "phone", id: Any = 4) -> [String: Any] {
        ["DeviceID": id, "Properties": ["SerialNumber": serial, "ConnectionType": type]]
    }

    func testSelectsOnlyExactUSBDeviceAndRejectsAmbiguityAndMalformedIDs() throws {
        XCTAssertEqual(
            try RunnerUSBTransport.deviceID(
                ["DeviceList": [device("Network"), device(serial: "other"), device()]], serial: "phone"), 4)
        for devices in [
            [device("Network")], [device(), device()], [device(serial: "other")],
            [device(id: true)], [device(id: 1.5)], [device(id: -1)], [device(id: UInt64.max)]
        ] {
            XCTAssertThrowsError(try RunnerUSBTransport.deviceID(["DeviceList": devices], serial: "phone"))
        }
    }

    private func header(_ size: UInt32, version: UInt32 = 1, type: UInt32 = 8, tag: UInt32 = 1) -> Data {
        var data = Data()
        for value in [size, version, type, tag] {
            var word = value.littleEndian; withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
        }
        return data
    }

    func testBoundedFramingRejectsTruncationLengthTypeVersionAndTag() throws {
        XCTAssertEqual(try RunnerUSBTransport.payloadSize(header(500)), 484)
        for bytes in [
            Data(), Data(repeating: 0, count: 15), header(16), header(UInt32.max),
            header(32, version: 0), header(32, type: 2), header(32, tag: 99)
        ] {
            XCTAssertThrowsError(try RunnerUSBTransport.payloadSize(bytes))
        }
    }

    private func pair(deadline: TimeInterval) throws -> (RunnerSocket, RunnerSocket) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return try (
            RunnerSocket(ownedDescriptor: descriptors[0], deadline: deadline),
            RunnerSocket(ownedDescriptor: descriptors[1], deadline: deadline)
        )
    }

    func testSocketDeadlineEOFAndLineLimit() throws {
        let now = ProcessInfo.processInfo.systemUptime
        let (reader, writer) = try pair(deadline: now + 0.05)
        XCTAssertThrowsError(try reader.read(count: 1))
        reader.close(); writer.close()
        let (reader2, writer2) = try pair(deadline: now + 2)
        try writer2.write(Data("abcd\n".utf8))
        XCTAssertThrowsError(try reader2.readLine(limit: 3))
        reader2.close(); writer2.close()
        let (reader3, writer3) = try pair(deadline: now + 2)
        writer3.close()
        XCTAssertThrowsError(try reader3.read(count: 1))
    }

    func testHandshakeAndPartialResponseUseUSBBigEndianPortAndOneJSONRequest() throws {
        try exchangeScenario(failure: nil)
    }

    func testConnectRejectionIsNotDispatchedAndLostOrMismatchedReplyMayHaveExecuted() throws {
        for failure in ["connect", "closed", "mismatch"] { try exchangeScenario(failure: failure) }
    }

    func testProgressArrivesBeforeFinalResponseAndNeverReplaysInput() throws {
        try exchangeScenario(failure: nil, progress: true)
        for failure in ["progress_id", "progress_duplicate", "progress_kind"] {
            try exchangeScenario(failure: failure, progress: true)
        }
    }

    func testCoalescedProgressAndFinalLinesAreNotLost() throws {
        let (reader, writer) = try pair(deadline: ProcessInfo.processInfo.systemUptime + 2)
        defer { reader.close(); writer.close() }
        try writer.write(Data("progress\nfinal\n".utf8))
        XCTAssertEqual(String(data: try reader.readLine(limit: 100), encoding: .utf8), "progress")
        XCTAssertEqual(String(data: try reader.readLine(limit: 100), encoding: .utf8), "final")
    }

    private func exchangeScenario(failure: String?, progress: Bool = false) throws {
        let progressRead = DispatchSemaphore(value: 0)
        var progressCount = 0
        let finished = expectation(description: "two usbmux connections")
        finished.expectedFulfillmentCount = 2
        var connections = 0
        let transport = RunnerUSBTransport(
            device: "phone",
            openSocket: { deadline in
                let (client, server) = try self.pair(deadline: deadline)
                connections += 1
                let index = connections
                DispatchQueue.global().async {
                    defer { server.close(); finished.fulfill() }
                    do {
                        try self.serveExchange(
                            server, index: index, failure: failure, progress: progress,
                            progressRead: progressRead)
                    } catch { XCTFail("Fake usbmux server: \(error)") }
                }
                return client
            })
        let request: [String: Any] = [
            "id": "request-1", "op": "act", "token": "secret", "inputProgress": progress
        ]
        let onProgress: (([String: Any]) throws -> Void)? =
            progress
            ? { event in
                XCTAssertEqual(event["event"] as? String, "input_started")
                progressCount += 1; progressRead.signal()
            } : nil
        if let failure {
            XCTAssertThrowsError(try transport.exchange(request, timeout: 3, onProgress: onProgress)) {
                XCTAssertEqual(($0 as? TransportError)?.possiblySent, failure != "connect")
            }
        } else {
            XCTAssertEqual(
                try transport.exchange(request, timeout: 3, onProgress: onProgress)["ok"] as? Bool, true)
        }
        if progress && failure == nil { XCTAssertEqual(progressCount, 1) }
        XCTAssertEqual(connections, 2) // No reconnect/replay after a transmitted UI command.
        wait(for: [finished], timeout: 4)
    }
    private func serveExchange(
        _ server: RunnerSocket, index: Int, failure: String?, progress: Bool, progressRead: DispatchSemaphore
    ) throws {
        let size = try RunnerUSBTransport.payloadSize(server.read(count: 16))
        let request = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: server.read(count: size), format: nil)
                as? [String: Any])
        let response: [String: Any]
        if index == 1 {
            XCTAssertEqual(request["MessageType"] as? String, "ListDevices")
            response = ["DeviceList": [self.device("Network"), self.device()]]
        } else {
            XCTAssertEqual(request["MessageType"] as? String, "Connect")
            XCTAssertEqual(request["DeviceID"] as? Int, 4)
            XCTAssertEqual(request["PortNumber"] as? Int, Int(UInt16(47821).bigEndian))
            response = ["MessageType": "Result", "Number": failure == "connect" ? 3 : 0]
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: response, format: .xml, options: 0)
        // Deliberately fragment the framing, independently of JSON.
        let header = self.header(UInt32(data.count + 16))
        try server.write(Data(header.prefix(3))); try server.write(Data(header.dropFirst(3)) + data)
        if index == 2, failure != "connect" {
            let line = try jsonObject(server.readLine(limit: 65536))
            XCTAssertEqual(line["id"] as? String, "request-1")
            XCTAssertEqual(line["token"] as? String, "secret")
            if failure == "closed" { return }
            if progress {
                let event: [String: Any] = [
                    "id": failure == "progress_id" ? "other" : "request-1",
                    "event": failure == "progress_kind" ? "unknown" : "input_started"
                ]
                let wire = try jsonData(event) + Data([10])
                if let failure, failure.hasPrefix("progress_") {
                    try server.write(wire + (failure == "progress_duplicate" ? wire : Data()))
                    return
                }
                try server.write(wire)
                XCTAssertEqual(
                    progressRead.wait(timeout: .now() + 2), .success,
                    "Host must consume progress before the final response is sent")
            }
            try server.write(Data("{\"id\":\"".utf8))
            try server.write(
                Data("\(failure == "mismatch" ? "other" : "request-1")\",\"ok\":true}\n".utf8))
        }
    }

}

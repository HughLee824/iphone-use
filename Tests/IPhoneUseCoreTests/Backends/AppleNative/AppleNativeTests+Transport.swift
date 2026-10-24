import XCTest
import CoreGraphics
import AppleNativeBridge
import Darwin
@testable import IPhoneUseCore

extension AppleNativeTests {
    func testBrokerSocketRejectsNonDeviceSocketAndConsumesOnlyOwnedDescriptor() throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { close(sockets[1]) }
        XCTAssertThrowsError(
            try ASNativeChannel(
                connectedFileDescriptor: sockets[0], deviceAddress: "::1", versionFlags: 1 << 56))
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
        XCTAssertEqual(
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }, 0)
        XCTAssertEqual(listen(listener, 4), 0)
        var size = socklen_t(MemoryLayout<sockaddr_in6>.size)
        XCTAssertEqual(
            withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(listener, $0, &size)
                }
            }, 0)
        for (expectedAddress, flags) in [("::2", UInt64(1) << 56), ("::1", UInt64(0)), ("::1", UInt64(2))] {
            let client = socket(AF_INET6, SOCK_STREAM, 0)
            XCTAssertGreaterThanOrEqual(client, 0)
            XCTAssertEqual(
                withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }, 0)
            let peer = accept(listener, nil, nil)
            defer { close(peer) }
            XCTAssertThrowsError(
                try ASNativeChannel(
                    connectedFileDescriptor: client, deviceAddress: expectedAddress, versionFlags: flags))
            XCTAssertEqual(fcntl(client, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF)
        }
    }

    func testLaunchOptionsPrecedeBundleSoTheyCannotBecomeAppArguments() {
        let bundle = "com.example.probe"
        let arguments = CoreDevice.commandArguments(
            ["device", "process", "launch", "--activate", "--device", "test-device"],
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
                } catch { XCTFail("\(error)") }
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
        XCTAssertThrowsError(try client.request(["id": 1], timeout: 0.01)) {
            XCTAssertEqual(($0 as? TransportError)?.possiblySent, true)
        }
        channel.reply(1, value: 123)
        XCTAssertThrowsError(try client.request(["id": 2], timeout: 1)) {
            XCTAssertEqual(($0 as? TransportError)?.possiblySent, false)
        }
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
            do { _ = try client.request(["id": 1], timeout: 3); XCTFail("Cancelled request must fail") } catch {
                XCTAssertEqual((error as? TransportError)?.possiblySent, true)
            }
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
        let client = NativeFeatureClient(
            transport: transport, deviceIdentifier: "test-device", version: "642.16")
        XCTAssertThrowsError(try client.invoke("getmediasupportinfo", action: "mediastreamgetsupportinfo"))
        XCTAssertEqual(transport.cancellations, 1)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testXPCValueRoundTripPreservesUUIDBinaryAndIntegerRange() throws {
        let uuid = UUID()
        let input: [String: Any] = [
            "uuid": uuid as NSUUID, "bytes": Data([0, 255, 1]), "signed": Int64(-3),
            "unsigned": nativeUInt(UInt64.max), "smallUnsigned": nativeUInt(1), "bool": true,
            "array": ["a", NSNull()] as [Any]
        ]
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
}

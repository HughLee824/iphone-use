import XCTest
import CoreImage
@testable import IPhoneUseCore

final class NativePreviewTests: XCTestCase {

    func get(_ url: URL, host: String? = nil, origin: String? = nil) throws -> (Int, Data) {
        let done = expectation(description: "HTTP")
        var response: HTTPURLResponse?, bytes = Data(), failure: Error?
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 3
        if let host { request.setValue(host, forHTTPHeaderField: "Host") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        URLSession.shared.dataTask(with: request) { data, result, error in
            bytes = data ?? Data(); response = result as? HTTPURLResponse; failure = error; done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        if let failure { throw failure }
        return (try XCTUnwrap(response).statusCode, bytes)
    }

    func previewDisplay(backlight: String?) throws -> NativeDisplay {
        var facts: [String: Any] = [
            "displays": [
                [
                    "primary": true, "displayId": 1,
                    "bounds": [[0, 0], [12, 18]], "pointScale": 1,
                    "currentOrientation": "rot0", "nativeOrientation": "rot0"
                ]
            ]
        ]
        facts["backlightState"] = backlight
        return try NativeDisplay(facts)
    }

    func withPreviewReceiver(_ body: (NativeRTPReceiver, (UInt8) -> Void) throws -> Void) throws {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(nil, 12, 18, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let frame = NativeDecodedVideoFrame(pixels: try XCTUnwrap(pixels), nativeWidth: 12, nativeHeight: 18)
        let receiver = try NativeRTPReceiver(
            deviceAddress: "::1", captureSnapshots: true,
            makeSnapshots: {
                NativeVideoSnapshot(decode: { _ in frame }, resetDecoder: {})
            })
        defer { receiver.close() }
        let sender = socket(AF_INET6, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(sender, 0)
        defer { Darwin.close(sender) }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); address.sin6_family = sa_family_t(AF_INET6)
        XCTAssertEqual(inet_pton(AF_INET6, "::1", &address.sin6_addr), 1)
        XCTAssertEqual(
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(sender, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        XCTAssertEqual(
            withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(sender, $0, &length)
                }
            }, 0)
        try receiver.configure([
            "SourcePort": UInt16(bigEndian: address.sin6_port), "LocalSSRC": 123, "RemoteSSRC": 456,
            "RTCPEnabled": true, "RTCPSendInterval": 1.0, "SRTPCipherSuite": 0, "RxPayloadType": 100,
            "TilesPerFrame": 1
        ])
        address.sin6_port = receiver.port.bigEndian
        func send(_ sequence: UInt8) {
            let packet = Data([0x80, 0xe4, 0, sequence, 0, 0, 0, sequence, 0, 0, 0, 123, 40, 1, 1])
            _ = packet.withUnsafeBytes { bytes in
                withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(
                            sender, bytes.baseAddress, bytes.count, 0, $0,
                            socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
            }
        }
        try body(receiver, send)
    }
}
